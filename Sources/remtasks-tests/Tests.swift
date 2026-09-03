import Foundation
import RemTasksCore

final class SyncPlannerTests {

    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    var t1: Date { t0.addingTimeInterval(100) }
    var t2: Date { t0.addingTimeInterval(200) }

    func apple(_ id: String, _ title: String, due: String? = nil, done: Bool = false, at: Date? = nil,
               recurring: Bool = false, parent: String? = nil, notes: String? = nil) -> AppleItem {
        AppleItem(id: id, listID: "L", fields: SyncFields(title: title, notes: notes, dueDay: due, completed: done),
                  due: due.flatMap(DueDate.fromDayKey), modifiedAt: at ?? t0, isRecurring: recurring, parentID: parent)
    }

    func google(_ id: String, _ title: String, due: String? = nil, done: Bool = false, at: Date? = nil,
                parent: String? = nil, notes: String? = nil) -> GoogleItem {
        GoogleItem(id: id, listID: "G", fields: SyncFields(title: title, notes: notes, dueDay: due, completed: done),
                   modifiedAt: at ?? t0, parentID: parent)
    }

    func link(_ a: AppleItem, _ g: GoogleItem, fields: SyncFields? = nil, appleParent: String? = nil) -> Link {
        let f = fields ?? a.fields
        return Link(appleID: a.id, googleID: g.id, account: "personal", appleListID: "L", googleListID: "G",
                    fingerprint: f.fingerprint, dueDay: f.dueDay, appleParentID: appleParent, googleParentID: g.parentID, lastSyncAt: t0)
    }

    func plan(_ apple: [AppleItem], _ google: [GoogleItem], _ links: [Link], allowDeletes: Bool = false, maxDeletes: Int = 20) -> SyncPlan {
        SyncPlanner.plan(apple: apple, google: google, links: links,
                         options: PlanOptions(allowDeletes: allowDeletes, maxDeletes: maxDeletes, hierarchyAvailable: true))
    }

    func testEmptyIsNoop() throws {
        try expectEqual(plan([], [], []).actions, [])
    }

    func testUnlinkedItemsAreCreatedOnTheOtherSide() throws {
        let a = apple("a1", "Buy milk")
        let g = google("g1", "Call bank")
        let p = plan([a], [g], [])
        try expectEqual(p.actions, [.createGoogle(a), .createApple(g)])
    }

    func testMatchingTitlesArePairedInsteadOfDuplicated() throws {
        let a = apple("a1", "Buy Milk", due: "2026-09-03")
        let g = google("g1", "buy   milk", due: "2026-09-03")
        let p = plan([a], [g], [])
        try expectEqual(p.actions, [.adopt(a, g, .apple)]) // titles differ in case/whitespace; apple wins tie on time
    }

    func testIdenticalPairAdoptsWithoutPush() throws {
        let a = apple("a1", "Same", due: "2026-09-03")
        let g = google("g1", "Same", due: "2026-09-03")
        try expectEqual(plan([a], [g], []).actions, [.adopt(a, g, .none)])
    }

    func testAppleEditFlowsToGoogle() throws {
        let a0 = apple("a1", "Old title")
        let g = google("g1", "Old title")
        let l = link(a0, g)
        let a = apple("a1", "New title", at: t1)
        try expectEqual(plan([a], [g], [l]).actions, [.updateGoogle(l, a, g)])
    }

    func testGoogleEditFlowsToApple() throws {
        let a = apple("a1", "Title")
        let g0 = google("g1", "Title")
        let l = link(a, g0)
        let g = google("g1", "Title", done: true, at: t1)
        try expectEqual(plan([a], [g], [l]).actions, [.updateApple(l, g, a)])
    }

