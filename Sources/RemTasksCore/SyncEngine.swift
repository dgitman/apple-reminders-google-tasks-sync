import Foundation

public struct RunOptions {
    public var dryRun: Bool
    public var allowDeletes: Bool
    public var onlyList: String?
    public init(dryRun: Bool = false, allowDeletes: Bool = false, onlyList: String? = nil) {
        self.dryRun = dryRun; self.allowDeletes = allowDeletes; self.onlyList = onlyList
    }
}

public struct RunSummary {
    public var counts: [String: Int] = [:]
    public var warnings: [String] = []
    public var errors: [String] = []
    public var listsSynced = 0
    public var dryRun = false

    public var changed: Int { counts.values.reduce(0, +) }
    public var text: String {
        var parts = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        if parts.isEmpty { parts = ["no changes"] }
        var s = "\(dryRun ? "[dry run] " : "")\(listsSynced) lists, \(parts.joined(separator: " "))"
        if !warnings.isEmpty { s += ", \(warnings.count) warnings" }
        if !errors.isEmpty { s += ", \(errors.count) errors" }
        return s
    }
}

/// Orchestrates one sync run across all mapped lists.
public final class SyncEngine {
    private let config: Config
    private let state: StateStore
    private let apple: RemindersStore
    private let auth: GoogleAuth
    private let hierarchy: RemindersHierarchy
    private let options: RunOptions
    private var clients: [String: GoogleTasksClient] = [:]
    private var summary = RunSummary()

    private static let pendingListID = "(new)"

    public init(config: Config, state: StateStore, apple: RemindersStore, auth: GoogleAuth,
                hierarchy: RemindersHierarchy, options: RunOptions) {
        self.config = config; self.state = state; self.apple = apple; self.auth = auth
        self.hierarchy = hierarchy; self.options = options
    }

    private var dryRun: Bool { options.dryRun }

    private func client(_ account: String) -> GoogleTasksClient {
        if let c = clients[account] { return c }
        let c = GoogleTasksClient(auth: auth, account: account)
        clients[account] = c
        return c
    }

    private func count(_ key: String) { summary.counts[key, default: 0] += 1 }
    private func warn(_ m: String) { Log.warn(m); summary.warnings.append(m) }

    // MARK: Run

    public func run() async throws -> RunSummary {
        summary = RunSummary()
        summary.dryRun = dryRun
        let started = Date()

        let source = try apple.source(titled: config.remindersSource)
        try bindIdentity(sourceID: source.sourceIdentifier)

        let (appleLists, usedCache) = try state.listsWithGroups(apple.lists(in: source, hierarchy: hierarchy), hierarchy: hierarchy)
        var pairs: [(AppleList, Config.Resolved)] = []
        for l in appleLists {
            if let r = config.resolve(list: l) { pairs.append((l, r)) }
            else { Log.debug("Skipping unmapped list '\(l.name)'\(l.groupName.map { " (group \($0))" } ?? "")") }
        }
        if let only = options.onlyList {
            pairs = pairs.filter { $0.0.name.caseInsensitiveCompare(only) == .orderedSame }
            if pairs.isEmpty { throw RemTasksError("No mapped list named '\(only)'") }
        }
        if !hierarchy.isAvailable {
            if usedCache {
                warn("Reminders database unreadable: using cached group membership; subtasks are not synced this run. Grant Full Disk Access to remtasks to fix.")
            } else if !config.groups.isEmpty {
                warn("Reminders database unreadable and no cached group membership yet: group-based mapping and subtasks are off this run. Run 'remtasks lists' once from a terminal to cache groups, or grant Full Disk Access to remtasks.")
            }
        }

        var googleLists: [String: [GoogleList]] = [:]
        for account in Set(pairs.map { $0.1.account }).sorted() {
            googleLists[account] = try await client(account).lists()
        }

        try await reconcileDeletedAppleLists(appleLists: appleLists, googleLists: googleLists)

        for (list, resolved) in pairs {
            do {
                guard let googleListID = try await resolveGoogleList(for: list, resolved: resolved, googleLists: &googleLists) else { continue }
                try await syncTasks(list: list, googleListID: googleListID, account: resolved.account)
                summary.listsSynced += 1
            } catch {
                let msg = "List '\(list.name)': \(error)"
                Log.error(msg)
                summary.errors.append(msg)
            }
        }

        if !dryRun {
            try state.recordRun(.init(startedAt: started, finishedAt: Date(),
                                      status: summary.errors.isEmpty ? "ok" : "errors", summary: summary.text))
        }
        return summary
    }

