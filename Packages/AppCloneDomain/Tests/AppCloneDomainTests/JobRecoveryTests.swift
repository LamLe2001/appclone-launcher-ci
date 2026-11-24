import XCTest
@testable import AppCloneDomain

final class JobRecoveryTests: XCTestCase {

    func testLegalSequentialAdvance() {
        var job = OperationJob(idempotencyKey: "k", kind: .createProfile)
        XCTAssertEqual(job.stage, .created)

        let next = JobRecovery.advance(job, to: .capabilityChecked)
        XCTAssertNotNil(next)
        job = next!
        XCTAssertEqual(job.stage, .capabilityChecked)
    }

    func testSkippingStagesIsRejected() {
        let job = OperationJob(idempotencyKey: "k", kind: .createProfile)
        // Skipping from created straight to verified must be refused.
        XCTAssertNil(JobRecovery.advance(job, to: .verified))
        XCTAssertNil(JobRecovery.advance(job, to: .committed))
    }

    func testIllegalStageForKindIsRefused() {
        let job = OperationJob(idempotencyKey: "k", kind: .createProfile)
        // archiveValidated belongs to importSource, not createProfile.
        XCTAssertNil(JobRecovery.advance(job, to: .archiveValidated))
    }

    func testFinalAdvanceMarksSuccess() {
        var job = OperationJob(idempotencyKey: "k", kind: .createProfile)
        for stage in JobKind.createProfile.stages.dropFirst() {
            job = JobRecovery.advance(job, to: stage)!
        }
        XCTAssertEqual(job.stage, .committed)
        XCTAssertEqual(job.outcome, .succeeded)
    }

    func testTerminalJobCannotAdvance() {
        var job = OperationJob(idempotencyKey: "k", kind: .createProfile)
        job.outcome = .succeeded
        XCTAssertNil(JobRecovery.advance(job, to: .capabilityChecked))
    }

    // MARK: - Recovery decisions (RT-01, RT-08)

    func testFreshJobRetriesFromStart() {
        let job = OperationJob(idempotencyKey: "k", kind: .createProfile)
        XCTAssertEqual(JobRecovery.decide(for: job), .retryFromStart)
    }

    func testJobAtEngineCreateBoundaryReconciles() {
        // Crash after asking the engine to create: a container may exist.
        var job = OperationJob(idempotencyKey: "k", kind: .createProfile)
        job.stage = .engineCreateRequested
        XCTAssertEqual(JobRecovery.decide(for: job), .reconcileWithEngine)
    }

    func testJobPastCommitBoundaryReconciles() {
        var job = OperationJob(idempotencyKey: "k", kind: .createProfile)
        job.stage = .verified
        XCTAssertEqual(JobRecovery.decide(for: job), .reconcileWithEngine)
    }

    func testStaleLockIsFlagged() {
        var job = OperationJob(idempotencyKey: "k", kind: .createProfile)
        job.lockOwnerOperation = job.id.rawValue
        XCTAssertEqual(JobRecovery.decide(for: job), .releaseStaleLock)
    }

    func testTerminalJobNeedsNothing() {
        var job = OperationJob(idempotencyKey: "k", kind: .createProfile)
        job.outcome = .succeeded
        XCTAssertEqual(JobRecovery.decide(for: job), .none)
    }

    func testCancellabilityStopsAtCommitBoundary() {
        var job = OperationJob(idempotencyKey: "k", kind: .createProfile)
        XCTAssertTrue(job.isCancellable)
        job.stage = .lockAcquired
        XCTAssertTrue(job.isCancellable)
        job.stage = .engineCreateRequested
        XCTAssertFalse(job.isCancellable, "After the engine may have created data, cancel must not be offered")
    }

    func testStageLegality() {
        var job = OperationJob(idempotencyKey: "k", kind: .launchProfile)
        job.stage = .archiveValidated  // wrong kind
        XCTAssertFalse(JobRecovery.isStageLegal(job))
        job.stage = .launchDispatched
        XCTAssertTrue(JobRecovery.isStageLegal(job))
    }
}

final class OwnershipPolicyTests: XCTestCase {

    private func makeProfile(app: RecordID = RecordID("app-1")) -> Profile {
        Profile(appID: app, name: "A", engineKind: .mock, engineHandle: "h1")
    }

