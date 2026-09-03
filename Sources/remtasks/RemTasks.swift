import ArgumentParser
import Foundation
import RemTasksCore

@main
struct RemTasks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remtasks",
        abstract: "Two-way sync between Apple Reminders and Google Tasks, across multiple Google accounts.",
        version: "0.1.0",
        subcommands: [Lists.self, GoogleLists.self, GoogleTasks.self, Auth.self, Sync.self, Status.self, Doctor.self, InstallAgent.self, UninstallAgent.self]
    )
}

// MARK: - Shared

struct CommonOptions: ParsableArguments {
    @Option(name: .long, help: "Path to config.json (default ~/.config/remtasks/config.json).")
    var config: String?

    @Flag(name: .shortAndLong, help: "Verbose logging.")
    var verbose = false
}

struct Context {
    let config: Config
    let directory: URL
    let state: StateStore
    let auth: GoogleAuth
    let hierarchy: RemindersHierarchy
    let hierarchyWarnings: [String]

    static let agentLabel = "net.gitman.remtasks"
    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/remtasks", isDirectory: true)
    }
    static var agentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    init(_ opts: CommonOptions) throws {
        Log.verbose = opts.verbose
        Log.toFile(Context.logDirectory.appendingPathComponent("remtasks.log"))
        config = try Config.load(from: opts.config)
        directory = opts.config.map { URL(fileURLWithPath: Config.expandTilde($0)).deletingLastPathComponent() } ?? Config.defaultDirectory
        state = try StateStore(path: directory.appendingPathComponent("state.sqlite").path)
        let storage: TokenStorage = config.google.tokenStorage == "keychain"
            ? KeychainTokenStorage()
            : FileTokenStorage(directory: directory.appendingPathComponent("tokens", isDirectory: true))
        auth = GoogleAuth(clientSecretURL: config.clientSecretURL, storage: storage)
        let (h, w) = RemindersDatabase.load(overridePath: config.remindersDatabase)
        hierarchy = h
        hierarchyWarnings = w
    }
}

/// One sync at a time.
final class RunLock {
    private let fd: Int32
    init?(directory: URL) {
        let path = directory.appendingPathComponent("sync.lock").path
        fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { return nil }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

// MARK: - lists

struct Lists: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show Reminders lists and where each one syncs.")
    @OptionGroup var common: CommonOptions

    func run() async throws {
        let ctx = try Context(common)
        ctx.hierarchyWarnings.forEach(Log.warn)
        let store = RemindersStore()
        try await store.requestAccess()
        let source = try store.source(titled: ctx.config.remindersSource)
        let (lists, usedCache) = try ctx.state.listsWithGroups(store.lists(in: source, hierarchy: ctx.hierarchy), hierarchy: ctx.hierarchy)
        let counts = try ctx.state.linkCounts()
        let listLinks = Dictionary(try ctx.state.listLinks().map { ($0.appleListID, $0) }, uniquingKeysWith: { a, _ in a })

        print(pad("GROUP", 14) + pad("LIST", 28) + pad("ACTIVE", 8) + pad("SUBTASKS", 10) + pad("SYNC TO", 44) + "LINKED")
        for l in lists {
            let items = try await store.items(in: l.id, hierarchy: ctx.hierarchy)
            let active = items.filter { !$0.fields.completed }.count
            let subtasks = items.filter { !$0.fields.completed && $0.parentID != nil }.count
            let target = ctx.config.resolve(list: l).map { r in
                let email = ctx.config.accounts[r.account]?.email ?? r.account
                return "\(email)\(r.googleListName == l.name ? "" : " as \"\(r.googleListName)\"")"
            } ?? "(not synced)"
            let linked = listLinks[l.id] != nil ? "\(counts[l.id] ?? 0) tasks" : "-"
            print(pad(l.groupName ?? "", 14) + pad(l.name, 28) + pad(String(active), 8) + pad(subtasks == 0 ? "" : String(subtasks), 10) + pad(target, 44) + linked)
        }
        if !ctx.hierarchy.isAvailable {
            print(usedCache ? "\nNote: Reminders database not readable; groups shown from the last run that could read it."
                            : "\nNote: Reminders database not readable and nothing cached, so groups are unknown. Only explicit 'lists' rules apply.")
        }
    }
}

