import Foundation
import RemTasksCore

// Minimal test harness: XCTest is not available with Command Line Tools alone.
struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) throws {
    if a != b { throw TestFailure(description: "\(file):\(line): expected\n  \(b)\ngot\n  \(a)") }
}
func expectNil<T>(_ a: T?, file: StaticString = #filePath, line: UInt = #line) throws {
    if let a { throw TestFailure(description: "\(file):\(line): expected nil, got \(a)") }
}
func expectThrows<T>(_ body: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) throws {
    do { _ = try body() } catch { return }
    throw TestFailure(description: "\(file):\(line): expected an error")
}

final class Runner {
    var passed = 0
    var failed = 0
    func test(_ name: String, _ body: () throws -> Void) {
        do { try body(); passed += 1; print("  ok    \(name)") }
        catch { failed += 1; print("  FAIL  \(name)\n        \(error)") }
    }
}

let runner = Runner()
    runner.test("SyncPlannerTests.testEmptyIsNoop") { try SyncPlannerTests().testEmptyIsNoop() }
    runner.test("SyncPlannerTests.testUnlinkedItemsAreCreatedOnTheOtherSide") { try SyncPlannerTests().testUnlinkedItemsAreCreatedOnTheOtherSide() }
    runner.test("SyncPlannerTests.testMatchingTitlesArePairedInsteadOfDuplicated") { try SyncPlannerTests().testMatchingTitlesArePairedInsteadOfDuplicated() }
    runner.test("SyncPlannerTests.testIdenticalPairAdoptsWithoutPush") { try SyncPlannerTests().testIdenticalPairAdoptsWithoutPush() }
    runner.test("SyncPlannerTests.testAppleEditFlowsToGoogle") { try SyncPlannerTests().testAppleEditFlowsToGoogle() }
    runner.test("SyncPlannerTests.testGoogleEditFlowsToApple") { try SyncPlannerTests().testGoogleEditFlowsToApple() }
    runner.test("SyncPlannerTests.testBothEditedNewerWins") { try SyncPlannerTests().testBothEditedNewerWins() }
    runner.test("SyncPlannerTests.testBothEditedToSameContentJustRelinks") { try SyncPlannerTests().testBothEditedToSameContentJustRelinks() }
    runner.test("SyncPlannerTests.testUnchangedPairIsNoop") { try SyncPlannerTests().testUnchangedPairIsNoop() }
    runner.test("SyncPlannerTests.testAppleDeletionDeletesGoogle") { try SyncPlannerTests().testAppleDeletionDeletesGoogle() }
    runner.test("SyncPlannerTests.testGoogleDeletionDeletesApple") { try SyncPlannerTests().testGoogleDeletionDeletesApple() }
    runner.test("SyncPlannerTests.testEditAfterDeleteRestores") { try SyncPlannerTests().testEditAfterDeleteRestores() }
    runner.test("SyncPlannerTests.testGoneOnBothSidesUnlinks") { try SyncPlannerTests().testGoneOnBothSidesUnlinks() }
    runner.test("SyncPlannerTests.testDeleteCapSuppressesDeletes") { try SyncPlannerTests().testDeleteCapSuppressesDeletes() }
    runner.test("SyncPlannerTests.testRecurringRollForward") { try SyncPlannerTests().testRecurringRollForward() }
    runner.test("SyncPlannerTests.testRecurringRollForwardPairsCompletedCopyWithOldGoogleTask") { try SyncPlannerTests().testRecurringRollForwardPairsCompletedCopyWithOldGoogleTask() }
    runner.test("SyncPlannerTests.testRecurringCompletedInGoogleBeforeAppleAdvancesCompletesApple") { try SyncPlannerTests().testRecurringCompletedInGoogleBeforeAppleAdvancesCompletesApple() }
    runner.test("SyncPlannerTests.testSubtaskCreatedAfterParentAndMovedWhenParentLinked") { try SyncPlannerTests().testSubtaskCreatedAfterParentAndMovedWhenParentLinked() }
    runner.test("SyncPlannerTests.testHierarchyIgnoredWhenUnavailable") { try SyncPlannerTests().testHierarchyIgnoredWhenUnavailable() }
    runner.test("ScopeTests.testOldCompletionsAreDroppedAndRecentOnesKept") { try ScopeTests().testOldCompletionsAreDroppedAndRecentOnesKept() }
    runner.test("ScopeTests.testLinkWithBothSidesOldIsForgottenNotDeleted") { try ScopeTests().testLinkWithBothSidesOldIsForgottenNotDeleted() }
    runner.test("ScopeTests.testLinkWithOldAppleSideGoneIsForgottenNotRestored") { try ScopeTests().testLinkWithOldAppleSideGoneIsForgottenNotRestored() }
    runner.test("ScopeTests.testLinkStaysWhenEitherSideIsLive") { try ScopeTests().testLinkStaysWhenEitherSideIsLive() }
    runner.test("OnePasswordTests.testParsesItemJSON") { try OnePasswordTests().testParsesItemJSON() }
    runner.test("ModelTests.testDueDateKeepsTime") { try ModelTests().testDueDateKeepsTime() }
    runner.test("ModelTests.testNotesNormalization") { try ModelTests().testNotesNormalization() }
    runner.test("ModelTests.testTimeOfDay") { try ModelTests().testTimeOfDay() }
    runner.test("ConfigTests.testResolveMapping") { try ConfigTests().testResolveMapping() }
    runner.test("ConfigTests.testValidationRejectsUnknownAccount") { try ConfigTests().testValidationRejectsUnknownAccount() }
print("\n\(runner.passed) passed, \(runner.failed) failed")
exit(runner.failed == 0 ? 0 : 1)
