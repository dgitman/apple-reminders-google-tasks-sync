import Foundation

public struct PlanOptions: Equatable {
    public var allowDeletes: Bool
    public var maxDeletes: Int
    public var hierarchyAvailable: Bool
    public init(allowDeletes: Bool = false, maxDeletes: Int = 20, hierarchyAvailable: Bool = true) {
        self.allowDeletes = allowDeletes; self.maxDeletes = maxDeletes; self.hierarchyAvailable = hierarchyAvailable
    }
}

public enum Winner: Equatable { case apple, google, none }

public enum SyncAction: Equatable {
    case createGoogle(AppleItem)
    case createApple(GoogleItem)
    /// Pair two pre-existing items; `Winner` says which side's content to push (none = already equal).
    case adopt(AppleItem, GoogleItem, Winner)
    case updateGoogle(Link, AppleItem, GoogleItem)
    case updateApple(Link, GoogleItem, AppleItem)
    case deleteGoogle(Link, GoogleItem)
    case deleteApple(Link, AppleItem)
    /// Apple side vanished but Google was edited after the last sync: re-create in Apple.
    case restoreApple(Link, GoogleItem)
    case restoreGoogle(Link, AppleItem)
    /// A recurring reminder advanced to its next occurrence after the Google task was completed.
    case rollForward(Link, AppleItem, GoogleItem)
    /// Re-parent a Google task (nil = top level) to mirror Apple's hierarchy.
    case moveGoogle(Link, GoogleItem, String?)
    case unlink(Link)

    public var isDelete: Bool {
        switch self {
        case .deleteGoogle, .deleteApple: return true
        default: return false
        }
    }

    public var kind: String {
        switch self {
        case .createGoogle: return "createGoogle"
        case .createApple: return "createApple"
        case .adopt: return "adopt"
        case .updateGoogle: return "updateGoogle"
        case .updateApple: return "updateApple"
        case .deleteGoogle: return "deleteGoogle"
        case .deleteApple: return "deleteApple"
        case .restoreApple: return "restoreApple"
        case .restoreGoogle: return "restoreGoogle"
        case .rollForward: return "rollForward"
        case .moveGoogle: return "moveGoogle"
        case .unlink: return "unlink"
        }
    }

    public var summary: String {
        func q(_ s: String) -> String { "\"\(s.count > 60 ? String(s.prefix(57)) + "..." : s)\"" }
        switch self {
        case .createGoogle(let a): return "Apple -> Google: create \(q(a.fields.title))\(a.parentID != nil ? " (subtask)" : "")"
        case .createApple(let g): return "Google -> Apple: create \(q(g.fields.title))\(g.parentID != nil ? " (subtask in Google)" : "")"
        case .adopt(let a, _, let w): return "Pair existing \(q(a.fields.title))" + (w == .none ? "" : " and push \(w == .apple ? "Apple" : "Google") version")
        case .updateGoogle(_, let a, let g): return "Apple -> Google: update \(q(g.fields.title))\(Self.diff(g.fields, a.fields))"
        case .updateApple(_, let g, let a): return "Google -> Apple: update \(q(a.fields.title))\(Self.diff(a.fields, g.fields))"
        case .deleteGoogle(_, let g): return "Apple -> Google: delete \(q(g.fields.title))"
        case .deleteApple(_, let a): return "Google -> Apple: delete \(q(a.fields.title))"
        case .restoreApple(_, let g): return "Google -> Apple: re-create \(q(g.fields.title)) (edited in Google after being deleted in Apple)"
        case .restoreGoogle(_, let a): return "Apple -> Google: re-create \(q(a.fields.title)) (edited in Apple after being deleted in Google)"
        case .rollForward(_, let a, _): return "Apple -> Google: next occurrence of recurring \(q(a.fields.title)) due \(a.fields.dueDay ?? "-")"
        case .moveGoogle(_, let g, let p): return "Apple -> Google: move \(q(g.fields.title)) \(p == nil ? "to top level" : "under its parent")"
        case .unlink(let l): return "Forget pairing \(l.appleID.prefix(8))/\(l.googleID.prefix(8)) (gone on both sides)"
        }
    }