// MARK: - google-lists

struct GoogleLists: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "google-lists", abstract: "Show the Google Tasks lists in each signed-in account.")
    @OptionGroup var common: CommonOptions

    func run() async throws {
        let ctx = try Context(common)
        let listLinks = try ctx.state.listLinks()
        for (key, acct) in ctx.config.accounts.sorted(by: { $0.key < $1.key }) {
            print("\(key) (\(acct.email))")
            guard try ctx.auth.storedTokens(account: key) != nil else { print("  not signed in (run: remtasks auth \(key))"); continue }
            let client = GoogleTasksClient(auth: ctx.auth, account: key)
            for l in try await client.lists() {
                let tasks = try await client.tasks(listID: l.id)
                let open = tasks.filter { !$0.fields.completed }.count
                let linked = listLinks.first { $0.googleListID == l.id }.map { "  <- Reminders \"\($0.name)\"" } ?? ""
                print("  \(pad(l.title, 30)) \(open) open, \(tasks.count - open) done\(linked)")
            }
        }
    }
}

// MARK: - google-tasks

struct GoogleTasks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "google-tasks", abstract: "Show the Google tasks in one list (by Reminders list name).")
    @OptionGroup var common: CommonOptions
    @Argument(help: "Reminders list name (the paired Google list is used).") var list: String
    @Flag(name: .long, help: "Include completed tasks.") var all = false

    func run() async throws {
        let ctx = try Context(common)
        guard let ll = try ctx.state.listLinks().first(where: { $0.name.caseInsensitiveCompare(list) == .orderedSame }) else {
            throw ValidationError("No paired Google list for '\(list)'. Run 'remtasks status' to see paired lists.")
        }
        let client = GoogleTasksClient(auth: ctx.auth, account: ll.account)
        let tasks = try await client.tasks(listID: ll.googleListID)
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let links = Dictionary(try ctx.state.links(forAppleList: ll.appleListID).map { ($0.googleID, $0) }, uniquingKeysWith: { a, _ in a })
        print("\(ll.name) -> \(ll.account): \(tasks.count) tasks (\(tasks.filter { !$0.fields.completed }.count) open)")
        for t in tasks.sorted(by: { ($0.parentID ?? $0.id, $0.parentID == nil ? "" : $0.position) < ($1.parentID ?? $1.id, $1.parentID == nil ? "" : $1.position) })
            where all || !t.fields.completed {
            let indent = t.parentID != nil ? "    " : "  "
            let mark = t.fields.completed ? "[x]" : "[ ]"
            let due = t.fields.dueDay.map { " due \($0)" } ?? ""
            let paired = links[t.id] != nil ? "" : "  (not paired)"
            let parent = t.parentID.flatMap { byID[$0] }.map { " (under \"\($0.fields.title)\")" } ?? ""
            print("\(indent)\(mark) \(t.fields.title)\(due)\(parent)\(paired)")
        }
    }
}

// MARK: - auth

struct Auth: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Sign in to a Google account named in the config (opens a browser).")
    @OptionGroup var common: CommonOptions
    @Argument(help: "Account key from config.json, e.g. personal or work.") var account: String
    @Flag(help: "Forget the stored token instead of signing in.") var signOut = false

    func run() async throws {
        let ctx = try Context(common)
        guard let acct = ctx.config.accounts[account] else {
            throw ValidationError("Unknown account '\(account)'. Configured: \(ctx.config.accounts.keys.sorted().joined(separator: ", "))")
        }
        if signOut {
            try ctx.auth.signOut(account: account)
            print("Signed out of \(account).")
            return
        }
        let tokens = try await ctx.auth.signIn(account: account, expectedEmail: acct.email)
        let lists = try await GoogleTasksClient(auth: ctx.auth, account: account).lists()
        print("Signed in to \(account) as \(tokens.email). Google Tasks lists: \(lists.map(\.title).joined(separator: ", "))")
    }
}

