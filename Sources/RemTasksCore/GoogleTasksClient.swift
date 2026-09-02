import Foundation

/// Thin client for the Google Tasks REST API (v1), scoped to one account.
public final class GoogleTasksClient {
    public let account: String
    private let auth: GoogleAuth
    private let base = "https://tasks.googleapis.com/tasks/v1"
    private let session: URLSession

    public init(auth: GoogleAuth, account: String, session: URLSession = .shared) {
        self.auth = auth; self.account = account; self.session = session
    }

    // MARK: Lists

    public func lists() async throws -> [GoogleList] {
        var out: [GoogleList] = []
        var pageToken: String?
        repeat {
            var q = ["maxResults": "100"]
            if let p = pageToken { q["pageToken"] = p }
            let json = try await request("GET", "/users/@me/lists", query: q)
            for item in json["items"] as? [[String: Any]] ?? [] {
                guard let id = item["id"] as? String else { continue }
                out.append(GoogleList(id: id, title: item["title"] as? String ?? "",
                                      updatedAt: (item["updated"] as? String).flatMap(Dates.parseRFC3339)))
            }
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil
        return out
    }

    public func createList(title: String) async throws -> GoogleList {
        let json = try await request("POST", "/users/@me/lists", body: ["title": title])
        guard let id = json["id"] as? String else { throw RemTasksError("Google did not return a list id") }
        return GoogleList(id: id, title: json["title"] as? String ?? title)
    }

    public func renameList(id: String, title: String) async throws {
        _ = try await request("PATCH", "/users/@me/lists/\(id)", body: ["title": title])
    }

    public func deleteList(id: String) async throws {
        _ = try await request("DELETE", "/users/@me/lists/\(id)")
    }

    // MARK: Tasks

    public func tasks(listID: String) async throws -> [GoogleItem] {
        var out: [GoogleItem] = []
        var pageToken: String?
        repeat {
            var q = ["maxResults": "100", "showCompleted": "true", "showHidden": "true"]
            if let p = pageToken { q["pageToken"] = p }
            let json = try await request("GET", "/lists/\(listID)/tasks", query: q)
            for item in json["items"] as? [[String: Any]] ?? [] {
                if let t = Self.item(from: item, listID: listID) { out.append(t) }
            }
            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil
        return out
    }

    public func createTask(listID: String, fields: SyncFields, parent: String?) async throws -> GoogleItem {
        var q: [String: String] = [:]
        if let parent { q["parent"] = parent }
        let json = try await request("POST", "/lists/\(listID)/tasks", query: q, body: Self.body(for: fields, patch: false))
        guard let t = Self.item(from: json, listID: listID) else { throw RemTasksError("Google did not return the created task") }
        return t
    }

    public func updateTask(listID: String, id: String, fields: SyncFields) async throws -> GoogleItem {
        let json = try await request("PATCH", "/lists/\(listID)/tasks/\(id)", body: Self.body(for: fields, patch: true))
        guard let t = Self.item(from: json, listID: listID) else { throw RemTasksError("Google did not return the updated task") }
        return t
    }

    public func deleteTask(listID: String, id: String) async throws {
        do {
            _ = try await request("DELETE", "/lists/\(listID)/tasks/\(id)")
        } catch let e as HTTPError where e.status == 404 {
            // already gone
        }
    }

    public func moveTask(listID: String, id: String, parent: String?) async throws -> GoogleItem {
        var q: [String: String] = [:]
        if let parent { q["parent"] = parent }
        let json = try await request("POST", "/lists/\(listID)/tasks/\(id)/move", query: q)
        guard let t = Self.item(from: json, listID: listID) else { throw RemTasksError("Google did not return the moved task") }
        return t
    }

    // MARK: Mapping

    static func item(from t: [String: Any], listID: String) -> GoogleItem? {
        guard let id = t["id"] as? String else { return nil }
        if t["deleted"] as? Bool == true { return nil }
        let dueDay = (t["due"] as? String).map { String($0.prefix(10)) }
        let fields = SyncFields(title: t["title"] as? String ?? "", notes: t["notes"] as? String,
                                dueDay: dueDay, completed: (t["status"] as? String) == "completed")
        let updated = (t["updated"] as? String).flatMap(Dates.parseRFC3339) ?? .distantPast
        let completedAt = fields.completed ? ((t["completed"] as? String).flatMap(Dates.parseRFC3339) ?? updated) : nil
        return GoogleItem(id: id, listID: listID, fields: fields, modifiedAt: updated,
                          parentID: t["parent"] as? String, position: t["position"] as? String ?? "",
                          completedAt: completedAt)
    }

    static func body(for fields: SyncFields, patch: Bool) -> [String: Any] {
        var b: [String: Any] = [
            "title": String(fields.title.prefix(1024)),
            "status": fields.completed ? "completed" : "needsAction",
        ]
        if let n = fields.notes { b["notes"] = String(n.prefix(8192)) } else if patch { b["notes"] = NSNull() }
        if let d = fields.dueDay { b["due"] = "\(d)T00:00:00.000Z" } else if patch { b["due"] = NSNull() }
        if fields.completed { b["completed"] = Dates.rfc3339(Date()) } else if patch { b["completed"] = NSNull() }
        return b
    }

    // MARK: HTTP

    public struct HTTPError: LocalizedError {
        public let status: Int
        public let message: String
        public var errorDescription: String? { "Google Tasks API \(status): \(message)" }
    }

    private func request(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> [String: Any] {
        var comps = URLComponents(string: base + path)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var lastError: Error?
        if method != "GET" { try await pace() }
        for attempt in 0..<maxAttempts {
            var req = URLRequest(url: comps.url!)
            req.httpMethod = method
            req.setValue("Bearer \(try await auth.accessToken(account: account, force: attempt > 0 && (lastError as? HTTPError)?.status == 401))",
                         forHTTPHeaderField: "Authorization")
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            Log.debug("\(method) \(comps.url!.absoluteString)")
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                if data.isEmpty { return [:] }
                return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            let err = HTTPError(status: status, message: text.prefix(300).description)
            lastError = err
            if status == 401 && attempt == 0 { continue }
            // Google reports per-minute quota exhaustion as 403 quotaExceeded / rateLimitExceeded.
            let quota = status == 403 && (text.contains("quotaExceeded") || text.contains("rateLimitExceeded") || text.contains("userRateLimitExceeded"))
            if status == 429 || status >= 500 || quota, attempt < maxAttempts - 1 {
                let delay = quota ? min(60.0, 5.0 * pow(2.0, Double(attempt))) : pow(2.0, Double(attempt))
                Log.warn("Google \(quota ? "quota" : status.description) hit; waiting \(Int(delay))s before retrying")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }
            throw err
        }
        throw lastError ?? RemTasksError("Google request failed")
    }

    private var maxAttempts: Int { 7 }

    /// Space out writes so bursts (e.g. a first sync of hundreds of tasks) stay under Google's per-minute quota.
    private var lastWrite = Date.distantPast
    private func pace() async throws {
        let gap = 0.25 - Date().timeIntervalSince(lastWrite)
        if gap > 0 { try await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000)) }
        lastWrite = Date()
    }
}