    static func diff(_ from: SyncFields, _ to: SyncFields) -> String {
        var parts: [String] = []
        if from.title != to.title { parts.append("title -> \"\(to.title)\"") }
        if from.notes != to.notes { parts.append("notes") }
        if from.dueDay != to.dueDay { parts.append("due \(from.dueDay ?? "-") -> \(to.dueDay ?? "-")") }
        if from.completed != to.completed { parts.append(to.completed ? "complete" : "reopen") }
        return parts.isEmpty ? "" : " [\(parts.joined(separator: ", "))]"
    }
}

public struct SyncPlan: Equatable {
    public var actions: [SyncAction]
    public var warnings: [String]
    public var suppressedDeletes: Int
}

/// Pure decision logic: given both sides and the stored links, decide what to do.
/// No I/O, fully unit-testable.
public enum SyncPlanner {

    public static func plan(apple: [AppleItem], google: [GoogleItem], links: [Link], options: PlanOptions) -> SyncPlan {
        var actions: [SyncAction] = []
        var moves: [SyncAction] = []
        var warnings: [String] = []

        let appleByID = Dictionary(apple.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let googleByID = Dictionary(google.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let linkByApple = Dictionary(links.map { ($0.appleID, $0) }, uniquingKeysWith: { a, _ in a })
        var linkedApple = Set<String>()
        var linkedGoogle = Set<String>()

        for link in links {
            linkedApple.insert(link.appleID)
            linkedGoogle.insert(link.googleID)
            let a = appleByID[link.appleID]
            let g = googleByID[link.googleID]

            switch (a, g) {
            case (nil, nil):
                actions.append(.unlink(link))

            case (let a?, nil):
                if a.fields.fingerprint != link.fingerprint && a.modifiedAt > link.lastSyncAt {
                    actions.append(.restoreGoogle(link, a))
                } else {
                    actions.append(.deleteApple(link, a))
                }

            case (nil, let g?):
                if g.fields.fingerprint != link.fingerprint && g.modifiedAt > link.lastSyncAt {
                    actions.append(.restoreApple(link, g))
                } else {
                    actions.append(.deleteGoogle(link, g))
                }

            case (let a?, let g?):
                if a.isRecurring, !a.fields.completed, g.fields.completed,
                   let day = a.fields.dueDay, day != link.dueDay {
                    actions.append(.rollForward(link, a, g))
                    continue
                }
                let aChanged = a.fields.fingerprint != link.fingerprint
                let gChanged = g.fields.fingerprint != link.fingerprint
                switch (aChanged, gChanged) {
                case (false, false):
                    break
                case (true, false):
                    actions.append(.updateGoogle(link, a, g))
                case (false, true):
                    actions.append(.updateApple(link, g, a))
                case (true, true):
                    if a.fields == g.fields {
                        actions.append(.adopt(a, g, .none))
                    } else if a.modifiedAt >= g.modifiedAt {
                        actions.append(.updateGoogle(link, a, g))
                    } else {
                        actions.append(.updateApple(link, g, a))
                    }
                }

                if options.hierarchyAvailable {
                    if let ap = a.parentID {
                        if let parentLink = linkByApple[ap], g.parentID != parentLink.googleID {
                            moves.append(.moveGoogle(link, g, parentLink.googleID))
                        }
                        // Parent not linked yet: it is being created this run; hierarchy catches up next run.
                    } else if link.appleParentID != nil, g.parentID != nil {
                        moves.append(.moveGoogle(link, g, nil))
                    }
                }
            }
        }

        // Items not yet paired. First try to pair by title+due to avoid duplicates
        // (first run, or state lost), then create the rest.
        let freeApple = apple.filter { !linkedApple.contains($0.id) }
        var freeGoogle = google.filter { !linkedGoogle.contains($0.id) }
        let googleByKey = Dictionary(grouping: freeGoogle, by: { $0.fields.matchKey })
        var adopted = Set<String>()
        var toCreate: [AppleItem] = []
        for a in freeApple {
            if let g = googleByKey[a.fields.matchKey]?.first(where: { !adopted.contains($0.id) }) {
                adopted.insert(g.id)
                let winner: Winner = a.fields == g.fields ? .none : (a.modifiedAt >= g.modifiedAt ? .apple : .google)
                actions.append(.adopt(a, g, winner))
            } else {
                toCreate.append(a)
            }
        }
        freeGoogle.removeAll { adopted.contains($0.id) }

        for a in parentsFirst(toCreate) { actions.append(.createGoogle(a)) }
        for g in freeGoogle.sorted(by: { ($0.parentID == nil ? 0 : 1, $0.position) < ($1.parentID == nil ? 0 : 1, $1.position) }) {
            actions.append(.createApple(g))
        }
        actions.append(contentsOf: moves)

        var suppressed = 0
        let deletes = actions.filter(\.isDelete).count
        if deletes > options.maxDeletes && !options.allowDeletes {
            suppressed = deletes
            actions.removeAll(where: \.isDelete)
            warnings.append("Suppressed \(deletes) deletions (safety limit \(options.maxDeletes)). Re-run with --allow-deletes if this is intended.")
        }
        return SyncPlan(actions: actions, warnings: warnings, suppressedDeletes: suppressed)
    }

    static func parentsFirst(_ items: [AppleItem]) -> [AppleItem] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func depth(_ item: AppleItem) -> Int {
            var d = 0
            var cur = item.parentID
            var seen = Set<String>()
            while let p = cur, let pa = byID[p], seen.insert(p).inserted { d += 1; cur = pa.parentID }
            return d
        }
        return items.sorted { (depth($0), $0.fields.title) < (depth($1), $1.fields.title) }
    }
}

/// Limits a sync to open items plus recently completed ones, so years of completed history are
/// neither copied to the other side nor mistaken for deletions.
public enum SyncScope {
    public struct Result: Equatable {
        public var apple: [AppleItem]
        public var google: [GoogleItem]
        public var links: [Link]
        /// Pairings whose items are all old completions (or gone): forget them without touching either side.
        public var forget: [Link]
    }

