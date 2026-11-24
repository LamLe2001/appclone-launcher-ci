import Foundation
import AppCloneDomain

/// Configuration for a simulated engine failure. Used to drive recovery tests
/// (RT-01, RT-02, RT-08) without a real device.
public struct MockFault: Sendable, Equatable {
    public enum Point: String, Sendable, CaseIterable {
        case probe
        case listSources
        case validateSource
        case create
        case inspect
        case quiesce
        case launch
        case reset
        case delete
    }

    public var point: Point
    /// The error thrown at that point.
    public var error: EngineError
    /// When true, the mutation still happens but the reply fails, simulating a
    /// lost response. This is the dangerous case that requires reconciliation.
    public var appliedButReplyLost: Bool

    public init(point: Point, error: EngineError, appliedButReplyLost: Bool = false) {
        self.point = point
        self.error = error
        self.appliedButReplyLost = appliedButReplyLost
    }
}

/// In-memory engine used for UI development and contract tests.
///
/// It is explicitly NOT evidence that any real app can be cloned: the plan
/// forbids ships must not treat mock success as acceptance (plan §15.1).
public actor MockEngine: CloneEngine {
    public nonisolated let kind: EngineKind = .mock
    public nonisolated let adapterVersion = "mock-1.0.0"

    private var sources: [DiscoveredSource]
    /// handle -> marker. Absence of a marker here models a foreign container.
    private var containers: [String: OwnershipMarker?] = [:]
    /// operationID -> handle, giving real idempotency like a native engine may not.
    private var operations: [String: EngineHandle] = [:]
    private var faults: [MockFault.Point: MockFault] = [:]
    private var launchCount = 0
    private var nextHandle = 0

    public init(sources: [DiscoveredSource] = [
        DiscoveredSource(sourceID: "facebook", bundleID: "com.facebook.Facebook",
                         displayName: "Facebook", version: "500.0", build: "100"),
    ]) {
        self.sources = sources
    }

    /// Installs a fault that will fire at the given point.
    public func injectFault(_ fault: MockFault) {
        faults[fault.point] = fault
    }

    public func clearFaults() {
        faults.removeAll()
    }

    /// Seeds a container that has no ownership marker, modelling the original
    /// app's data that must never be touched.
    public func seedForeignContainer(handle: String) {
        containers[handle] = .some(nil)
    }

    public func seedOwnedContainer(handle: String, marker: OwnershipMarker) {
        containers[handle] = .some(marker)
    }

    public func existingHandles() -> [String] { Array(containers.keys) }
    public func dispatchCount() -> Int { launchCount }

    private func throwIfFaulted(_ point: MockFault.Point) throws {
        if let fault = faults[point], !fault.appliedButReplyLost {
            throw fault.error
        }
    }

    private func settleReplyFailure(_ point: MockFault.Point) throws {
        if let fault = faults[point], fault.appliedButReplyLost {
            throw fault.error
        }
    }

    public func probeEnvironment() async throws -> EnvironmentReport {
        try throwIfFaulted(.probe)
        let fingerprint = EnvironmentFingerprint(
            engineKind: .mock,
            engineVersion: "mock",
            adapterVersion: adapterVersion,
            osVersion: "simulator",
            jailbreakFlavor: nil,
            configFingerprint: "mock"
        )
        let all = Capability.allCases.map {
            CapabilityRecord(capability: $0, status: .supported, reason: "mock", evidence: nil)
        }
        return EnvironmentReport(
            fingerprint: fingerprint,
            capabilities: all,
            summary: "Mock engine (UI development only)"
        )
    }

    public func listSources() async throws -> [DiscoveredSource] {
        try throwIfFaulted(.listSources)
        return sources
    }

    public func validateSource(_ sourceID: String) async throws -> Bool {
        try throwIfFaulted(.validateSource)
        return sources.contains { $0.sourceID == sourceID }
    }

    public func createBlankProfile(sourceID: String, operationID: String) async throws -> CreatedProfile {
        // Idempotency: same operation ID never creates a second container.
        if let existing = operations[operationID] {
            return CreatedProfile(handle: existing)
        }
        try throwIfFaulted(.create)
        nextHandle += 1
        let handle = EngineHandle("mock-handle-\(nextHandle)")
        containers[handle.rawValue] = .some(nil)  // marker written by caller
        operations[operationID] = handle
        try settleReplyFailure(.create)
        return CreatedProfile(handle: handle)
    }

    public func inspectProfile(_ handle: EngineHandle) async throws -> InspectedProfile {
        try throwIfFaulted(.inspect)
        guard let entry = containers[handle.rawValue] else {
            return InspectedProfile(handle: handle, exists: false)
        }
        return InspectedProfile(handle: handle, exists: true, marker: entry)
    }

    /// Writes an ownership marker, mirroring what a real adapter must do after
    /// the engine creates a container.
    public func writeMarker(_ marker: OwnershipMarker, to handle: EngineHandle) {
        if containers[handle.rawValue] != nil {
            containers[handle.rawValue] = .some(marker)
        }
    }

    public func quiesce(_ handle: EngineHandle) async throws {
        try throwIfFaulted(.quiesce)
    }

    public func launch(_ handle: EngineHandle) async throws {
        try throwIfFaulted(.launch)
        guard containers[handle.rawValue] != nil else {
            throw EngineError.staleHandle
        }
        launchCount += 1
        try settleReplyFailure(.launch)
    }

    public func resetProfile(_ handle: EngineHandle) async throws {
        try throwIfFaulted(.reset)
        guard containers[handle.rawValue] != nil else { throw EngineError.staleHandle }
        containers[handle.rawValue] = .some(nil)
        try settleReplyFailure(.reset)
    }

    public func deleteProfile(_ handle: EngineHandle) async throws {
        try throwIfFaulted(.delete)
        guard containers[handle.rawValue] != nil else { throw EngineError.staleHandle }
        containers.removeValue(forKey: handle.rawValue)
        try settleReplyFailure(.delete)
    }
}
