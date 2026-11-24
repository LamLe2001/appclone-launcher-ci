import XCTest
@testable import AppCloneDomain
@testable import LauncherStorage

/// End-to-end coordinator behaviour against the real SQLite repository and the
/// in-memory mock engine. These cover the crash/reconciliation scenarios from
/// plan §15.2 (RT-01, RT-02, FB-01, FB-07 protection).
final class CoordinatorTests: XCTestCase {

    private var repo: LauncherRepository!
    private var engine: MockEngine!
    private var app: SourceApplication!

    override func setUpWithError() throws {
        repo = try LauncherRepository.inMemory()
        engine = MockEngine()
        app = SourceApplication(
            sourceType: .installedApp,
            bundleID: "com.facebook.Facebook",
            displayName: "Facebook",
            engineKind: .mock,
            engineSourceID: "facebook"
        )
        try repo.saveApplication(app)
    }

    private func makeCoordinator() -> ProfileCoordinator {
        ProfileCoordinator(engine: engine, repository: repo)
    }

    func testCreateSucceedsAndPersistsReadyProfile() async throws {
        let coordinator = makeCoordinator()
        let result = try await coordinator.createBlankProfile(
            app: app, sourceVersion: nil,
            name: "Facebook Công việc", color: .blue,
            idempotencyKey: "op-1"
        )
        guard case .created(let profile) = result else {
            return XCTFail("expected created, got \(result)")
        }
        XCTAssertEqual(profile.state, .ready)
        XCTAssertEqual(profile.name, "Facebook Công việc")
        XCTAssertEqual(profile.engineKind, .mock)

        let stored = try repo.profile(id: profile.id)
        XCTAssertEqual(stored?.engineHandle, profile.engineHandle)
        XCTAssertTrue(profile.id.isPathSafe)
    }

    func testTwoProfilesGetDistinctHandles() async throws {
        // FB-01: two clones must be distinct containers.
        let coordinator = makeCoordinator()
        let a = try await coordinator.createBlankProfile(
            app: app, sourceVersion: nil, name: "A", color: .blue,
            idempotencyKey: "op-a")
        let b = try await coordinator.createBlankProfile(
            app: app, sourceVersion: nil, name: "B", color: .green,
            idempotencyKey: "op-b")

        guard case .created(let pa) = a, case .created(let pb) = b else {
            return XCTFail("both creates must succeed")
        }
        XCTAssertNotEqual(pa.engineHandle, pb.engineHandle)
        XCTAssertNotEqual(pa.id, pb.id)
    }

    func testOriginalContainerIsNeverTouched() async throws {
        // The original app's container has no marker. Creating clones must not
        // alter or remove it (FB-07, risk "Tác động bản Facebook gốc").
        await engine.seedForeignContainer(handle: "original-facebook")
        let before = await engine.existingHandles()

        let coordinator = makeCoordinator()
        _ = try await coordinator.createBlankProfile(
            app: app, sourceVersion: nil, name: "Clone", color: .blue,
            idempotencyKey: "op-x")

        let after = await engine.existingHandles()
        XCTAssertTrue(after.contains("original-facebook"), "original container must survive")
        XCTAssertEqual(after.count, before.count + 1)

        let inspected = try await engine.inspectProfile(EngineHandle("original-facebook"))
        XCTAssertNil(inspected.marker, "launcher must not stamp a marker on the original")
    }

    func testLostCreateReplyNeedsReconciliationNotSuccess() async throws {
        // RT-01: engine creates the container but the reply is lost. The
        // coordinator must NOT report success and must NOT lose track.
        await engine.injectFault(MockFault(
            point: .create,
            error: .transportFailure(isRetryable: false),
            appliedButReplyLost: true))

        let coordinator = makeCoordinator()
        let result = try await coordinator.createBlankProfile(
            app: app, sourceVersion: nil, name: "Risk", color: .red,
            idempotencyKey: "op-lost")

        guard case .needsReconciliation(let jobID, _) = result else {
            return XCTFail("lost reply must require reconciliation, got \(result)")
        }

        // No profile was committed.
        let profiles = try repo.profiles()
        XCTAssertTrue(profiles.isEmpty)

        // The job stays non-terminal so startup recovery will reconcile.
        let job = try repo.job(id: jobID)
        XCTAssertNotNil(job)
        XCTAssertNil(job?.outcome)
        XCTAssertEqual(JobRecovery.decide(for: job!), .reconcileWithEngine)

        // And a container really does exist in the engine — proving why a
        // blind retry would create an orphan.
        let handles = await engine.existingHandles()
        XCTAssertEqual(handles.count, 1)
    }

