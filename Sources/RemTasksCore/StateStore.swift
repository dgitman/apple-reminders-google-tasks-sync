import Foundation

/// Local sync state: which reminder is paired with which Google task, plus list pairings,
/// identity binding, and a run history. Lives in ~/.config/remtasks/state.sqlite.
public final class StateStore {
    private let db: SQLiteDB
    public let path: String

    public init(path: String) throws {
        self.path = path
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        db = try SQLiteDB(path: path)
        try db.exec("PRAGMA journal_mode=WAL;")
        try migrate()
    }

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS links (
            apple_id TEXT PRIMARY KEY,
            google_id TEXT NOT NULL UNIQUE,
            account TEXT NOT NULL,
            apple_list_id TEXT NOT NULL,
            google_list_id TEXT NOT NULL,
            fingerprint TEXT NOT NULL,
            due_day TEXT,
            apple_parent_id TEXT,
            google_parent_id TEXT,
            last_sync_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS links_apple_list ON links(apple_list_id);
        CREATE TABLE IF NOT EXISTS list_links (
            apple_list_id TEXT PRIMARY KEY,
            google_list_id TEXT NOT NULL,
            account TEXT NOT NULL,
            name TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS runs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            started_at REAL NOT NULL,
            finished_at REAL NOT NULL,
            status TEXT NOT NULL,
            summary TEXT NOT NULL
        );
        """)
    }

    // MARK: Transactions

    public func begin() throws { try db.exec("BEGIN IMMEDIATE;") }
    public func commit() throws { try db.exec("COMMIT;") }
    public func rollback() { try? db.exec("ROLLBACK;") }

    // MARK: Links

    private func link(from r: SQLiteDB.Row) -> Link {
        Link(appleID: r["apple_id"].string ?? "",
             googleID: r["google_id"].string ?? "",
             account: r["account"].string ?? "",
             appleListID: r["apple_list_id"].string ?? "",
             googleListID: r["google_list_id"].string ?? "",
             fingerprint: r["fingerprint"].string ?? "",
             dueDay: r["due_day"].string,
             appleParentID: r["apple_parent_id"].string,
             googleParentID: r["google_parent_id"].string,
             lastSyncAt: Date(timeIntervalSince1970: r["last_sync_at"].double ?? 0))
    }

    public func links(forAppleList listID: String) throws -> [Link] {
        try db.run("SELECT * FROM links WHERE apple_list_id = ?", [listID]).map(link(from:))
    }

    public func allLinks() throws -> [Link] {
        try db.run("SELECT * FROM links").map(link(from:))
    }

    public func link(forApple appleID: String) throws -> Link? {
        try db.run("SELECT * FROM links WHERE apple_id = ?", [appleID]).first.map(link(from:))
    }

    public func link(forGoogle googleID: String) throws -> Link? {
        try db.run("SELECT * FROM links WHERE google_id = ?", [googleID]).first.map(link(from:))
    }

    public func upsert(_ l: Link) throws {
        // A Google task id can only be linked once; drop any stale row that still claims it.
        try db.run("DELETE FROM links WHERE google_id = ? AND apple_id <> ?", [l.googleID, l.appleID])
        try db.run("""
        INSERT INTO links (apple_id, google_id, account, apple_list_id, google_list_id, fingerprint, due_day,
                           apple_parent_id, google_parent_id, last_sync_at)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(apple_id) DO UPDATE SET
            google_id=excluded.google_id, account=excluded.account, apple_list_id=excluded.apple_list_id,
            google_list_id=excluded.google_list_id, fingerprint=excluded.fingerprint, due_day=excluded.due_day,
            apple_parent_id=excluded.apple_parent_id, google_parent_id=excluded.google_parent_id,
            last_sync_at=excluded.last_sync_at
        """, [l.appleID, l.googleID, l.account, l.appleListID, l.googleListID, l.fingerprint, l.dueDay,
              l.appleParentID, l.googleParentID, l.lastSyncAt])
    }

    public func deleteLink(appleID: String) throws {
        try db.run("DELETE FROM links WHERE apple_id = ?", [appleID])
    }

    public func deleteLinks(forAppleList listID: String) throws {
        try db.run("DELETE FROM links WHERE apple_list_id = ?", [listID])
    }

    public func linkCount() throws -> Int {
        Int(try db.run("SELECT COUNT(*) AS n FROM links").first?["n"].int ?? 0)
    }

    public func linkCounts() throws -> [String: Int] {
        var out: [String: Int] = [:]
        for r in try db.run("SELECT apple_list_id, COUNT(*) AS n FROM links GROUP BY apple_list_id") {
            out[r["apple_list_id"].string ?? ""] = Int(r["n"].int ?? 0)
        }
        return out
    }

    // MARK: List links

    public func listLinks() throws -> [ListLink] {
        try db.run("SELECT * FROM list_links").map {
            ListLink(appleListID: $0["apple_list_id"].string ?? "", googleListID: $0["google_list_id"].string ?? "",
                     account: $0["account"].string ?? "", name: $0["name"].string ?? "")
        }
    }

    public func upsertListLink(_ l: ListLink) throws {
        try db.run("""
        INSERT INTO list_links (apple_list_id, google_list_id, account, name) VALUES (?,?,?,?)
        ON CONFLICT(apple_list_id) DO UPDATE SET google_list_id=excluded.google_list_id, account=excluded.account, name=excluded.name
        """, [l.appleListID, l.googleListID, l.account, l.name])
    }

    public func deleteListLink(appleListID: String) throws {
        try db.run("DELETE FROM list_links WHERE apple_list_id = ?", [appleListID])
    }

    // MARK: Meta

    public func meta(_ key: String) throws -> String? {
        try db.run("SELECT value FROM meta WHERE key = ?", [key]).first?["value"].string
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO meta (key, value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value])
    }

    // MARK: Runs

    public struct Run {
        public var startedAt: Date
        public var finishedAt: Date
        public var status: String
        public var summary: String
    }

    public func recordRun(_ run: Run) throws {
        try db.run("INSERT INTO runs (started_at, finished_at, status, summary) VALUES (?,?,?,?)",
                   [run.startedAt, run.finishedAt, run.status, run.summary])
        try db.run("DELETE FROM runs WHERE id NOT IN (SELECT id FROM runs ORDER BY id DESC LIMIT 200)")
    }

    public func lastRuns(_ limit: Int = 5) throws -> [Run] {
        try db.run("SELECT * FROM runs ORDER BY id DESC LIMIT ?", [limit]).map {
            Run(startedAt: Date(timeIntervalSince1970: $0["started_at"].double ?? 0),
                finishedAt: Date(timeIntervalSince1970: $0["finished_at"].double ?? 0),
                status: $0["status"].string ?? "", summary: $0["summary"].string ?? "")
        }
    }
}
