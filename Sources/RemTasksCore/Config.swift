import Foundation

/// User configuration, loaded from ~/.config/remtasks/config.json (or a path given on the command line).
public struct Config: Codable, Equatable {

    public struct Account: Codable, Equatable {
        public var email: String
        public init(email: String) { self.email = email }
    }

    public struct ListRule: Codable, Equatable {
        public var account: String?
        public var googleListName: String?
        public var skip: Bool?
        public init(account: String? = nil, googleListName: String? = nil, skip: Bool? = nil) {
            self.account = account; self.googleListName = googleListName; self.skip = skip
        }
    }

    public struct NewTaskDefaults: Codable, Equatable {
        /// Time of day applied to reminders created from Google tasks that have a due date. nil = all-day.
        public var dueTime: String?
        /// Add an alarm at the due time for reminders created from Google tasks.
        public var alarm: Bool
        public init(dueTime: String? = "09:00", alarm: Bool = true) { self.dueTime = dueTime; self.alarm = alarm }
        public var timeOfDay: TimeOfDay? { dueTime.flatMap(TimeOfDay.init(string:)) }
    }

    public struct Safety: Codable, Equatable {
        /// Deleting more than this many tasks in one run requires --allow-deletes.
        public var maxDeletesPerRun: Int
        /// Propagate list deletions (Apple list removed -> Google list removed, and vice versa).
        public var deleteLists: Bool
        public init(maxDeletesPerRun: Int = 20, deleteLists: Bool = false) {
            self.maxDeletesPerRun = maxDeletesPerRun; self.deleteLists = deleteLists
        }
    }

    public struct Google: Codable, Equatable {
        /// OAuth "Desktop app" client JSON downloaded from Google Cloud Console.
        public var clientSecretFile: String
        /// "file" (0600 JSON under the config dir) or "keychain".
        public var tokenStorage: String
        public init(clientSecretFile: String = "~/.config/remtasks/google-client.json", tokenStorage: String = "file") {
            self.clientSecretFile = clientSecretFile; self.tokenStorage = tokenStorage
        }
    }

    public var accounts: [String: Account]
    /// Reminders group name -> account key.
    public var groups: [String: String]
    /// Reminders list name -> rule. Takes precedence over `groups`.
    public var lists: [String: ListRule]
    /// Name of the Reminders account/source to sync (matches EKSource.title). Default "iCloud".
    public var remindersSource: String
    public var newTaskDefaults: NewTaskDefaults
    public var safety: Safety
    public var google: Google
    /// Optional path override for the Reminders SQLite store used for subtask hierarchy and groups.
    public var remindersDatabase: String?
    /// Completed items older than this many days are left alone on both sides (not created, not deleted).
    public var completedHistoryDays: Int

    public init(accounts: [String: Account], groups: [String: String] = [:], lists: [String: ListRule] = [:],
                remindersSource: String = "iCloud", newTaskDefaults: NewTaskDefaults = .init(),
                safety: Safety = .init(), google: Google = .init(), remindersDatabase: String? = nil,
                completedHistoryDays: Int = 30) {
        self.accounts = accounts; self.groups = groups; self.lists = lists
        self.remindersSource = remindersSource; self.newTaskDefaults = newTaskDefaults
        self.safety = safety; self.google = google; self.remindersDatabase = remindersDatabase
        self.completedHistoryDays = completedHistoryDays
    }

    // Codable with defaults for optional sections
    enum CodingKeys: String, CodingKey {
        case accounts, groups, lists, remindersSource, newTaskDefaults, safety, google, remindersDatabase, completedHistoryDays
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decode([String: Account].self, forKey: .accounts)
        groups = try c.decodeIfPresent([String: String].self, forKey: .groups) ?? [:]
        lists = try c.decodeIfPresent([String: ListRule].self, forKey: .lists) ?? [:]
        remindersSource = try c.decodeIfPresent(String.self, forKey: .remindersSource) ?? "iCloud"
        newTaskDefaults = try c.decodeIfPresent(NewTaskDefaults.self, forKey: .newTaskDefaults) ?? .init()
        safety = try c.decodeIfPresent(Safety.self, forKey: .safety) ?? .init()
        google = try c.decodeIfPresent(Google.self, forKey: .google) ?? .init()
        remindersDatabase = try c.decodeIfPresent(String.self, forKey: .remindersDatabase)
        completedHistoryDays = try c.decodeIfPresent(Int.self, forKey: .completedHistoryDays) ?? 30
    }

    // MARK: Loading

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/remtasks", isDirectory: true)
    }

    public static func load(from path: String? = nil) throws -> Config {
        let url = path.map { URL(fileURLWithPath: expandTilde($0)) } ?? defaultDirectory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RemTasksError("Config not found at \(url.path). Copy config.example.json there and edit it.")
        }
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(Config.self, from: data)
        try config.validate()
        return config
    }

    public func validate() throws {
        if accounts.isEmpty { throw RemTasksError("Config has no accounts.") }
        for (group, key) in groups where accounts[key] == nil {
            throw RemTasksError("Group '\(group)' maps to unknown account '\(key)'.")
        }
        for (list, rule) in lists {
            if let key = rule.account, accounts[key] == nil {
                throw RemTasksError("List '\(list)' maps to unknown account '\(key)'.")
            }
            if rule.account == nil && rule.skip != true && rule.googleListName != nil {
                // fine — account may come from the group
            }
        }
        if let t = newTaskDefaults.dueTime, TimeOfDay(string: t) == nil {
            throw RemTasksError("newTaskDefaults.dueTime '\(t)' is not HH:MM.")
        }
        if completedHistoryDays < 0 { throw RemTasksError("completedHistoryDays must be 0 or more.") }
        if !["file", "keychain"].contains(google.tokenStorage) {
            throw RemTasksError("google.tokenStorage must be 'file' or 'keychain'.")
        }
    }

    // MARK: Mapping

    public struct Resolved: Equatable {
        public var account: String
        public var googleListName: String
        public init(account: String, googleListName: String) { self.account = account; self.googleListName = googleListName }
    }

    /// Where an Apple list should sync to, or nil to skip it.
    public func resolve(list: AppleList) -> Resolved? {
        if let rule = lists[list.name] {
            if rule.skip == true { return nil }
            let account = rule.account ?? list.groupName.flatMap { groups[$0] }
            guard let account else { return nil }
            return Resolved(account: account, googleListName: rule.googleListName ?? list.name)
        }
        if let group = list.groupName, let account = groups[group] {
            return Resolved(account: account, googleListName: list.name)
        }
        return nil
    }

    public static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    public var clientSecretURL: URL { URL(fileURLWithPath: Config.expandTilde(google.clientSecretFile)) }
}
