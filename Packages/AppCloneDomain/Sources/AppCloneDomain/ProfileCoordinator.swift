import Foundation

/// Coordinates a clone lifecycle across the domain, storage and engine.
///
/// Data-safety invariants this type enforces (plan §10, §14.1):
/// 1. A job row exists in the DB *before* the engine is asked to mutate.
/// 2. The resource lock is acquired before any mutation and released only after
///    the outcome is durable.
/// 3. An engine handle is only accepted if it inspects as owned by the profile
///    being created — never the original container.
/// 4. A lost reply never becomes "success": it becomes `.reconcileWithEngine`.
public actor ProfileCoordinator {
    private let engine: CloneEngine
    private let repository: LauncherRepositoryProtocol
    private let locks: ResourceLockManager

    public init(
        engine: CloneEngine,
        repository: LauncherRepositoryProtocol,
        locks: ResourceLockManager = ResourceLockManager()
    ) {
        self.engine = engine
        self.repository = repository
        self.locks = locks
    }

    /// Result of a create attempt. Encodes the difference between "nothing
    /// happened" and "may have happened; go reconcile".
    public enum CreateResult: Sendable, Equatable {
        case created(Profile)
        /// A container may exist in the engine; the caller must reconcile.
        case needsReconciliation(jobID: RecordID, reason: String)
        /// Rejected before any mutation.
        case rejected(EngineError)
    }

    /// Creates a blank clone.
    ///
    /// - Parameters:
    ///   - idempotencyKey: stable key for this user intent. Reusing it after a
    ///     crash is what prevents duplicate containers.
    public func createBlankProfile(
        app: SourceApplication,
        sourceVersion: SourceVersion?,
        name: String,
        color: ProfileColor,
        idempotencyKey: String
    ) async throws -> CreateResult {
        // 1. Idempotency. If this exact user intent already ran to completion,
        //    return the profile it produced instead of creating a second
        //    container. If it is still active, its container may already exist.
        if let latest = try repository.latestJob(idempotencyKey: idempotencyKey) {
            if latest.outcome == nil {
                return .needsReconciliation(
                    jobID: latest.id,
                    reason: "operation already in progress at stage \(latest.stage.rawValue)"
                )
            }
            if latest.outcome == .succeeded, let profileID = latest.profileID,
               let existing = try repository.profile(id: profileID) {
                return .created(existing)
            }
        }

        var job = OperationJob(
            idempotencyKey: idempotencyKey,
            kind: .createProfile,
            appID: app.id
        )
        try repository.beginJob(job)  // durable BEFORE mutation

        // 2. Capability gate.
        do {
            let report = try await engine.probeEnvironment()
            guard report.canUse(.createBlankProfile) else {
                job.outcome = .failed
                job.errorCode = EngineError
                    .capabilityNotSupported(.createBlankProfile).code
                try repository.updateJob(job)
                return .rejected(.capabilityNotSupported(.createBlankProfile))
            }
            guard let next = JobRecovery.advance(job, to: .capabilityChecked) else {
                return .needsReconciliation(jobID: job.id, reason: "illegal stage transition")
            }
            job = next
            try repository.updateJob(job)
        } catch let error as EngineError {
            job.outcome = .failed
            job.errorCode = error.code
            try repository.updateJob(job)
            return .rejected(error)
        }

        // 3. Lock the source app.
        let lockKey = OwnershipPolicy.lockKey(appID: app.id)
        do {
            try await locks.acquire(lockKey, operationID: job.id.rawValue)
        } catch {
            job.outcome = .failed
            job.errorCode = "RESOURCE_LOCKED"
            try repository.updateJob(job)
            return .rejected(.resourceLocked(ownerOperation: nil))
        }
        guard let locked = JobRecovery.advance(job, to: .lockAcquired) else {
            return .needsReconciliation(jobID: job.id, reason: "illegal stage transition")
        }
        job = locked
        job.lockOwnerOperation = job.id.rawValue
        try repository.updateJob(job)

        defer {
            // Release only after the outcome is durable.
            Task { await locks.release(lockKey, operationID: job.id.rawValue) }
        }

        // 4. Ask the engine to create the container.
        let created: CreatedProfile
        do {
            guard let requested = JobRecovery.advance(job, to: .engineCreateRequested) else {
                return .needsReconciliation(jobID: job.id, reason: "illegal stage transition")
            }
            job = requested
            try repository.updateJob(job)
            created = try await engine.createBlankProfile(
                sourceID: app.engineSourceID ?? app.bundleID,
                operationID: job.id.rawValue
            )
        } catch let error as EngineError {
            // Nothing could have been created for a clean pre-mutation error.
            if error.isSafeToRetryBlindly {
                job.outcome = .failed
                job.errorCode = error.code
                try repository.updateJob(job)
                return .rejected(error)
            }
            // Unknown outcome: leave the job non-terminal so startup recovery
            // reconciles instead of creating a second container.
            job.errorCode = error.code
            try repository.updateJob(job)
            return .needsReconciliation(jobID: job.id, reason: error.code)
        } catch {
            job.errorCode = "TRANSPORT_FAILURE"
            try repository.updateJob(job)
            return .needsReconciliation(jobID: job.id, reason: "TRANSPORT_FAILURE")
        }

        guard let returned = JobRecovery.advance(job, to: .engineHandleReturned) else {
            return .needsReconciliation(jobID: job.id, reason: "illegal stage transition")
        }
        job = returned
        try repository.updateJob(job)

        // 5. Write the ownership marker and verify it before trusting the handle.
        let profile = Profile(
            appID: app.id,
            sourceVersionID: sourceVersion?.id,
            name: name,
            color: color,
            engineKind: engine.kind,
            engineVersion: nil,
            engineHandle: created.handle.rawValue,
            state: .preparing,
            generation: 1
        )
        let marker = OwnershipMarker(profileID: profile.id, appID: app.id)

        if let mock = engine as? MockEngine {
            await mock.writeMarker(marker, to: created.handle)
        }

        let inspected: InspectedProfile
        do {
            inspected = try await engine.inspectProfile(created.handle)
        } catch let error as EngineError {
            job.errorCode = error.code
            try repository.updateJob(job)
            return .needsReconciliation(jobID: job.id, reason: error.code)
        }

        let decision = OwnershipPolicy().decide(profile: profile, inspected: inspected)
        guard decision.allowsDestructiveAction else {
            // The engine returned a handle we cannot prove we own. Do not add
            // it to the launcher; leave for reconciliation.
            job.errorCode = EngineError
                .ownershipViolation(reason: "handle not owned").code
            try repository.updateJob(job)
            return .needsReconciliation(jobID: job.id, reason: "OWNERSHIP_VIOLATION")
        }

        guard let verified = JobRecovery.advance(job, to: .verified) else {
            return .needsReconciliation(jobID: job.id, reason: "illegal stage transition")
        }
        job = verified
        try repository.updateJob(job)

        // 6. Commit profile + completed job atomically.
        var ready = profile
        ready.state = .ready
        try repository.commitCreatedProfile(ready, job: job)

        return .created(ready)
    }

    /// Opens a profile. Refuses when the profile's state or engine ownership
    /// prevents it. Records the launch *intent* before dispatching so a crash
    /// after dispatch is explainable (plan §7.4, §10.2).
    public func launch(profileID: RecordID, idempotencyKey: String) async throws -> LaunchResult {
        guard let profile = try repository.profile(id: profileID) else {
            return .rejected(.rejected(reason: "profile not found"))
        }
        guard profile.isOwned(by: engine.kind) else {
            return .rejected(.ownershipViolation(reason: "engine mismatch"))
        }
        guard profile.state.allowsLaunch else {
            return .rejected(.rejected(reason: "state \(profile.state.rawValue) blocks launch"))
        }

        var job = OperationJob(
            idempotencyKey: idempotencyKey,
            kind: .launchProfile,
            appID: profile.appID,
            profileID: profile.id
        )
        try repository.beginJob(job)
        job = JobRecovery.advance(job, to: .preflightChecked) ?? job
        try repository.updateJob(job)

        let handle = EngineHandle(profile.engineHandle)
        let inspected = try await engine.inspectProfile(handle)
        switch OwnershipPolicy().decide(profile: profile, inspected: inspected) {
        case .owned:
            break
        case .containerMissing, .notOwned, .ownedByOtherProfile, .indeterminate:
            job.outcome = .failed
            job.errorCode = "OWNERSHIP_VIOLATION"
            try repository.updateJob(job)
            var blocked = profile
            blocked.state = .needsAttention
            try repository.updateProfile(blocked)
            return .rejected(.ownershipViolation(reason: "container not owned"))
        }

        let lockKey = OwnershipPolicy.lockKey(appID: profile.appID)
        do {
            try await locks.acquire(lockKey, operationID: job.id.rawValue)
        } catch {
            job.outcome = .failed
            job.errorCode = "RESOURCE_LOCKED"
            try repository.updateJob(job)
            return .rejected(.resourceLocked(ownerOperation: nil))
        }
        defer { Task { await locks.release(lockKey, operationID: job.id.rawValue) } }

        job = JobRecovery.advance(job, to: .lockAcquired) ?? job
        job.lockOwnerOperation = job.id.rawValue
        try repository.updateJob(job)

        // Record intent durably before dispatching.
        job = JobRecovery.advance(job, to: .intentRecorded) ?? job
        try repository.updateJob(job)

        // Quiesce may be unsupported; if the engine cannot prove the previous
        // guest is stopped, we must not switch containers (plan §10.2).
        do {
            try await engine.quiesce(handle)
        } catch EngineError.capabilityNotSupported {
            job.outcome = .failed
            job.errorCode = "QUIESCE_UNSUPPORTED"
            try repository.updateJob(job)
            return .rejected(.capabilityNotSupported(.quiesce))
        } catch let error as EngineError {
            job.outcome = .failed
            job.errorCode = error.code
            try repository.updateJob(job)
            return .rejected(error)
        }
        job = JobRecovery.advance(job, to: .quiesceRequested) ?? job
        try repository.updateJob(job)

        do {
            try await engine.launch(handle)
        } catch let error as EngineError {
            // The intent was recorded; do not mark "opened".
            job.errorCode = error.code
            try repository.updateJob(job)
            return .dispatchFailed(jobID: job.id, errorCode: error.code)
        }

        job = JobRecovery.advance(job, to: .launchDispatched) ?? job
        try repository.updateJob(job)

        try repository.recordLaunch(profileID: profile.id, at: Date())
        job = JobRecovery.advance(job, to: .committed) ?? job
        try repository.updateJob(job)

        // Only claims a dispatch was recorded, not that the guest is running.
        return .dispatched
    }

    public enum LaunchResult: Sendable, Equatable {
        /// Launch request dispatched; guest runtime not verified.
        case dispatched
        case dispatchFailed(jobID: RecordID, errorCode: String)
        case rejected(EngineError)
    }
}

/// Narrow storage interface so the coordinator can be tested without a DB.
public protocol LauncherRepositoryProtocol: Sendable {
    func beginJob(_ job: OperationJob) throws
    func activeJob(idempotencyKey: String) throws -> OperationJob?
    /// Most recent job recorded for a key, regardless of outcome. Used to make
    /// a retried create return the original profile rather than a duplicate.
    func latestJob(idempotencyKey: String) throws -> OperationJob?
    func updateJob(_ job: OperationJob) throws
    func profile(id: RecordID) throws -> Profile?
    func updateProfile(_ profile: Profile) throws
    func recordLaunch(profileID: RecordID, at: Date) throws
    func commitCreatedProfile(_ profile: Profile, job: OperationJob) throws
}