    // MARK: Identity binding

    private func bindIdentity(sourceID: String) throws {
        let key = "apple_source_id"
        if let stored = try state.meta(key), stored != sourceID {
            throw RemTasksError("Sync state was created for a different Reminders account. Delete \(state.path) to start over.")
        }
        for (key, acct) in config.accounts {
            guard let tokens = try auth.storedTokens(account: key) else {
                throw RemTasksError("Account '\(key)' (\(acct.email)) is not signed in. Run: remtasks auth \(key)")
            }
            if tokens.email.caseInsensitiveCompare(acct.email) != .orderedSame {
                throw RemTasksError("Account '\(key)' is signed in as \(tokens.email) but config says \(acct.email). Run: remtasks auth \(key)")
            }
            let metaKey = "google_email_\(key)"
            if let stored = try state.meta(metaKey), stored.caseInsensitiveCompare(acct.email) != .orderedSame {
                throw RemTasksError("Sync state for account '\(key)' was created for \(stored), config now says \(acct.email). Delete \(state.path) to start over.")
            }
            if !dryRun { try state.setMeta(metaKey, acct.email) }
        }
        if !dryRun { try state.setMeta(key, sourceID) }
    }

    // MARK: Lists

    /// Apple lists that were linked before but no longer exist.
    private func reconcileDeletedAppleLists(appleLists: [AppleList], googleLists: [String: [GoogleList]]) async throws {
        guard options.onlyList == nil else { return }
        let appleIDs = Set(appleLists.map(\.id))
        for ll in try state.listLinks() where !appleIDs.contains(ll.appleListID) {
            guard let gl = googleLists[ll.account] else { continue } // account not in play this run
            guard let g = gl.first(where: { $0.id == ll.googleListID }) else {
                Log.info("List '\(ll.name)' is gone on both sides; forgetting it.")
                if !dryRun { try state.deleteLinks(forAppleList: ll.appleListID); try state.deleteListLink(appleListID: ll.appleListID) }
                continue
            }
            if config.safety.deleteLists {
                let tasks = try await client(ll.account).tasks(listID: g.id)
                let active = tasks.filter { !$0.fields.completed }.count
                if active > config.safety.maxDeletesPerRun && !options.allowDeletes {
                    warn("Apple list '\(ll.name)' was deleted, but Google list '\(g.title)' still has \(active) open tasks. Re-run with --allow-deletes to delete it.")
                    continue
                }
                Log.info("Apple list '\(ll.name)' was deleted: deleting Google list '\(g.title)' (\(tasks.count) tasks)")
                if !dryRun {
                    try await client(ll.account).deleteList(id: g.id)
                    try state.deleteLinks(forAppleList: ll.appleListID)
                    try state.deleteListLink(appleListID: ll.appleListID)
                }
                count("listDelete")
            } else {
                warn("Apple list '\(ll.name)' was deleted. safety.deleteLists is false, so Google list '\(g.title)' is kept and unlinked.")
                if !dryRun { try state.deleteLinks(forAppleList: ll.appleListID); try state.deleteListLink(appleListID: ll.appleListID) }
            }
        }
    }

