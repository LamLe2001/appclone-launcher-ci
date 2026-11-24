import XCTest
@testable import AppCloneDomain

final class CapabilityTests: XCTestCase {

    private func report(_ statuses: [Capability: CapabilityStatus]) -> EnvironmentReport {
        EnvironmentReport(
            fingerprint: EnvironmentFingerprint(
                engineKind: .mock, adapterVersion: "t", osVersion: "t"),
            capabilities: statuses.map {
                CapabilityRecord(capability: $0.key, status: $0.value)
            },
            summary: "test"
        )
    }

    func testMissingCapabilityIsUnknownNotSupported() {
        let r = report([.probeEnvironment: .supported])
        XCTAssertEqual(r.status(for: .createBlankProfile), .unknown)
        XCTAssertFalse(r.canUse(.createBlankProfile))
    }

    func testUnknownBlocksMutation() {
        // "unknown" is the honest answer when untested; it must not enable writes.
        let r = report([.probeEnvironment: .supported, .createBlankProfile: .unknown])
        XCTAssertFalse(r.mayMutate)
    }

    func testSupportedCreateAllowsMutation() {
        let r = report([.probeEnvironment: .supported, .createBlankProfile: .supported])
        XCTAssertTrue(r.mayMutate)
    }

    func testUnsupportedProbeBlocksEverything() {
        let r = report([.probeEnvironment: .unsupported, .createBlankProfile: .supported])
        XCTAssertFalse(r.mayMutate)
    }

    func testDestructiveCapabilitiesAreFlagged() {
        XCTAssertTrue(Capability.resetProfile.isDestructive)
        XCTAssertTrue(Capability.deleteProfile.isDestructive)
        XCTAssertFalse(Capability.launch.isDestructive)
    }
}

final class ProfileStateTests: XCTestCase {

    func testOnlyHealthyStatesAllowLaunch() {
        XCTAssertTrue(ProfileState.ready.allowsLaunch)
        XCTAssertTrue(ProfileState.recentlyLaunched.allowsLaunch)
        XCTAssertFalse(ProfileState.preparing.allowsLaunch)
        XCTAssertFalse(ProfileState.launching.allowsLaunch)
        XCTAssertFalse(ProfileState.needsAttention.allowsLaunch)
        XCTAssertFalse(ProfileState.unsupported.allowsLaunch)
    }

    func testBusyStatesBlockMutation() {
        XCTAssertFalse(ProfileState.preparing.allowsMutation)
        XCTAssertFalse(ProfileState.launching.allowsMutation)
        XCTAssertFalse(ProfileState.needsAttention.allowsMutation)
        XCTAssertFalse(ProfileState.unsupported.allowsMutation)
        XCTAssertTrue(ProfileState.ready.allowsMutation)
    }

    func testRecentlyLaunchedIsNotEvidenceOfBeingOnline() {
        // Documents the plan rule: a recorded launch is not a login/online state.
        // recentlyLaunched may be launched again, but no state implies session.
        let states: [ProfileState] = [.ready, .preparing, .launching,
                                      .recentlyLaunched, .needsAttention, .unsupported]
        XCTAssertFalse(states.contains { $0.rawValue == "loggedIn" })
    }
}

final class RecordIDTests: XCTestCase {
    func testGeneratedIDIsPathSafe() {
        let id = RecordID.generate()
        XCTAssertTrue(id.isPathSafe, "IDs appear in staging paths and must not contain separators")
    }

    func testTraversalInjectedIDIsRejected() {
        // A malicious/legacy id must never be usable as a path component.
        XCTAssertFalse(RecordID("../../etc/passwd").isPathSafe)
        XCTAssertFalse(RecordID("a/b").isPathSafe)
        XCTAssertFalse(RecordID("").isPathSafe)
        XCTAssertFalse(RecordID("a\\b").isPathSafe)
    }
}