    func testBothEditedNewerWins() throws {
        let base = apple("a1", "Base")
        let gbase = google("g1", "Base")
        let l = link(base, gbase)
        let a = apple("a1", "Apple edit", at: t2)
        let g = google("g1", "Google edit", at: t1)
        try expectEqual(plan([a], [g], [l]).actions, [.updateGoogle(l, a, g)])
        let a2 = apple("a1", "Apple edit", at: t1)
        let g2 = google("g1", "Google edit", at: t2)
        try expectEqual(plan([a2], [g2], [l]).actions, [.updateApple(l, g2, a2)])
    }

    func testBothEditedToSameContentJustRelinks() throws {
        let base = apple("a1", "Base")
        let l = link(base, google("g1", "Base"))
        let a = apple("a1", "Done", done: true, at: t1)
        let g = google("g1", "Done", done: true, at: t2)
        try expectEqual(plan([a], [g], [l]).actions, [.adopt(a, g, .none)])
    }

    func testUnchangedPairIsNoop() throws {
        let a = apple("a1", "Same")
        let g = google("g1", "Same")
        try expectEqual(plan([a], [g], [link(a, g)]).actions, [])
    }

    func testAppleDeletionDeletesGoogle() throws {
        let a = apple("a1", "Gone")
        let g = google("g1", "Gone")
        let l = link(a, g)
        try expectEqual(plan([], [g], [l]).actions, [.deleteGoogle(l, g)])
    }

    func testGoogleDeletionDeletesApple() throws {
        let a = apple("a1", "Gone")
        let l = link(a, google("g1", "Gone"))
        try expectEqual(plan([a], [], [l]).actions, [.deleteApple(l, a)])
    }

    func testEditAfterDeleteRestores() throws {
        let a = apple("a1", "Keep me")
        let l = link(a, google("g1", "Keep me"))
        let gEdited = google("g1", "Keep me (edited)", at: t1)
        try expectEqual(plan([], [gEdited], [l]).actions, [.restoreApple(l, gEdited)])
        let aEdited = apple("a1", "Keep me (edited)", at: t1)
        try expectEqual(plan([aEdited], [], [l]).actions, [.restoreGoogle(l, aEdited)])
    }

    func testGoneOnBothSidesUnlinks() throws {
        let l = link(apple("a1", "x"), google("g1", "x"))
        try expectEqual(plan([], [], [l]).actions, [.unlink(l)])
    }

    func testDeleteCapSuppressesDeletes() throws {
        var links: [Link] = []
        var googles: [GoogleItem] = []
        for i in 0..<5 {
            let a = apple("a\(i)", "t\(i)")
            let g = google("g\(i)", "t\(i)")
            links.append(link(a, g)); googles.append(g)
        }
        let p = plan([], googles, links, maxDeletes: 3)
        try expectEqual(p.actions, [])
        try expectEqual(p.suppressedDeletes, 5)
        try expectEqual(p.warnings.count, 1)
        let allowed = plan([], googles, links, allowDeletes: true, maxDeletes: 3)
        try expectEqual(allowed.actions.count, 5)
    }

    func testRecurringRollForward() throws {
        let a0 = apple("a1", "Pay rent", due: "2026-09-01", recurring: true)
        let g0 = google("g1", "Pay rent", due: "2026-09-01")
        let l = link(a0, g0)
        // User completed in Google; Apple advanced to the next occurrence.
        let a = apple("a1", "Pay rent", due: "2026-10-01", at: t1, recurring: true)
        let g = google("g1", "Pay rent", due: "2026-09-01", done: true, at: t1)
        try expectEqual(plan([a], [g], [l]).actions, [.rollForward(l, a, g)])
    }