    /// Returns the Google list id to sync with, creating or re-linking as needed; nil to skip this list.
    private func resolveGoogleList(for list: AppleList, resolved: Config.Resolved,
                                   googleLists: inout [String: [GoogleList]]) async throws -> String? {
        let account = resolved.account
        let c = client(account)
        var existing = try state.listLinks().first { $0.appleListID == list.id }

        if let e = existing, e.account != account {
            warn("List '\(list.name)' moved from account '\(e.account)' to '\(account)'. Its tasks will be created in the new account; the old Google list is left as is.")
            if !dryRun { try state.deleteLinks(forAppleList: list.id); try state.deleteListLink(appleListID: list.id) }
            existing = nil
        }

        let gl = googleLists[account] ?? []
        if let e = existing, let g = gl.first(where: { $0.id == e.googleListID }) {
            if g.title != resolved.googleListName {
                Log.info("Renaming Google list '\(g.title)' -> '\(resolved.googleListName)'")
                if !dryRun { try await c.renameList(id: g.id, title: resolved.googleListName) }
                count("listRename")
            }
            return g.id
        }

        if existing != nil {
            // Linked Google list no longer exists.
            if config.safety.deleteLists {
                let active = try await apple.items(in: list.id, hierarchy: hierarchy).filter { !$0.fields.completed }.count
                if active > config.safety.maxDeletesPerRun && !options.allowDeletes {
                    warn("Google list for '\(list.name)' was deleted, but the Apple list still has \(active) open reminders. Re-run with --allow-deletes to delete it.")
                    return nil
                }
                Log.info("Google list for '\(list.name)' was deleted: deleting the Apple list")
                if !dryRun {
                    try apple.deleteList(id: list.id)
                    try state.deleteLinks(forAppleList: list.id)
                    try state.deleteListLink(appleListID: list.id)
                }
                count("listDelete")
                return nil
            }
            warn("Google list for '\(list.name)' was deleted. safety.deleteLists is false, so it will be re-created from Apple.")
            if !dryRun { try state.deleteLinks(forAppleList: list.id) }
        }

        var googleListID: String
        if let g = gl.first(where: { $0.title == resolved.googleListName }) {
            googleListID = g.id
        } else {
            Log.info("Creating Google list '\(resolved.googleListName)' in \(account)")
            count("listCreate")
            if dryRun { return Self.pendingListID }
            let g = try await c.createList(title: resolved.googleListName)
            googleLists[account, default: []].append(g)
            googleListID = g.id
        }
        if !dryRun {
            try state.upsertListLink(ListLink(appleListID: list.id, googleListID: googleListID, account: account, name: list.name))
        }
        return googleListID
    }

    // MARK: Tasks

    private func syncTasks(list: AppleList, googleListID: String, account: String) async throws {
        let c = client(account)
        let allApple = try await apple.items(in: list.id, hierarchy: hierarchy)
        let allGoogle = googleListID == Self.pendingListID ? [] : try await c.tasks(listID: googleListID)
        let allLinks = try state.links(forAppleList: list.id)
        let cutoff = Date().addingTimeInterval(-Double(config.completedHistoryDays) * 86_400)
        let scope = SyncScope.partition(apple: allApple, google: allGoogle, links: allLinks, cutoff: cutoff)
        if !scope.forget.isEmpty {
            Log.debug("[\(list.name)] forgetting \(scope.forget.count) pairings of old completed items")
            if !dryRun { for l in scope.forget { try state.deleteLink(appleID: l.appleID) } }
        }
        let (appleItems, googleItems, links) = (scope.apple, scope.google, scope.links)
        let plan = SyncPlanner.plan(apple: appleItems, google: googleItems, links: links,
                                    options: PlanOptions(allowDeletes: options.allowDeletes,
                                                         maxDeletes: config.safety.maxDeletesPerRun,
                                                         hierarchyAvailable: hierarchy.isAvailable))
        for w in plan.warnings { warn("[\(list.name)] \(w)") }
        Log.debug("[\(list.name)] apple=\(appleItems.count)/\(allApple.count) google=\(googleItems.count)/\(allGoogle.count) links=\(links.count) actions=\(plan.actions.count)")

        for action in plan.actions {
            Log.info("[\(list.name)] \(action.summary)")
            count(action.kind)
            if dryRun { continue }
            do {
                try await execute(action, list: list, googleListID: googleListID, account: account, client: c)
            } catch {
                let msg = "[\(list.name)] \(action.summary) failed: \(error)"
                Log.error(msg)
                summary.errors.append(msg)
            }
        }
    }

