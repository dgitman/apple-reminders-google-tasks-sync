import Foundation
import Network
import CryptoKit
import Security

// MARK: - Token storage

public struct TokenSet: Codable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var email: String
}

public protocol TokenStorage {
    func load(account: String) throws -> TokenSet?
    func save(_ tokens: TokenSet, account: String) throws
    func delete(account: String) throws
    /// False for backends that only keep the refresh token; access tokens then live in memory.
    var persistsAccessTokens: Bool { get }
}

public extension TokenStorage {
    var persistsAccessTokens: Bool { true }
}

/// Where the Google OAuth client JSON comes from.
public enum ClientSecretSource {
    case file(URL)
    case onePassword(reference: String, op: OnePassword)

    public var description: String {
        switch self {
        case .file(let url): return url.path
        case .onePassword(let ref, _): return ref
        }
    }
}

/// JSON files with 0600 permissions under the config directory.
public struct FileTokenStorage: TokenStorage {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    private func url(_ account: String) -> URL { directory.appendingPathComponent("\(account).json") }

    public func load(account: String) throws -> TokenSet? {
        let u = url(account)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try JSONDecoder().decode(TokenSet.self, from: Data(contentsOf: u))
    }

    public func save(_ tokens: TokenSet, account: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(tokens)
        try data.write(to: url(account), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(account).path)
    }

    public func delete(account: String) throws {
        try? FileManager.default.removeItem(at: url(account))
    }
}

/// macOS Keychain generic-password items.
public struct KeychainTokenStorage: TokenStorage {
    public let service: String
    public init(service: String = "net.gitman.remtasks") { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load(account: String) throws -> TokenSet? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let rc = SecItemCopyMatching(q as CFDictionary, &out)
        if rc == errSecItemNotFound { return nil }
        guard rc == errSecSuccess, let data = out as? Data else { throw RemTasksError("Keychain read failed (\(rc))") }
        return try JSONDecoder().decode(TokenSet.self, from: data)
    }

    public func save(_ tokens: TokenSet, account: String) throws {
        let data = try JSONEncoder().encode(tokens)
        var add = query(account)
        add[kSecValueData as String] = data
        var rc = SecItemAdd(add as CFDictionary, nil)
        if rc == errSecDuplicateItem {
            rc = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard rc == errSecSuccess else { throw RemTasksError("Keychain write failed (\(rc))") }
    }

    public func delete(account: String) throws {
        SecItemDelete(query(account) as CFDictionary)
    }
}

// MARK: - OAuth

struct GoogleClientSecret: Decodable {
    struct Installed: Decodable {
        let client_id: String
        let client_secret: String?
        let auth_uri: String?
        let token_uri: String?
    }
    let installed: Installed?
    let web: Installed?
    var creds: Installed? { installed ?? web }
}

/// Google OAuth 2.0 for installed apps: loopback redirect + PKCE, refresh tokens persisted per account.
public final class GoogleAuth {
    public static let scopes = "https://www.googleapis.com/auth/tasks openid email"

    public let clientSecretSource: ClientSecretSource
    public let storage: TokenStorage
    private var cache: [String: TokenSet] = [:]
    private var secret: GoogleClientSecret.Installed?

    public init(clientSecret: ClientSecretSource, storage: TokenStorage) {
        self.clientSecretSource = clientSecret
        self.storage = storage
    }

    public convenience init(clientSecretURL: URL, storage: TokenStorage) {
        self.init(clientSecret: .file(clientSecretURL), storage: storage)
    }

    /// Loads and validates the OAuth client; returns a short description of where it came from.
    @discardableResult
    public func checkClientSecret() throws -> String {
        _ = try loadSecret()
        return clientSecretSource.description
    }

    private func loadSecret() throws -> GoogleClientSecret.Installed {
        if let secret { return secret }
        let data: Data
        switch clientSecretSource {
        case .file(let url):
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw RemTasksError("Google OAuth client file not found at \(url.path). See README: 'Google Cloud setup'.")
            }
            data = try Data(contentsOf: url)
        case .onePassword(let ref, let op):
            data = try op.read(ref)
        }
        guard let creds = try JSONDecoder().decode(GoogleClientSecret.self, from: data).creds else {
            throw RemTasksError("\(clientSecretSource.description) is not a Google OAuth client JSON (expected an 'installed' key).")
        }
        secret = creds
        return creds
    }

    public func storedTokens(account: String) throws -> TokenSet? {
        if let t = cache[account] { return t }
        let t = try storage.load(account: account)
        if let t { cache[account] = t }
        return t
    }

    public func signOut(account: String) throws {
        cache[account] = nil
        try storage.delete(account: account)
    }