    public static func inScope(_ completedAt: Date?, completed: Bool, cutoff: Date) -> Bool {
        guard completed else { return true }
        guard let completedAt else { return false }
        return completedAt >= cutoff
    }

    public static func partition(apple: [AppleItem], google: [GoogleItem], links: [Link], cutoff: Date) -> Result {
        let appleByID = Dictionary(apple.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let googleByID = Dictionary(google.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var keepApple: [AppleItem] = []
        var keepGoogle: [GoogleItem] = []
        var keepLinks: [Link] = []
        var forget: [Link] = []
        var linkedApple = Set<String>()
        var linkedGoogle = Set<String>()

        for link in links {
            linkedApple.insert(link.appleID); linkedGoogle.insert(link.googleID)
            let a = appleByID[link.appleID]
            let g = googleByID[link.googleID]
            let aLive = a.map { inScope($0.completedAt, completed: $0.fields.completed, cutoff: cutoff) } ?? false
            let gLive = g.map { inScope($0.completedAt, completed: $0.fields.completed, cutoff: cutoff) } ?? false
            if !aLive && !gLive {
                forget.append(link)          // both old completions (or gone): leave them be
                continue
            }
            keepLinks.append(link)
            if let a { keepApple.append(a) }
            if let g { keepGoogle.append(g) }
        }
        for a in apple where !linkedApple.contains(a.id) && inScope(a.completedAt, completed: a.fields.completed, cutoff: cutoff) {
            keepApple.append(a)
        }
        for g in google where !linkedGoogle.contains(g.id) && inScope(g.completedAt, completed: g.fields.completed, cutoff: cutoff) {
            keepGoogle.append(g)
        }
        return Result(apple: keepApple, google: keepGoogle, links: keepLinks, forget: forget)
    }
}