    func testRetryWithSameIdempotencyKeyReturnsSameProfile() async throws {
        // RT-02: a repeated user action with the same key must resolve to the
        // original profile and must not create a second container.
        let coordinator = makeCoordinator()
        guard case .created(let first) = try await coordinator.createBlankProfile(
            app: app, sourceVersion: nil, name: "Once", color: .blue,
            idempotencyKey: "op-dup") else {
            return XCTFail("first create failed")
        }
        let handlesAfterFirst = await engine.existingHandles()

        let second = try await coordinator.createBlankProfile(
            app: app, sourceVersion: nil, name: "Once", color: .blue,
            idempotencyKey: "op-dup")

        guard case .created(let again) = second else {
            return XCTFail("repeat with same key should return the existing profile, got \(second)")
        }
        XCTAssertEqual(again.id, first.id, "same key must resolve to the same profile")
        XCTAssertEqual(again.engineHandle, first.engineHandle)

        let handlesAfterSecond = await engine.existingHandles()
        XCTAssertEqual(handlesAfterSecond.count, handlesAfterFirst.count,
                       "no second container may be created for a repeated key")
        XCTAssertEqual(try repo.profiles().count, 1)
    }

    func testCapabilityUnsupportedRejectsBeforeMutation() async throws {
        // A configuration without createBlankProfile must not mutate anything.
        let brokenEngine = CapabilityLimitedEngine()
        let coordinator = ProfileCoordinator(engine: brokenEngine, repository: repo)
        let result = try await coordinator.createBlankProfile(
            app: app, sourceVersion: nil, name: "Nope", color: .blue,
            idempotencyKey: "op-cap")
        guard case .rejected = result else {
            return XCTFail("must reject when capability unsupported")
        }
        XCTAssertTrue(try repo.profiles().isEmpty)
    }

    func testLaunchRecordsDispatchWithoutClaimingOnline() async throws {
        let coordinator = makeCoordinator()
        guard case .created(let profile) = try await coordinator.createBlankProfile(
            app: app, sourceVersion: nil, name: "L", color: .blue,
            idempotencyKey: "op-l") else {
            return XCTFail("create failed")
        }

        let outcome = try await coordinator.launch(profileID: profile.id, idempotencyKey: "launch-1")
        XCTAssertEqual(outcome, .dispatched)

        let stored = try repo.profile(id: profile.id)
        XCTAssertEqual(stored?.state, .recentlyLaunched)
        XCTAssertNotNil(stored?.lastOpenedAt)
    }

    func testLaunchRefusesWhenContainerOwnershipLost() async throws {
        let coordinator = makeCoordinator()
        guard case .created(let profile) = try await coordinator.createBlankProfile(
            app: app, sourceVersion: nil, name: "L", color: .blue,
            idempotencyKey: "op-l2") else {
            return XCTFail("create failed")
        }
        // Simulate an upstream tool wiping the container (RT-05).
        try await engine.deleteProfile(EngineHandle(profile.engineHandle))

        let outcome = try await coordinator.launch(profileID: profile.id, idempotencyKey: "launch-2")
        if case .rejected = outcome {
            // expected
        } else {
            XCTFail("must refuse launch when container missing, got \(outcome)")
        }

        // Profile is flagged, and its data record is preserved.
        let stored = try repo.profile(id: profile.id)
        XCTAssertEqual(stored?.state, .needsAttention)
    }
}

/// Engine that advertises no create capability, to prove the gate works.
private actor CapabilityLimitedEngine: CloneEngine {
    nonisolated let kind: EngineKind = .mock
    nonisolated let adapterVersion = "limited"

    func probeEnvironment() async throws -> EnvironmentReport {
        EnvironmentReport(
            fingerprint: EnvironmentFingerprint(
                engineKind: .mock, adapterVersion: adapterVersion, osVersion: "t"),
            capabilities: [CapabilityRecord(capability: .probeEnvironment, status: .supported)],
            summary: "limited")
    }
    func listSources() async throws -> [DiscoveredSource] { [] }
    func validateSource(_ sourceID: String) async throws -> Bool { false }
    func createBlankProfile(sourceID: String, operationID: String) async throws -> CreatedProfile {
        XCTFail("createBlankProfile must not be called when capability is unsupported")
        throw EngineError.capabilityNotSupported(.createBlankProfile)
    }
    func inspectProfile(_ handle: EngineHandle) async throws -> InspectedProfile {
        InspectedProfile(handle: handle, exists: false)
    }
    func quiesce(_ handle: EngineHandle) async throws {}
    func launch(_ handle: EngineHandle) async throws {}
    func resetProfile(_ handle: EngineHandle) async throws {}
    func deleteProfile(_ handle: EngineHandle) async throws {}
}