    /// Interactive sign-in. Opens the browser, waits for the redirect, verifies the signed-in
    /// email matches `expectedEmail`, and stores the refresh token.
    @discardableResult
    public func signIn(account: String, expectedEmail: String) async throws -> TokenSet {
        let creds = try loadSecret()
        let verifier = Self.randomURLSafe(64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(24)

        let server = try LoopbackServer()
        let port = try await server.start()
        defer { server.stop() }
        let redirect = "http://127.0.0.1:\(port)/"

        var comps = URLComponents(string: creds.auth_uri ?? "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: creds.client_id),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "login_hint", value: expectedEmail),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        let authURL = comps.url!

        Log.info("Opening browser for \(expectedEmail). If it does not open, visit:\n\(authURL.absoluteString)")
        let query = try await server.waitForCallback {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = [authURL.absoluteString]
            try? p.run()
        }
        guard query["state"] == state, let code = query["code"] else {
            throw RemTasksError("OAuth callback state mismatch or missing code.")
        }

        var form = [
            "code": code, "client_id": creds.client_id, "redirect_uri": redirect,
            "grant_type": "authorization_code", "code_verifier": verifier,
        ]
        if let s = creds.client_secret { form["client_secret"] = s }
        let json = try await tokenRequest(form, tokenURI: creds.token_uri)

        guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
            throw RemTasksError("Token response had no refresh token. Remove remtasks from https://myaccount.google.com/permissions and sign in again.")
        }
        let expires = (json["expires_in"] as? Double) ?? 3600
        let email = (json["id_token"] as? String).flatMap(Self.email(fromIDToken:)) ?? ""
        guard email.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
            throw RemTasksError("Signed in as '\(email)' but account '\(account)' is configured for '\(expectedEmail)'. Nothing saved; try again and pick the right Google account.")
        }
        let tokens = TokenSet(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(expires), email: email)
        try storage.save(tokens, account: account)
        cache[account] = tokens
        return tokens
    }

    /// A valid access token, refreshing when within 60s of expiry (or when `force` is set).
    public func accessToken(account: String, force: Bool = false) async throws -> String {
        guard var tokens = try storedTokens(account: account) else {
            throw RemTasksError("Account '\(account)' is not signed in. Run: remtasks auth \(account)")
        }
        if !force && tokens.expiresAt.timeIntervalSinceNow > 60 { return tokens.accessToken }
        let creds = try loadSecret()
        var form = ["client_id": creds.client_id, "refresh_token": tokens.refreshToken, "grant_type": "refresh_token"]
        if let s = creds.client_secret { form["client_secret"] = s }
        let json = try await tokenRequest(form, tokenURI: creds.token_uri)
        guard let access = json["access_token"] as? String else {
            throw RemTasksError("Token refresh for '\(account)' failed. Run: remtasks auth \(account)")
        }
        tokens.accessToken = access
        tokens.expiresAt = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3600)
        if storage.persistsAccessTokens { try storage.save(tokens, account: account) }
        cache[account] = tokens
        return access
    }

    private func tokenRequest(_ form: [String: String], tokenURI: String?) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: tokenURI ?? "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(form.map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&").utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (200..<300).contains(status) else {
            let desc = json["error_description"] as? String ?? json["error"] as? String ?? String(data: data, encoding: .utf8) ?? ""
            throw RemTasksError("Google token endpoint returned \(status): \(desc)")
        }
        return json
    }

    // MARK: Helpers

    static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["email"] as? String
    }

    static func randomURLSafe(_ bytes: Int) -> String {
        var buf = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)
        return base64URL(Data(buf))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

// MARK: - Loopback HTTP server for the OAuth redirect

final class LoopbackServer {
    private let listener: NWListener
    private var continuation: CheckedContinuation<[String: String], Error>?
    private let lock = NSLock()

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if once.claim() { cont.resume(returning: self.listener.port?.rawValue ?? 0) }
                case .failed(let err):
                    if once.claim() { cont.resume(throwing: err) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: .global())
        }
    }

    func waitForCallback(afterArming: () -> Void) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            lock.lock(); continuation = cont; lock.unlock()
            afterArming()
        }
    }

    func stop() { listener.cancel() }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let requestLine = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = requestLine.split(separator: " ")
            var path = "/"
            var query: [String: String] = [:]
            if parts.count >= 2, let comps = URLComponents(string: "http://127.0.0.1" + parts[1]) {
                path = comps.path
                for item in comps.queryItems ?? [] { query[item.name] = item.value ?? "" }
            }
            let isCallback = path == "/" && (query["code"] != nil || query["error"] != nil)
            let body: String
            if !isCallback {
                body = "<html><body>remtasks</body></html>"
            } else if query["code"] != nil {
                body = "<html><body style='font-family:-apple-system'><h2>remtasks: signed in.</h2><p>You can close this tab and return to the terminal.</p></body></html>"
            } else {
                body = "<html><body style='font-family:-apple-system'><h2>remtasks: sign-in failed</h2><p>\(query["error"] ?? "")</p></body></html>"
            }
            let response = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                conn.cancel()
                guard isCallback, let self else { return }
                self.lock.lock()
                let cont = self.continuation
                self.continuation = nil
                self.lock.unlock()
                if query["code"] != nil { cont?.resume(returning: query) }
                else { cont?.resume(throwing: RemTasksError("Google returned OAuth error: \(query["error"] ?? "unknown")")) }
            })
        }
    }
}

/// Thread-safe one-shot flag.
final class Once {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