// MARK: - sync

struct Sync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run one sync pass.")
    @OptionGroup var common: CommonOptions
    @Flag(name: .long, help: "Print what would change without writing anything.") var dryRun = false
    @Flag(name: .long, help: "Permit deletions beyond safety.maxDeletesPerRun.") var allowDeletes = false
    @Option(name: .long, help: "Sync only this Reminders list.") var list: String?

    func run() async throws {
        let ctx = try Context(common)
        ctx.hierarchyWarnings.forEach(Log.warn)
        guard let lock = RunLock(directory: ctx.directory) else {
            throw RemTasksError("Another remtasks sync is already running.")
        }
        _ = lock
        let store = RemindersStore()
        try await store.requestAccess()
        let engine = SyncEngine(config: ctx.config, state: ctx.state, apple: store, auth: ctx.auth,
                                hierarchy: ctx.hierarchy, options: RunOptions(dryRun: dryRun, allowDeletes: allowDeletes, onlyList: list))
        let summary = try await engine.run()
        Log.info("Done: \(summary.text)")
        if !summary.errors.isEmpty { throw ExitCode(1) }
    }
}

// MARK: - status

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show recent runs and pairing counts.")
    @OptionGroup var common: CommonOptions

    func run() async throws {
        let ctx = try Context(common)
        let runs = try ctx.state.lastRuns(5)
        if runs.isEmpty { print("No sync runs recorded yet.") }
        for r in runs {
            print("\(Dates.short(r.startedAt))  \(pad(r.status, 7)) \(r.summary)")
        }
        let listLinks = try ctx.state.listLinks()
        let counts = try ctx.state.linkCounts()
        print("\nPaired lists: \(listLinks.count), paired tasks: \(try ctx.state.linkCount())")
        for ll in listLinks.sorted(by: { $0.name < $1.name }) {
            print("  \(pad(ll.name, 28)) \(pad(ll.account, 10)) \(counts[ll.appleListID] ?? 0) tasks")
        }
        let agent = FileManager.default.fileExists(atPath: Context.agentPlist.path)
        print("\nBackground agent: \(agent ? "installed (\(Context.agentPlist.path))" : "not installed")")
    }
}

