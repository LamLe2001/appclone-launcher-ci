import Foundation

/// Decides whether the launcher may act on a profile's container.
///
/// This is deliberately a separate, pure component: every destructive path in
/// the app must ask it first, and it is exhaustively unit-tested. The original
/// app's container is protected because it has no ownership marker at all
/// (plan §9, §10.3, risk table "Tác động bản Facebook gốc").
public struct OwnershipPolicy: Sendable {

    public enum Decision: Equatable, Sendable {
        /// Launcher created this container and owns it.
        case owned
        /// Container belongs to a different profile.
        case ownedByOtherProfile(RecordID)
        /// No marker: this is the original app or a foreign container.
        case notOwned
        /// Record exists but the engine no longer has the container.
        case containerMissing
        /// Cannot determine; mutations must be blocked.
        case indeterminate(reason: String)

        public var allowsDestructiveAction: Bool {
            if case .owned = self { return true }
            return false
        }
    }

    public init() {}

    /// Evaluates a launcher record against what the engine currently reports.
    public func decide(profile: Profile, inspected: InspectedProfile) -> Decision {
        guard inspected.exists else { return .containerMissing }

        guard let marker = inspected.marker else {
            // This is the critical protection: no marker means the launcher did
            // not create this container, so it must never be modified.
            return .notOwned
        }

        guard marker.profileID == profile.id else {
            return .ownedByOtherProfile(marker.profileID)
        }

        guard marker.appID == profile.appID else {
            return .indeterminate(reason: "marker app mismatch")
        }

        return .owned
    }

    /// Whether a lock key may be taken. One mutation at a time per source app
    /// (plan §8.2); launching additionally serializes the whole switch chain.
    public static func lockKey(appID: RecordID) -> String {
        "app:\(appID.rawValue)"
    }
}

/// Serializes mutations to a single source app. Deliberately in-memory with an
/// explicit owner operation ID so a stale lock from a dead process is
/// detectable rather than silently expiring (plan §8.2: "không xóa khóa chỉ vì
/// hết timeout khi chưa đối soát engine").
public actor ResourceLockManager {
    private struct Held {
        let operationID: String
        let acquiredAt: Date
    }

    private var locks: [String: Held] = [:]
    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    public enum LockError: Error, Equatable {
        case alreadyHeld(byOperation: String)
    }

    /// Acquires a lock or throws with the current owner. Callers must pass a
    /// unique operation ID so a crash can be attributed to a specific job.
    public func acquire(_ key: String, operationID: String) throws {
        if let existing = locks[key] {
            throw LockError.alreadyHeld(byOperation: existing.operationID)
        }
        locks[key] = Held(operationID: operationID, acquiredAt: clock())
    }

    /// Releases only if the caller is the current owner. A non-owner cannot
    /// release someone else's lock, which prevents a resumed job from stealing
    /// a live lock.
    @discardableResult
    public func release(_ key: String, operationID: String) -> Bool {
        guard let existing = locks[key], existing.operationID == operationID else {
            return false
        }
        locks.removeValue(forKey: key)
        return true
    }

    /// Releases a lock whose owning job is known to be dead, after the caller
    /// has reconciled engine state. Requires the expected owner so a wrong
    /// reconciliation cannot drop a live lock.
    @discardableResult
    public func forceRelease(_ key: String, expectedOwner: String) -> Bool {
        guard let existing = locks[key], existing.operationID == expectedOwner else {
            return false
        }
        locks.removeValue(forKey: key)
        return true
    }

    public func owner(of key: String) -> String? { locks[key]?.operationID }
    public var heldKeys: [String] { Array(locks.keys) }
}
