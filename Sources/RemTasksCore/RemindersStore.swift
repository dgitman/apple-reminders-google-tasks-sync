import Foundation
import EventKit

/// EventKit access to Apple Reminders.
public final class RemindersStore {
    public let store = EKEventStore()
    public init() {}

    // MARK: Access

    public static var authorizationStatus: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .reminder) }

    public func requestAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return
        case .denied, .restricted:
            throw RemTasksError("Reminders access is denied. Enable it in System Settings > Privacy & Security > Reminders.")
        default:
            let granted = try await store.requestFullAccessToReminders()
            guard granted else {
                throw RemTasksError("Reminders access was not granted. Enable it in System Settings > Privacy & Security > Reminders.")
            }
        }
    }

    // MARK: Sources and lists

    public var sources: [EKSource] { store.sources }

    public func source(titled title: String) throws -> EKSource {
        let matches = store.sources.filter { $0.title.caseInsensitiveCompare(title) == .orderedSame }
        if let s = matches.first(where: { !$0.calendars(for: .reminder).isEmpty }) ?? matches.first { return s }
        let names = store.sources.map { "\($0.title) (\($0.calendars(for: .reminder).count) lists)" }
        throw RemTasksError("No Reminders account named '\(title)'. Available: \(names.joined(separator: ", "))")
    }

    public func lists(in source: EKSource, hierarchy: RemindersHierarchy) -> [AppleList] {
        source.calendars(for: .reminder).map { cal in
            AppleList(id: cal.calendarIdentifier, name: cal.title,
                      groupName: hierarchy.group(forListID: cal.calendarIdentifier, name: cal.title),
                      sourceID: source.sourceIdentifier, sourceTitle: source.title)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func createList(name: String, in source: EKSource) throws -> AppleList {
        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = name
        cal.source = source
        try store.saveCalendar(cal, commit: true)
        return AppleList(id: cal.calendarIdentifier, name: name, sourceID: source.sourceIdentifier, sourceTitle: source.title)
    }

    public func deleteList(id: String) throws {
        guard let cal = store.calendar(withIdentifier: id) else { throw RemTasksError("Reminders list \(id) not found") }
        try store.removeCalendar(cal, commit: true)
    }

    // MARK: Reading reminders

    public func items(in listID: String, hierarchy: RemindersHierarchy) async throws -> [AppleItem] {
        guard let cal = store.calendar(withIdentifier: listID) else { throw RemTasksError("Reminders list \(listID) not found") }
        let reminders: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: store.predicateForReminders(in: [cal])) { cont.resume(returning: $0 ?? []) }
        }
        // Map the database's UUIDs onto EventKit identifiers so parent references resolve
        // to AppleItem.id values within this list.
        var idByUUID: [String: String] = [:]
        for r in reminders {
            idByUUID[r.calendarItemIdentifier.uppercased()] = r.calendarItemIdentifier
            if let u = RemindersDatabase.uuid(fromExternalID: r.calendarItemExternalIdentifier ?? "") {
                idByUUID[u] = r.calendarItemIdentifier
            }
        }
        var seen = Set<String>()
        var out: [AppleItem] = []
        for r in reminders {
            guard seen.insert(r.calendarItemIdentifier).inserted else { continue }
            var item = Self.item(from: r, listID: listID)
            if let p = hierarchy.parentUUID(of: r.calendarItemIdentifier, externalID: r.calendarItemExternalIdentifier) {
                item.parentID = idByUUID[p] ?? p
            }
            out.append(item)
        }
        return out
    }

    public func reminder(id: String) -> EKReminder? {
        store.calendarItem(withIdentifier: id) as? EKReminder
    }

    static func item(from r: EKReminder, listID: String) -> AppleItem {
        let due = dueDate(from: r.dueDateComponents)
        let fields = SyncFields(title: r.title ?? "", notes: r.notes, dueDay: due?.dayKey, completed: r.isCompleted)
        return AppleItem(id: r.calendarItemIdentifier, listID: listID, fields: fields, due: due,
                         modifiedAt: r.lastModifiedDate ?? r.creationDate ?? .distantPast,
                         isRecurring: r.hasRecurrenceRules, parentID: nil, hasAlarms: !(r.alarms ?? []).isEmpty)
    }

    static func dueDate(from c: DateComponents?) -> DueDate? {
        guard let c, let y = c.year, let m = c.month, let d = c.day else { return nil }
        if let h = c.hour, let mi = c.minute { return DueDate(year: y, month: m, day: d, hour: h, minute: mi) }
        return DueDate(year: y, month: m, day: d)
    }

    // MARK: Writing reminders

    public func createReminder(listID: String, fields: SyncFields, due: DueDate?, addAlarm: Bool) throws -> AppleItem {
        guard let cal = store.calendar(withIdentifier: listID) else { throw RemTasksError("Reminders list \(listID) not found") }
        let r = EKReminder(eventStore: store)
        r.calendar = cal
        apply(fields: fields, due: due, addAlarm: addAlarm, to: r, previousDue: nil)
        try store.save(r, commit: true)
        return Self.item(from: r, listID: listID)
    }

    public func updateReminder(id: String, fields: SyncFields, due: DueDate?, addAlarm: Bool) throws -> AppleItem {
        guard let r = reminder(id: id) else { throw RemTasksError("Reminder \(id) not found") }
        let previousDue = Self.dueDate(from: r.dueDateComponents)
        apply(fields: fields, due: due, addAlarm: addAlarm, to: r, previousDue: previousDue)
        try store.save(r, commit: true)
        return Self.item(from: r, listID: r.calendar.calendarIdentifier)
    }

    public func deleteReminder(id: String) throws {
        guard let r = reminder(id: id) else { return } // already gone
        try store.remove(r, commit: true)
    }

    private func apply(fields: SyncFields, due: DueDate?, addAlarm: Bool, to r: EKReminder, previousDue: DueDate?) {
        if r.title != fields.title { r.title = fields.title }
        if SyncFields.normalizeNotes(r.notes) != fields.notes { r.notes = fields.notes }
        if r.isCompleted != fields.completed { r.isCompleted = fields.completed }

        guard due != previousDue else { return }
        let oldDate = previousDue?.date()
        func pinnedToOldDue(_ alarm: EKAlarm) -> Bool {
            guard let oldDate, let abs = alarm.absoluteDate else { return false }
            return Swift.abs(abs.timeIntervalSince(oldDate)) < 60
        }
        if let due {
            var comps = due.dateComponents
            comps.calendar = Calendar.current
            if due.hasTime { comps.timeZone = TimeZone.current }
            r.dueDateComponents = comps
            let newDate = due.date()
            for alarm in r.alarms ?? [] where pinnedToOldDue(alarm) {
                if let newDate { alarm.absoluteDate = newDate } else { r.removeAlarm(alarm) }
            }
            if addAlarm, due.hasTime, (r.alarms ?? []).isEmpty, let newDate {
                r.addAlarm(EKAlarm(absoluteDate: newDate))
            }
        } else {
            r.dueDateComponents = nil
            for alarm in r.alarms ?? [] where pinnedToOldDue(alarm) { r.removeAlarm(alarm) }
        }
    }
}