// MARK: - doctor

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check configuration, permissions, and credentials.")
    @OptionGroup var common: CommonOptions

    func run() async throws {
        var problems = 0
        func ok(_ s: String) { print("  ok    \(s)") }
        func bad(_ s: String) { print("  FAIL  \(s)"); problems += 1 }
        func note(_ s: String) { print("  note  \(s)") }

        let ctx: Context
        do { ctx = try Context(common); ok("config loaded from \(ctx.directory.path)") }
        catch { bad("config: \(error)"); throw ExitCode(1) }

        if FileManager.default.fileExists(atPath: ctx.config.clientSecretURL.path) { ok("Google OAuth client file present") }
        else { bad("Google OAuth client file missing at \(ctx.config.clientSecretURL.path)") }

        for (key, acct) in ctx.config.accounts.sorted(by: { $0.key < $1.key }) {
            do {
                guard let t = try ctx.auth.storedTokens(account: key) else { bad("account \(key): not signed in (run: remtasks auth \(key))"); continue }
                if t.email.caseInsensitiveCompare(acct.email) != .orderedSame { bad("account \(key): token is for \(t.email), config says \(acct.email)"); continue }
                _ = try await ctx.auth.accessToken(account: key, force: true)
                let lists = try await GoogleTasksClient(auth: ctx.auth, account: key).lists()
                ok("account \(key) (\(acct.email)): token valid, \(lists.count) Google Tasks lists")
            } catch { bad("account \(key): \(error)") }
        }

        switch RemindersStore.authorizationStatus {
        case .fullAccess: ok("Reminders access granted")
        case .notDetermined: note("Reminders access not yet requested; run 'remtasks lists' to trigger the prompt")
        default: bad("Reminders access denied: System Settings > Privacy & Security > Reminders")
        }

        if ctx.hierarchy.isAvailable {
            ok("Reminders database readable (\(ctx.hierarchy.parentByReminderID.count) subtask links, \(ctx.hierarchy.groupByListName.count) grouped lists)")
        } else {
            bad("Reminders database not readable: subtasks and group mapping unavailable")
            ctx.hierarchyWarnings.forEach { note($0) }
        }

        if RemindersStore.authorizationStatus == .fullAccess {
            let store = RemindersStore()
            do {
                let source = try store.source(titled: ctx.config.remindersSource)
                let lists = store.lists(in: source, hierarchy: ctx.hierarchy)
                let mapped = lists.filter { ctx.config.resolve(list: $0) != nil }
                ok("Reminders source '\(source.title)': \(lists.count) lists, \(mapped.count) mapped")
                for l in lists where ctx.config.resolve(list: l) == nil { note("not synced: \(l.name)") }
            } catch { bad("\(error)") }
        }

        ok("state database at \(ctx.state.path) (\(try ctx.state.linkCount()) pairings)")
        if FileManager.default.fileExists(atPath: Context.agentPlist.path) { ok("launchd agent installed") }
        else { note("launchd agent not installed (run: remtasks install-agent)") }

        print(problems == 0 ? "\nAll checks passed." : "\n\(problems) problem(s).")
        if problems > 0 { throw ExitCode(1) }
    }
}

// MARK: - install-agent / uninstall-agent

struct InstallAgent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install-agent", abstract: "Install a launchd agent that runs 'remtasks sync' periodically.")
    @OptionGroup var common: CommonOptions
    @Option(name: .long, help: "Seconds between runs.") var interval: Int = 300

    func run() async throws {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let exePath = exe.path.hasPrefix("/") ? exe.path : FileManager.default.currentDirectoryPath + "/" + exe.path
        try FileManager.default.createDirectory(at: Context.logDirectory, withIntermediateDirectories: true)
        var args = [exePath, "sync"]
        if let c = common.config { args += ["--config", Config.expandTilde(c)] }
        let argXML = args.map { "        <string>\($0.xmlEscaped)</string>" }.joined(separator: "\n")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(Context.agentLabel)</string>
            <key>ProgramArguments</key>
            <array>
        \(argXML)
            </array>
            <key>StartInterval</key>
            <integer>\(interval)</integer>
            <key>RunAtLoad</key>
            <true/>
            <key>ProcessType</key>
            <string>Background</string>
            <key>StandardOutPath</key>
            <string>\(Context.logDirectory.appendingPathComponent("agent.log").path)</string>
            <key>StandardErrorPath</key>
            <string>\(Context.logDirectory.appendingPathComponent("agent.log").path)</string>
        </dict>
        </plist>
        """
        try FileManager.default.createDirectory(at: Context.agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(Context.agentLabel)"])
        try plist.write(to: Context.agentPlist, atomically: true, encoding: .utf8)
        let rc = shell("/bin/launchctl", ["bootstrap", "gui/\(getuid())", Context.agentPlist.path])
        guard rc == 0 else { throw RemTasksError("launchctl bootstrap failed (\(rc))") }
        print("Installed \(Context.agentPlist.path); runs '\(exePath) sync' every \(interval)s. Logs: \(Context.logDirectory.path)")
        print("If the agent cannot read the Reminders database, grant Full Disk Access to \(exePath) in System Settings > Privacy & Security.")
    }
}

struct UninstallAgent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uninstall-agent", abstract: "Remove the launchd agent.")

    func run() async throws {
        _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(Context.agentLabel)"])
        try? FileManager.default.removeItem(at: Context.agentPlist)
        print("Removed \(Context.agentPlist.path)")
    }
}

@discardableResult
func shell(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
