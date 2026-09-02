import Foundation
import CryptoKit

// MARK: - Due dates

/// A due date as the user sees it: a calendar day, optionally with a wall-clock time.
/// Google Tasks only stores the day. Apple Reminders stores the day and, optionally, a time.
public struct DueDate: Equatable, Hashable, Codable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int
    public var hour: Int?
    public var minute: Int?

    public init(year: Int, month: Int, day: Int, hour: Int? = nil, minute: Int? = nil) {
        self.year = year; self.month = month; self.day = day
        self.hour = hour; self.minute = minute
    }

    public var hasTime: Bool { hour != nil && minute != nil }

    /// "YYYY-MM-DD" — the only part Google Tasks can hold.
    public var dayKey: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func fromDayKey(_ key: String) -> DueDate? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return DueDate(year: parts[0], month: parts[1], day: parts[2])
    }

    /// Same day, with the time-of-day copied from `other` (if it has one).
    public func keepingTime(of other: DueDate?) -> DueDate {
        var copy = self
        if let o = other, o.hasTime { copy.hour = o.hour; copy.minute = o.minute }
        return copy
    }

    public func withTime(hour: Int, minute: Int) -> DueDate {
        var copy = self
        copy.hour = hour; copy.minute = minute
        return copy
    }

    public var withoutTime: DueDate { DueDate(year: year, month: month, day: day) }

    public var dateComponents: DateComponents {
        var c = DateComponents(year: year, month: month, day: day)
        if hasTime { c.hour = hour; c.minute = minute }
        return c
    }

    public func date(in calendar: Calendar = .current) -> Date? {
        var comps = dateComponents
        if !hasTime { comps.hour = 0; comps.minute = 0 }
        return calendar.date(from: comps)
    }

    public var description: String {
        hasTime ? String(format: "%@ %02d:%02d", dayKey, hour!, minute!) : dayKey
    }
}

/// A wall-clock time such as 09:00, used for defaults.
public struct TimeOfDay: Equatable, Codable {
    public var hour: Int
    public var minute: Int
    public init(hour: Int, minute: Int) { self.hour = hour; self.minute = minute }

    public init?(string: String) {
        let parts = string.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        self.init(hour: parts[0], minute: parts[1])
    }
}

// MARK: - Sync fields

/// The set of fields BOTH platforms can represent. Only these participate in
/// change detection and conflict resolution. Everything else (alarms, priority,
/// tags, recurrence rules, subtask placement in Apple) is platform-owned and never
/// overwritten by the other side.
public struct SyncFields: Equatable, Hashable, Codable {
    public var title: String
    public var notes: String?
    public var dueDay: String?
    public var completed: Bool

    public init(title: String, notes: String? = nil, dueDay: String? = nil, completed: Bool = false) {
        self.title = title
        self.notes = SyncFields.normalizeNotes(notes)
        self.dueDay = dueDay
        self.completed = completed
    }

    public static func normalizeNotes(_ notes: String?) -> String? {
        guard let n = notes else { return nil }
        let trimmed = n.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Stable content hash. Two items with equal fingerprints are "the same" as far as sync is concerned.
    public var fingerprint: String {
        let raw = [title, notes ?? "", dueDay ?? "", completed ? "1" : "0"].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Loose key used to pair up items that already exist on both sides (first run, or
    /// after state loss) without creating duplicates.
    public var matchKey: String {
        let t = title.lowercased()
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return "\(t)|\(dueDay ?? "")"
    }
}

// MARK: - Items

public struct AppleItem: Equatable {
    public var id: String              // EKReminder.calendarItemIdentifier
    public var listID: String          // EKCalendar.calendarIdentifier
    public var fields: SyncFields
    public var due: DueDate?
    public var modifiedAt: Date
    public var isRecurring: Bool
    public var parentID: String?       // from the Reminders database; nil if unknown/top-level
    public var hasAlarms: Bool
    public var completedAt: Date?

    public init(id: String, listID: String, fields: SyncFields, due: DueDate? = nil, modifiedAt: Date,
                isRecurring: Bool = false, parentID: String? = nil, hasAlarms: Bool = false, completedAt: Date? = nil) {
        self.id = id; self.listID = listID; self.fields = fields; self.due = due
        self.modifiedAt = modifiedAt; self.isRecurring = isRecurring
        self.parentID = parentID; self.hasAlarms = hasAlarms; self.completedAt = completedAt
    }
}

public struct GoogleItem: Equatable {
    public var id: String
    public var listID: String
    public var fields: SyncFields
    public var modifiedAt: Date
    public var parentID: String?
    public var position: String
    public var completedAt: Date?

    public init(id: String, listID: String, fields: SyncFields, modifiedAt: Date, parentID: String? = nil,
                position: String = "", completedAt: Date? = nil) {
        self.id = id; self.listID = listID; self.fields = fields
        self.modifiedAt = modifiedAt; self.parentID = parentID; self.position = position; self.completedAt = completedAt
    }

    public var due: DueDate? { fields.dueDay.flatMap(DueDate.fromDayKey) }
}

/// One row of sync state: an Apple reminder paired with a Google task.
public struct Link: Equatable, Codable {
    public var appleID: String
    public var googleID: String
    public var account: String
    public var appleListID: String
    public var googleListID: String
    public var fingerprint: String        // fields as last written/observed on both sides
    public var dueDay: String?
    public var appleParentID: String?
    public var googleParentID: String?
    public var lastSyncAt: Date

    public init(appleID: String, googleID: String, account: String, appleListID: String, googleListID: String,
                fingerprint: String, dueDay: String?, appleParentID: String? = nil, googleParentID: String? = nil,
                lastSyncAt: Date) {
        self.appleID = appleID; self.googleID = googleID; self.account = account
        self.appleListID = appleListID; self.googleListID = googleListID
        self.fingerprint = fingerprint; self.dueDay = dueDay
        self.appleParentID = appleParentID; self.googleParentID = googleParentID
        self.lastSyncAt = lastSyncAt
    }
}

// MARK: - Lists

public struct AppleList: Equatable {
    public var id: String
    public var name: String
    public var groupName: String?
    public var sourceID: String
    public var sourceTitle: String
    public init(id: String, name: String, groupName: String? = nil, sourceID: String, sourceTitle: String) {
        self.id = id; self.name = name; self.groupName = groupName; self.sourceID = sourceID; self.sourceTitle = sourceTitle
    }
}

public struct GoogleList: Equatable {
    public var id: String
    public var title: String
    public var updatedAt: Date?
    public init(id: String, title: String, updatedAt: Date? = nil) { self.id = id; self.title = title; self.updatedAt = updatedAt }
}

public struct ListLink: Equatable, Codable {
    public var appleListID: String
    public var googleListID: String
    public var account: String
    public var name: String
    public init(appleListID: String, googleListID: String, account: String, name: String) {
        self.appleListID = appleListID; self.googleListID = googleListID; self.account = account; self.name = name
    }
}

// MARK: - Errors

public struct RemTasksError: LocalizedError, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}
