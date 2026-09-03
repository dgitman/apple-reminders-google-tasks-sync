import Foundation

/// Thin wrapper around the 1Password CLI (`op`), using the desktop app integration for auth.
public struct OnePassword {
    public let opPath: String
    public let vault: String

    public init(vault: String, opPath: String? = nil) throws {
        self.vault = vault
        self.opPath = try opPath.map(Config.expandTilde) ?? Self.locate()
    }

    static func locate() throws -> String {
        for p in ["/opt/homebrew/bin/op", "/usr/local/bin/op", "/usr/bin/op"] where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        throw RemTasksError("1Password CLI (op) not found. Install it (brew install 1password-cli) or set google.onePassword.opPath.")
    }

    public struct OPError: LocalizedError {
        public let status: Int32
        public let message: String
        public var errorDescription: String? { "op exited \(status): \(message)" }
        public var isNotFound: Bool { message.contains("isn't an item") || message.contains("isn't a vault") }
    }

    @discardableResult
    public func run(_ args: [String], stdin: Data? = nil) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: opPath)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let input = stdin != nil ? Pipe() : nil
        if let input { p.standardInput = input }
        Log.debug("op \(args.filter { !$0.hasPrefix("{") }.joined(separator: " "))")
        try p.run()
        if let input, let stdin {
            input.fileHandleForWriting.write(stdin)
            try? input.fileHandleForWriting.close()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw OPError(status: p.terminationStatus, message: msg.isEmpty ? "(no output)" : msg)
        }
        return outData
    }

    /// `op read op://vault/item/field`
    public func read(_ reference: String) throws -> Data {
        try run(["read", reference, "--no-newline"])
    }

    /// Whether the vault is reachable (app unlocked and CLI integration on).
    public func check() throws {
        try run(["vault", "get", vault, "--format", "json"])
    }

    public func item(titled title: String) throws -> [String: Any]? {
        do {
            let data = try run(["item", "get", title, "--vault", vault, "--format", "json"])
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch let e as OPError where e.isNotFound {
            return nil
        }
    }

    public func createItem(_ template: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: template)
        try run(["item", "create", "--vault", vault, "-"], stdin: data)
    }

    public func deleteItem(titled title: String) throws {
        try run(["item", "delete", title, "--vault", vault])
    }
}

/// Refresh tokens stored as 1Password "API Credential" items named "<prefix> <account>".
/// Access tokens are never persisted; each run mints a fresh one from the refresh token.
public struct OnePasswordTokenStorage: TokenStorage {
    public let op: OnePassword
    public let itemPrefix: String

    public init(op: OnePassword, itemPrefix: String = "remtasks") {
        self.op = op
        self.itemPrefix = itemPrefix
    }

    public var persistsAccessTokens: Bool { false }

    public func title(for account: String) -> String { "\(itemPrefix) \(account)" }

    public func load(account: String) throws -> TokenSet? {
        guard let json = try op.item(titled: title(for: account)) else { return nil }
        return Self.parse(json)
    }

    public static func parse(_ json: [String: Any]) -> TokenSet? {
        guard let fields = json["fields"] as? [[String: Any]] else { return nil }
        func field(_ id: String) -> String? {
            fields.first { ($0["id"] as? String) == id || ($0["label"] as? String) == id }?["value"] as? String
        }
        guard let refresh = field("credential"), !refresh.isEmpty else { return nil }
        return TokenSet(accessToken: "", refreshToken: refresh, expiresAt: .distantPast, email: field("username") ?? "")
    }

    public func save(_ tokens: TokenSet, account: String) throws {
        let t = title(for: account)
        if try op.item(titled: t) != nil { try op.deleteItem(titled: t) }
        let template: [String: Any] = [
            "title": t,
            "category": "API_CREDENTIAL",
            "fields": [
                ["id": "username", "type": "STRING", "label": "username", "value": tokens.email],
                ["id": "credential", "type": "CONCEALED", "label": "credential", "value": tokens.refreshToken],
                ["id": "notesPlain", "type": "STRING", "purpose": "NOTES", "label": "notesPlain",
                 "value": "Google Tasks refresh token for remtasks account '\(account)'. Managed by remtasks; re-run 'remtasks auth \(account)' to replace."],
            ],
        ]
        try op.createItem(template)
    }

    public func delete(account: String) throws {
        let t = title(for: account)
        if try op.item(titled: t) != nil { try op.deleteItem(titled: t) }
    }
}
