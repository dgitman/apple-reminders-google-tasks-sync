import Foundation

/// Facts EventKit does not expose, read directly (read-only) from the Reminders app's
/// own SQLite stores: subtask parent relationships and list group membership.
///
/// If the stores cannot be read (e.g. no Full Disk Access for a launchd agent), sync still
/// works — hierarchy is simply not synced and groups can't be used for account mapping.
public struct RemindersHierarchy {
    public var isAvailable: Bool
    /// child reminder UUID (uppercase) -> parent reminder UUID (uppercase)
    public var parentByReminderID: [String: String] = [:]
    /// list UUID (uppercase) -> group name
    public var groupByListID: [String: String] = [:]
    /// list name -> group name (fallback when identifiers don't line up)
    public var groupByListName: [String: String] = [:]

    public init(isAvailable: Bool) { self.isAvailable = isAvailable }

    public static let unavailable = RemindersHierarchy(isAvailable: false)

    public func parentUUID(of reminderID: String, externalID: String?) -> String? {
        if let p = parentByReminderID[reminderID.uppercased()] { return p }
        if let ext = externalID, let uuid = RemindersDatabase.uuid(fromExternalID: ext),
           let p = parentByReminderID[uuid] { return p }
        return nil
    }

    public func group(forListID listID: String, name: String) -> String? {
        groupByListID[listID.uppercased()] ?? groupByListName[name]
    }
}

public enum RemindersDatabase {

    public static var defaultStoreDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.reminders/Container_v1/Stores", isDirectory: true)
    }

    /// "x-apple-reminderkit://REMCDReminder/<UUID>" -> "<UUID>"
    public static func uuid(fromExternalID ext: String) -> String? {
        guard let last = ext.split(separator: "/").last else { return nil }
        let s = String(last).uppercased()
        return s.count == 36 ? s : nil
    }

    /// Reads every account store in the directory and merges them.
    public static func load(overridePath: String? = nil) -> (RemindersHierarchy, warnings: [String]) {
        var warnings: [String] = []
        var paths: [String] = []
        if let o = overridePath {
            paths = [Config.expandTilde(o)]
        } else {
            let dir = defaultStoreDirectory
            if let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                paths = names.filter { $0.hasPrefix("Data-") && $0.hasSuffix(".sqlite") && $0 != "Data-local.sqlite" }
                    .map { dir.appendingPathComponent($0).path }
            }
        }
        guard !paths.isEmpty else {
            let exists = FileManager.default.fileExists(atPath: defaultStoreDirectory.path)
            warnings.append(exists
                ? "Reminders database at \(defaultStoreDirectory.path) is not readable from this process (Full Disk Access needed for launchd runs)."
                : "Reminders database not found under \(defaultStoreDirectory.path); subtasks and groups unavailable.")
            return (.unavailable, warnings)
        }

        var h = RemindersHierarchy(isAvailable: false)
        for path in paths {
            do {
                let db = try SQLiteDB(path: path, readOnly: true)
                let lists = try db.run("""
                    SELECT l.ZCKIDENTIFIER AS id, l.ZNAME AS name, g.ZNAME AS grp
                    FROM ZREMCDBASELIST l LEFT JOIN ZREMCDBASELIST g ON g.Z_PK = l.ZPARENTLIST
                    WHERE l.ZISGROUP = 0 AND l.ZMARKEDFORDELETION = 0 AND l.ZNAME IS NOT NULL
                    """)
                for r in lists {
                    guard let grp = r["grp"].string, let name = r["name"].string else { continue }
                    if let id = r["id"].string { h.groupByListID[id.uppercased()] = grp }
                    h.groupByListName[name] = grp
                }
                let parents = try db.run("""
                    SELECT r.ZCKIDENTIFIER AS id, p.ZCKIDENTIFIER AS parent
                    FROM ZREMCDREMINDER r JOIN ZREMCDREMINDER p ON p.Z_PK = r.ZPARENTREMINDER
                    WHERE r.ZMARKEDFORDELETION = 0 AND p.ZMARKEDFORDELETION = 0
                    """)
                for r in parents {
                    if let id = r["id"].string, let p = r["parent"].string {
                        h.parentByReminderID[id.uppercased()] = p.uppercased()
                    }
                }
                h.isAvailable = true
            } catch {
                warnings.append("Cannot read Reminders store \((path as NSString).lastPathComponent): \(error). If running from launchd, grant Full Disk Access to remtasks.")
            }
        }
        return (h, warnings)
    }
}
