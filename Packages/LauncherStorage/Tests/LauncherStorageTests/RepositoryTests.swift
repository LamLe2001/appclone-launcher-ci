import XCTest
@testable import LauncherStorage
import AppCloneDomain

final class RepositoryTests: XCTestCase {

    private var repo: LauncherRepository!

    override func setUpWithError() throws {
        repo = try LauncherRepository.inMemory()
    }

    func testMigrationSetsSchemaVersion() {
        XCTAssertEqual(repo.schemaVersion, SchemaMigrator.currentVersion)
    }

    func testMigrationIsIdempotent() throws {
        // Re-running migrate on an up-to-date DB must be a no-op, not an error.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mig-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try LauncherRepository.open(at: url)
        let second = try LauncherRepository.open(at: url)
        XCTAssertEqual(second.schemaVersion, SchemaMigrator.currentVersion)
    }

    private func makeApp() throws -> SourceApplication {
        let app = SourceApplication(
            sourceType: .installedApp, bundleID: "com.facebook.Facebook",
            displayName: "Facebook", engineKind: .mock, engineSourceID: "facebook")
        try repo.saveApplication(app)
        return app
    }

    func testDuplicateEngineHandleRejected() throws {
        let app = try makeApp()
        let p1 = Profile(appID: app.id, name: "A", engineKind: .mock, engineHandle: "h1")
        try repo.insertProfile(p1)

        let p2 = Profile(appID: app.id, name: "B", engineKind: .mock, engineHandle: "h1")
        XCTAssertThrowsError(try repo.insertProfile(p2)) { error in
            XCTAssertEqual(error as? StorageError, .duplicateHandle(.mock, "h1"))
        }
    }

    func testSameHandleAllowedAcrossEngines() throws {
        let app = try makeApp()
        try repo.insertProfile(Profile(appID: app.id, name: "A", engineKind: .mock, engineHandle: "h1"))
        // A handle is only unique within its engine.
        try repo.insertProfile(Profile(appID: app.id, name: "B", engineKind: .jailbreak, engineHandle: "h1"))
        XCTAssertEqual(try repo.profiles().count, 2)
    }

    func testActiveJobConflictPreventsDuplicateWork() throws {
        let app = try makeApp()
        let job = OperationJob(idempotencyKey: "key-1", kind: .createProfile, appID: app.id)
        try repo.beginJob(job)

        XCTAssertThrowsError(
            try repo.beginJob(OperationJob(idempotencyKey: "key-1", kind: .createProfile))
        ) { error in
            XCTAssertEqual(error as? StorageError, .activeJobConflict(key: "key-1"))
        }
    }

    func testFinishedJobAllowsSameKeyAgain() throws {
        let app = try makeApp()
        var job = OperationJob(idempotencyKey: "key-2", kind: .createProfile, appID: app.id)
        try repo.beginJob(job)
        job.outcome = .succeeded
        try repo.updateJob(job)

        // A completed job should not block a new one with the same key.
        XCTAssertNoThrow(try repo.beginJob(OperationJob(idempotencyKey: "key-2", kind: .createProfile)))
    }

    func testUnfinishedJobsSurfaceForRecovery() throws {
        let app = try makeApp()
        var done = OperationJob(idempotencyKey: "done", kind: .createProfile, appID: app.id)
        try repo.beginJob(done)
        done.outcome = .succeeded
        try repo.updateJob(done)

        let pending = OperationJob(idempotencyKey: "pending", kind: .createProfile, appID: app.id)
        try repo.beginJob(pending)

        let unfinished = try repo.unfinishedJobs()
        XCTAssertEqual(unfinished.count, 1)
        XCTAssertEqual(unfinished.first?.idempotencyKey, "pending")
    }

    func testDeleteWritesTombstoneAndKeepsEvidence() throws {
        let app = try makeApp()
        let profile = Profile(appID: app.id, name: "Gone", engineKind: .mock, engineHandle: "h9")
        try repo.insertProfile(profile)

        try repo.deleteProfileMetadata(profileID: profile.id)

        XCTAssertNil(try repo.profile(id: profile.id))
        let stone = try repo.tombstone(profileID: profile.id)
        XCTAssertNotNil(stone)
        XCTAssertEqual(stone?.engineHandle, "h9")
        XCTAssertEqual(stone?.containerConfirmedGone, false,
                       "metadata deletion must not claim the container is gone")

        try repo.markContainerConfirmedGone(profileID: profile.id)
        XCTAssertEqual(try repo.tombstone(profileID: profile.id)?.containerConfirmedGone, true)
    }

    func testProfilesOrderedPinnedFirst() throws {
        let app = try makeApp()
        let old = Date(timeIntervalSince1970: 1000)
        try repo.insertProfile(Profile(appID: app.id, name: "Normal", engineKind: .mock,
                                       engineHandle: "n", isPinned: false, createdAt: old.addingTimeInterval(10)))
        try repo.insertProfile(Profile(appID: app.id, name: "Pinned", engineKind: .mock,
                                       engineHandle: "p", isPinned: true, createdAt: old))

        let ordered = try repo.profiles()
        XCTAssertEqual(ordered.first?.name, "Pinned")
    }

    func testCapabilitySnapshotReplacedNotAppended() throws {
        let fp = EnvironmentFingerprint(engineKind: .mock, adapterVersion: "1", osVersion: "15.8.5")
        let report1 = EnvironmentReport(
            fingerprint: fp,
            capabilities: [CapabilityRecord(capability: .launch, status: .unknown)],
            summary: "s1")
        try repo.saveCapabilitySnapshot(report: report1)
        XCTAssertEqual(try repo.capabilitySnapshot(fingerprint: fp).count, 1)

        // A new probe for the same fingerprint replaces the old answer, so a
        // stale "supported" cannot linger after re-testing.
        let report2 = EnvironmentReport(
            fingerprint: fp,
            capabilities: [CapabilityRecord(capability: .launch, status: .unsupported)],
            summary: "s2")
        try repo.saveCapabilitySnapshot(report: report2)
        let rows = try repo.capabilitySnapshot(fingerprint: fp)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.status, "unsupported")
    }

    func testDifferentFingerprintsDoNotShareSnapshot() throws {
        let a = EnvironmentFingerprint(engineKind: .mock, adapterVersion: "1", osVersion: "15.8.5")
        let b = EnvironmentFingerprint(engineKind: .jailbreak, adapterVersion: "1", osVersion: "15.8.5")
        try repo.saveCapabilitySnapshot(report: EnvironmentReport(
            fingerprint: a,
            capabilities: [CapabilityRecord(capability: .launch, status: .supported)],
            summary: "a"))
        XCTAssertTrue(try repo.capabilitySnapshot(fingerprint: b).isEmpty,
                      "a different configuration must not inherit tested capability")
    }

    func testFingerprintCodecIsStableAndDistinct() {
        let a = EnvironmentFingerprint(engineKind: .mock, engineVersion: "1",
                                       adapterVersion: "a", osVersion: "15.8.5",
                                       jailbreakFlavor: "rootless", configFingerprint: "c")
        let b = EnvironmentFingerprint(engineKind: .mock, engineVersion: "1",
                                       adapterVersion: "a", osVersion: "15.8.5",
                                       jailbreakFlavor: "rootful", configFingerprint: "c")
        XCTAssertNotEqual(EnvironmentFingerprintCodec.encode(a),
                          EnvironmentFingerprintCodec.encode(b))
        XCTAssertEqual(EnvironmentFingerprintCodec.encode(a),
                       EnvironmentFingerprintCodec.encode(a))
    }
}