    func testRecurringRollForwardPairsCompletedCopyWithOldGoogleTask() throws {
        // Apple advanced the master (same id) and spawned a completed copy for the finished occurrence.
        let master0 = apple("a1", "Pay rent", due: "2026-09-01", recurring: true)
        let g = google("g1", "Pay rent", due: "2026-09-01", done: true, at: t1)
        let l = link(master0, google("g1", "Pay rent", due: "2026-09-01"))
        let master = apple("a1", "Pay rent", due: "2026-10-01", at: t1, recurring: true)
        let copy = apple("a2", "Pay rent", due: "2026-09-01", done: true, at: t1)
        let p = plan([master, copy], [g], [l])
        try expectEqual(p.actions, [.rollForward(l, master, g), .adopt(copy, g, .none)])
    }

    func testRecurringCompletedInGoogleBeforeAppleAdvancesCompletesApple() throws {
        let a = apple("a1", "Pay rent", due: "2026-09-01", recurring: true)
        let g0 = google("g1", "Pay rent", due: "2026-09-01")
        let l = link(a, g0)
        let g = google("g1", "Pay rent", due: "2026-09-01", done: true, at: t1)
        try expectEqual(plan([a], [g], [l]).actions, [.updateApple(l, g, a)])
    }

    func testSubtaskCreatedAfterParentAndMovedWhenParentLinked() throws {
        let parent = apple("p", "Parent")
        let child = apple("c", "Child", parent: "p")
        let p = plan([child, parent], [], [])
        try expectEqual(p.actions, [.createGoogle(parent), .createGoogle(child)])

        // Next run: both linked, Google child is top-level -> move under parent.
        let gp = google("gp", "Parent")
        let gc = google("gc", "Child")
        let lp = link(parent, gp)
        let lc = link(child, gc)
        try expectEqual(plan([parent, child], [gp, gc], [lp, lc]).actions, [.moveGoogle(lc, gc, "gp")])

        // Apple un-nested the child -> move to top level.
        let gcNested = google("gc", "Child", parent: "gp")
        let childTop = apple("c", "Child")
        let lcNested = link(child, gcNested, appleParent: "p")
        try expectEqual(plan([parent, childTop], [gp, gcNested], [lp, lcNested]).actions, [.moveGoogle(lcNested, gcNested, nil)])
    }

    func testHierarchyIgnoredWhenUnavailable() throws {
        let parent = apple("p", "Parent")
        let child = apple("c", "Child", parent: "p")
        let gp = google("gp", "Parent")
        let gc = google("gc", "Child")
        let p = SyncPlanner.plan(apple: [parent, child], google: [gp, gc], links: [link(parent, gp), link(child, gc)],
                                 options: PlanOptions(hierarchyAvailable: false))
        try expectEqual(p.actions, [])
    }
}

final class ScopeTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var cutoff: Date { now.addingTimeInterval(-30 * 86_400) }
    func a(_ id: String, done: Bool = false, ago days: Double = 0) -> AppleItem {
        AppleItem(id: id, listID: "L", fields: SyncFields(title: id, completed: done), modifiedAt: now,
                  completedAt: done ? now.addingTimeInterval(-days * 86_400) : nil)
    }
    func g(_ id: String, done: Bool = false, ago days: Double = 0) -> GoogleItem {
        GoogleItem(id: id, listID: "G", fields: SyncFields(title: id, completed: done), modifiedAt: now,
                   completedAt: done ? now.addingTimeInterval(-days * 86_400) : nil)
    }
    func link(_ a: String, _ g: String) -> Link {
        Link(appleID: a, googleID: g, account: "p", appleListID: "L", googleListID: "G", fingerprint: "x", dueDay: nil, lastSyncAt: now)
    }

    func testOldCompletionsAreDroppedAndRecentOnesKept() throws {
        let items = [a("open"), a("recent", done: true, ago: 3), a("old", done: true, ago: 90)]
        let r = SyncScope.partition(apple: items, google: [], links: [], cutoff: cutoff)
        try expectEqual(r.apple.map(\.id), ["open", "recent"])
    }

    func testLinkWithBothSidesOldIsForgottenNotDeleted() throws {
        let l = link("a1", "g1")
        let r = SyncScope.partition(apple: [a("a1", done: true, ago: 60)], google: [g("g1", done: true, ago: 60)], links: [l], cutoff: cutoff)
        try expectEqual(r.forget, [l])
        try expectEqual(r.links, [])
        try expectEqual(r.apple, [])
    }

    func testLinkWithOldAppleSideGoneIsForgottenNotRestored() throws {
        let l = link("a1", "g1")
        let r = SyncScope.partition(apple: [], google: [g("g1", done: true, ago: 60)], links: [l], cutoff: cutoff)
        try expectEqual(r.forget, [l])
    }

    func testLinkStaysWhenEitherSideIsLive() throws {
        let l = link("a1", "g1")
        let old = a("a1", done: true, ago: 60)
        let reopened = g("g1")
        let r = SyncScope.partition(apple: [old], google: [reopened], links: [l], cutoff: cutoff)
        try expectEqual(r.links, [l])
        try expectEqual(r.apple, [old])
        try expectEqual(r.google, [reopened])
    }
}