    private func execute(_ action: SyncAction, list: AppleList, googleListID: String, account: String, client c: GoogleTasksClient) async throws {
        let now = Date()
        func link(apple a: AppleItem, google g: GoogleItem, fields: SyncFields) -> Link {
            Link(appleID: a.id, googleID: g.id, account: account, appleListID: list.id, googleListID: googleListID,
                 fingerprint: fields.fingerprint, dueDay: fields.dueDay,
                 appleParentID: a.parentID, googleParentID: g.parentID, lastSyncAt: now)
        }
        func googleParent(for a: AppleItem) throws -> String? {
            guard let p = a.parentID else { return nil }
            return try state.link(forApple: p)?.googleID
        }

        switch action {
        case .createGoogle(let a):
            let g = try await c.createTask(listID: googleListID, fields: a.fields, parent: try googleParent(for: a))
            try state.upsert(link(apple: a, google: g, fields: a.fields))

        case .createApple(let g), .restoreApple(_, let g):
            if case .restoreApple(let old, _) = action { try state.deleteLink(appleID: old.appleID) }
            let due = appleDue(google: g, apple: nil)
            let a = try apple.createReminder(listID: list.id, fields: g.fields, due: due, addAlarm: config.newTaskDefaults.alarm)
            try state.upsert(link(apple: a, google: g, fields: g.fields))

        case .adopt(let a, let g, let winner):
            switch winner {
            case .none:
                try state.upsert(link(apple: a, google: g, fields: a.fields))
            case .apple:
                let g2 = try await c.updateTask(listID: googleListID, id: g.id, fields: a.fields)
                try state.upsert(link(apple: a, google: g2, fields: a.fields))
            case .google:
                let a2 = try apple.updateReminder(id: a.id, fields: g.fields, due: appleDue(google: g, apple: a), addAlarm: config.newTaskDefaults.alarm)
                try state.upsert(link(apple: a2, google: g, fields: g.fields))
            }

        case .updateGoogle(_, let a, let g):
            let g2 = try await c.updateTask(listID: googleListID, id: g.id, fields: a.fields)
            try state.upsert(link(apple: a, google: g2, fields: a.fields))

        case .updateApple(_, let g, let a):
            let a2 = try apple.updateReminder(id: a.id, fields: g.fields, due: appleDue(google: g, apple: a), addAlarm: config.newTaskDefaults.alarm)
            try state.upsert(link(apple: a2, google: g, fields: g.fields))

        case .deleteGoogle(let l, let g):
            try await c.deleteTask(listID: googleListID, id: g.id)
            try state.deleteLink(appleID: l.appleID)

        case .deleteApple(let l, let a):
            try apple.deleteReminder(id: a.id)
            try state.deleteLink(appleID: l.appleID)

        case .restoreGoogle(let old, let a):
            try state.deleteLink(appleID: old.appleID)
            let g = try await c.createTask(listID: googleListID, fields: a.fields, parent: try googleParent(for: a))
            try state.upsert(link(apple: a, google: g, fields: a.fields))

        case .rollForward(let old, let a, let g):
            // Old Google task stays completed as history; a fresh task represents the next occurrence.
            let g2 = try await c.createTask(listID: googleListID, fields: a.fields, parent: g.parentID)
            try state.deleteLink(appleID: old.appleID)
            try state.upsert(link(apple: a, google: g2, fields: a.fields))

        case .moveGoogle(let l, let g, let parent):
            let g2 = try await c.moveTask(listID: googleListID, id: g.id, parent: parent)
            var l2 = l
            l2.googleParentID = g2.parentID
            if let parent {
                if l2.appleParentID == nil { l2.appleParentID = try state.link(forGoogle: parent)?.appleID }
            } else {
                l2.appleParentID = nil
            }
            l2.lastSyncAt = now
            try state.upsert(l2)

        case .unlink(let l):
            try state.deleteLink(appleID: l.appleID)
        }
    }

    /// The due date to write into Apple when Google's date wins. Google only has a day, so keep
    /// Apple's existing time-of-day; for brand-new reminders apply the configured default time.
    func appleDue(google g: GoogleItem, apple a: AppleItem?) -> DueDate? {
        guard let day = g.due else { return nil }
        if let a, let ad = a.due { return day.keepingTime(of: ad) }
        if let t = config.newTaskDefaults.timeOfDay { return day.withTime(hour: t.hour, minute: t.minute) }
        return day
    }
}