    func testOwnedWhenMarkerMatches() {
        let profile = makeProfile()
        let inspected = InspectedProfile(
            handle: EngineHandle(profile.engineHandle),
            exists: true,
            marker: OwnershipMarker(profileID: profile.id, appID: profile.appID)
        )
        XCTAssertEqual(OwnershipPolicy().decide(profile: profile, inspected: inspected), .owned)
    }

    func testOriginalAppWithoutMarkerIsNotOwned() {
        // This is the critical protection: the pre-existing Facebook container
        // has no marker, so it can never be deleted or reset by us.
        let profile = makeProfile()
        let inspected = InspectedProfile(handle: EngineHandle("original"), exists: true, marker: nil)
        let decision = OwnershipPolicy().decide(profile: profile, inspected: inspected)
        XCTAssertEqual(decision, .notOwned)
        XCTAssertFalse(decision.allowsDestructiveAction)
    }

    func testForeignMarkerBlocksAction() {
        let profile = makeProfile()
        let other = RecordID("other-profile")
        let inspected = InspectedProfile(
            handle: EngineHandle(profile.engineHandle),
            exists: true,
            marker: OwnershipMarker(profileID: other, appID: profile.appID)
        )
        XCTAssertEqual(
            OwnershipPolicy().decide(profile: profile, inspected: inspected),
            .ownedByOtherProfile(other)
        )
    }

    func testMissingContainerReported() {
        let profile = makeProfile()
        let inspected = InspectedProfile(handle: EngineHandle(profile.engineHandle), exists: false)
        XCTAssertEqual(OwnershipPolicy().decide(profile: profile, inspected: inspected), .containerMissing)
    }

    func testAppMismatchIsIndeterminate() {
        let profile = makeProfile(app: RecordID("app-1"))
        let inspected = InspectedProfile(
            handle: EngineHandle(profile.engineHandle),
            exists: true,
            marker: OwnershipMarker(profileID: profile.id, appID: RecordID("different-app"))
        )
        if case .indeterminate = OwnershipPolicy().decide(profile: profile, inspected: inspected) {
            // expected
        } else {
            XCTFail("app mismatch must be indeterminate")
        }
    }

    func testOnlyOwnedAllowsDestructiveAction() {
        XCTAssertTrue(OwnershipPolicy.Decision.owned.allowsDestructiveAction)
        XCTAssertFalse(OwnershipPolicy.Decision.notOwned.allowsDestructiveAction)
        XCTAssertFalse(OwnershipPolicy.Decision.containerMissing.allowsDestructiveAction)
        XCTAssertFalse(OwnershipPolicy.Decision.indeterminate(reason: "x").allowsDestructiveAction)
        XCTAssertFalse(OwnershipPolicy.Decision.ownedByOtherProfile(RecordID("x")).allowsDestructiveAction)
    }
}

final class ResourceLockManagerTests: XCTestCase {

    func testSecondAcquireFails() async throws {
        let mgr = ResourceLockManager()
        try await mgr.acquire("app:1", operationID: "op-a")
        do {
            try await mgr.acquire("app:1", operationID: "op-b")
            XCTFail("second acquire must fail")
        } catch let error as ResourceLockManager.LockError {
            XCTAssertEqual(error, .alreadyHeld(byOperation: "op-a"))
        }
    }

    func testNonOwnerCannotRelease() async throws {
        let mgr = ResourceLockManager()
        try await mgr.acquire("app:1", operationID: "op-a")
        let released = await mgr.release("app:1", operationID: "op-b")
        XCTAssertFalse(released)
        let owner = await mgr.owner(of: "app:1")
        XCTAssertEqual(owner, "op-a")
    }

    func testOwnerReleases() async throws {
        let mgr = ResourceLockManager()
        try await mgr.acquire("app:1", operationID: "op-a")
        let released = await mgr.release("app:1", operationID: "op-a")
        XCTAssertTrue(released)
        let owner = await mgr.owner(of: "app:1")
        XCTAssertNil(owner)
    }

    func testForceReleaseRequiresExpectedOwner() async throws {
        let mgr = ResourceLockManager()
        try await mgr.acquire("app:1", operationID: "dead-op")
        let wrong = await mgr.forceRelease("app:1", expectedOwner: "live-op")
        XCTAssertFalse(wrong, "must not drop a lock on mismatched reconciliation")
        let right = await mgr.forceRelease("app:1", expectedOwner: "dead-op")
        XCTAssertTrue(right)
    }
}