final class ModelTests {
    func testDueDateKeepsTime() throws {
        let apple = DueDate(year: 2026, month: 9, day: 2, hour: 15, minute: 30)
        let fromGoogle = DueDate.fromDayKey("2026-09-10")!
        try expectEqual(fromGoogle.keepingTime(of: apple), DueDate(year: 2026, month: 9, day: 10, hour: 15, minute: 30))
        try expectEqual(fromGoogle.keepingTime(of: DueDate(year: 2026, month: 1, day: 1)), fromGoogle)
        try expectEqual(apple.dayKey, "2026-09-02")
        try expectNil(DueDate.fromDayKey("nope"))
    }

    func testNotesNormalization() throws {
        try expectNil(SyncFields(title: "x", notes: "   \n").notes)
        try expectEqual(SyncFields(title: "x", notes: "a\r\nb ").notes, "a\nb")
        try expectEqual(SyncFields(title: "x", notes: nil).fingerprint, SyncFields(title: "x", notes: "").fingerprint)
    }

    func testTimeOfDay() throws {
        try expectEqual(TimeOfDay(string: "09:05"), TimeOfDay(hour: 9, minute: 5))
        try expectNil(TimeOfDay(string: "25:00"))
        try expectNil(TimeOfDay(string: "9"))
    }
}

final class ConfigTests {
    func testResolveMapping() throws {
        let json = """
        {
          "accounts": { "personal": { "email": "p@example.com" }, "work": { "email": "w@example.com" } },
          "groups": { "Personal": "personal", "Business": "work" },
          "lists": {
            "Reminders": { "account": "personal", "googleListName": "My List" },
            "Shared Groceries": { "account": "personal" },
            "Deals": { "skip": true }
          }
        }
        """
        let cfg = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        try cfg.validate()
        func list(_ name: String, group: String? = nil) -> AppleList { AppleList(id: name, name: name, groupName: group, sourceID: "s", sourceTitle: "iCloud") }
        try expectEqual(cfg.resolve(list: list("Reminders")), .init(account: "personal", googleListName: "My List"))
        try expectEqual(cfg.resolve(list: list("Shared Groceries")), .init(account: "personal", googleListName: "Shared Groceries"))
        try expectEqual(cfg.resolve(list: list("Clients", group: "Business")), .init(account: "work", googleListName: "Clients"))
        try expectNil(cfg.resolve(list: list("Deals", group: "Business")))
        try expectNil(cfg.resolve(list: list("Loose")))
        try expectEqual(cfg.newTaskDefaults.timeOfDay, TimeOfDay(hour: 9, minute: 0))
        try expectEqual(cfg.safety.maxDeletesPerRun, 20)
    }

    func testValidationRejectsUnknownAccount() throws {
        let cfg = Config(accounts: ["personal": .init(email: "p@example.com")], groups: ["Personal": "nope"])
        try expectThrows(try cfg.validate())
    }
}
