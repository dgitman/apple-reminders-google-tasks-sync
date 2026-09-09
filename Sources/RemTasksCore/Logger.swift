import Foundation

/// URLSession without an on-disk cache. API traffic gains nothing from caching, and a disk cache
/// under ~/Library/Caches gets deleted by cleanup tools while a long-running daemon has it open,
/// which produces a stream of SQLite "disk I/O error" messages.
public enum HTTP {
    public static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }()
}

public enum Log {
    public static var verbose = false
    public static var quiet = false
    private static var handle: FileHandle?
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Also append every line to a log file.
    public static func toFile(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try FileHandle(forWritingTo: url)
            handle?.seekToEndOfFile()
        } catch {
            FileHandle.standardError.write(Data("WARN cannot open log file \(url.path): \(error)\n".utf8))
        }
    }

    public static func info(_ message: String) { emit("INFO ", message, toStderr: false) }
    public static func warn(_ message: String) { emit("WARN ", message, toStderr: true) }
    public static func error(_ message: String) { emit("ERROR", message, toStderr: true) }
    public static func debug(_ message: String) { if verbose { emit("DEBUG", message, toStderr: false) } }

    private static func emit(_ level: String, _ message: String, toStderr: Bool) {
        let line = "\(stamp.string(from: Date())) \(level) \(message)\n"
        if !quiet || toStderr {
            let out = toStderr ? FileHandle.standardError : FileHandle.standardOutput
            out.write(Data(line.utf8))
        }
        // Seek every time so a log file truncated by a cleanup tool doesn't get a hole of NULs.
        handle?.seekToEndOfFile()
        handle?.write(Data(line.utf8))
    }
}

public enum Dates {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parseRFC3339(_ s: String) -> Date? {
        withFraction.date(from: s) ?? plain.date(from: s)
    }

    public static func rfc3339(_ d: Date) -> String { withFraction.string(from: d) }

    public static func short(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: d)
    }
}
