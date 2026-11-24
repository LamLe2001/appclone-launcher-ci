import Foundation

/// Kind of asynchronous work the launcher performs. Each kind has an explicit
/// stage sequence so resuming an interrupted job is deterministic.
public enum JobKind: String, Codable, Sendable, CaseIterable {
    case createProfile
    case importSource
    case launchProfile
    case resetProfile
    case deleteProfile
    case backupProfile
    case restoreProfile

    /// Ordered stages. The last stage is terminal-success.
    public var stages: [JobStage] {
        switch self {
        case .createProfile:
            return [.created, .capabilityChecked, .lockAcquired, .engineCreateRequested,
                    .engineHandleReturned, .verified, .committed]
        case .importSource:
            return [.created, .archiveValidated, .extracted, .analyzed,
                    .runtimeChecked, .prepared, .committed]
        case .launchProfile:
            return [.created, .preflightChecked, .lockAcquired, .intentRecorded,
                    .quiesceRequested, .launchDispatched, .committed]
        case .resetProfile:
            return [.created, .capabilityChecked, .lockAcquired, .quiesceRequested,
                    .resetRequested, .verified, .committed]
        case .deleteProfile:
            return [.created, .ownershipVerified, .lockAcquired, .quiesceRequested,
                    .deleteRequested, .verified, .committed]
        case .backupProfile:
            return [.created, .capabilityChecked, .lockAcquired, .snapshotStaged,
                    .encrypted, .committed]
        case .restoreProfile:
            return [.created, .manifestValidated, .lockAcquired, .restoreRequested,
                    .verified, .committed]
        }
    }

    /// Stages after which the operation has changed durable state and can no
    /// longer be safely cancelled (plan §10.4). Cancel is only offered before.
    public var lastCancellableStage: JobStage {
        switch self {
        case .createProfile: return .lockAcquired
        case .importSource: return .analyzed
        case .launchProfile: return .intentRecorded
        case .resetProfile: return .quiesceRequested
        case .deleteProfile: return .quiesceRequested
        case .backupProfile: return .snapshotStaged
        case .restoreProfile: return .restoreRequested
        }
    }
}

/// Individual stage names used across job kinds. Kept flat so the journal is a
/// single table; `JobKind.stages` defines the legal ordering per kind.
public enum JobStage: String, Codable, Sendable, CaseIterable {
    case created
    case capabilityChecked
    case preflightChecked
    case ownershipVerified
    case lockAcquired
    case archiveValidated
    case extracted
    case analyzed
    case runtimeChecked
    case prepared
    case intentRecorded
    case quiesceRequested
    case engineCreateRequested
    case engineHandleReturned
    case launchDispatched
    case resetRequested
    case deleteRequested
    case snapshotStaged
    case manifestValidated
    case restoreRequested
    case encrypted
    case verified
    case committed
}

/// Terminal disposition of a job.
public enum JobOutcome: String, Codable, Sendable {
    case succeeded
    case cancelled
    case failed
    /// Process died mid-job; must be reconciled, not assumed failed or done.
    case interrupted
}

/// Durable journal entry. Written BEFORE the mutation it describes so that a
/// crash leaves evidence (plan §10.1 step 2, §10.4).
public struct OperationJob: Codable, Sendable, Equatable, Identifiable {
    public var id: RecordID
    /// Caller-supplied key so retrying the same user action is idempotent.
    public var idempotencyKey: String
    public var kind: JobKind
    public var appID: RecordID?
    public var profileID: RecordID?
    /// Current stage. Always one of `kind.stages`.
    public var stage: JobStage
    public var outcome: JobOutcome?
    public var errorCode: String?
    /// Operation currently holding the resource lock, if any.
    public var lockOwnerOperation: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// Number of times the job was resumed after an interruption.
    public var resumeCount: Int

    public init(
        id: RecordID = .generate(),
        idempotencyKey: String,
        kind: JobKind,
        appID: RecordID? = nil,
        profileID: RecordID? = nil,
        stage: JobStage = .created,
        outcome: JobOutcome? = nil,
        errorCode: String? = nil,
        lockOwnerOperation: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        resumeCount: Int = 0
    ) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        self.kind = kind
        self.appID = appID
        self.profileID = profileID
        self.stage = stage
        self.outcome = outcome
        self.errorCode = errorCode
        self.lockOwnerOperation = lockOwnerOperation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.resumeCount = resumeCount
    }

    public var isTerminal: Bool { outcome != nil }

    /// Whether the user may cancel at the current stage.
    public var isCancellable: Bool {
        guard !isTerminal else { return false }
        let stages = kind.stages
        guard let currentIndex = stages.firstIndex(of: stage),
              let lastCancelIndex = stages.firstIndex(of: kind.lastCancellableStage)
        else { return false }
        return currentIndex <= lastCancelIndex
    }

    /// Whether this job has passed the point of no return, meaning a resume
    /// must reconcile with the engine rather than simply retry.
    public var isPastCommitBoundary: Bool {
        let stages = kind.stages
        guard let currentIndex = stages.firstIndex(of: stage),
              let lastCancelIndex = stages.firstIndex(of: kind.lastCancellableStage)
        else { return true }
        return currentIndex > lastCancelIndex
    }
}

/// Result of deciding what to do with a job found in the journal at startup.
public enum RecoveryAction: String, Codable, Sendable, Equatable {
    /// No unfinished work.
    case none
    /// Job never touched durable state; safe to retry from the start.
    case retryFromStart
    /// Job passed the commit boundary; reconcile with engine before anything.
    case reconcileWithEngine
    /// Job holds a lock whose owner is gone; release after reconciliation.
    case releaseStaleLock
    /// Job must be surfaced to the user as needing attention.
    case surfaceToUser
}

/// Pure decision logic for startup recovery. Kept free of I/O so it is fully
/// unit-testable and so crash points (RT-01, RT-08) can be simulated exactly.
public enum JobRecovery {
    /// Decides what to do with a job that was not terminal when the process died.
    public static func decide(for job: OperationJob) -> RecoveryAction {
        guard !job.isTerminal else { return .none }

        // A job still at its first stage never mutated anything.
        if job.stage == job.kind.stages.first {
            return job.lockOwnerOperation == nil ? .retryFromStart : .releaseStaleLock
        }

        if job.isPastCommitBoundary {
            return .reconcileWithEngine
        }

        // Mid-job, before the boundary: the only durable effect so far may be
        // an engine container (createProfile) or extracted staging files.
        switch job.kind {
        case .createProfile:
            // engineCreateRequested onward may have produced a handle.
            if job.kind.stages.firstIndex(of: job.stage)! >=
                job.kind.stages.firstIndex(of: .engineCreateRequested)! {
                return .reconcileWithEngine
            }
            return .retryFromStart
        case .importSource:
            return .retryFromStart
        default:
            return .surfaceToUser
        }
    }

    /// Whether the job's current stage is legal for its kind.
    public static func isStageLegal(_ job: OperationJob) -> Bool {
        job.kind.stages.contains(job.stage)
    }

    /// Advances a job one stage, refusing illegal transitions. Returns nil when
    /// the transition is not allowed so callers cannot skip verification steps.
    public static func advance(_ job: OperationJob, to next: JobStage, now: Date = Date()) -> OperationJob? {
        guard !job.isTerminal else { return nil }
        let stages = job.kind.stages
        guard let current = stages.firstIndex(of: job.stage),
              let target = stages.firstIndex(of: next),
              target == current + 1
        else { return nil }
        var updated = job
        updated.stage = next
        updated.updatedAt = now
        if next == stages.last {
            updated.outcome = .succeeded
        }
        return updated
    }
}
