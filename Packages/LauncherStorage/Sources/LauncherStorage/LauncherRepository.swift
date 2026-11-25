import Foundation
import GRDB
import AppCloneDomain

/// Repository over the launcher's SQLite database.
///
/// All multi-step writes are wrapped in a transaction so a crash cannot leave a
/// half-written profile (plan §10.1 step 5, RT-01).
public final class LauncherRepository: Sendable {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// Opens (or creates) the database, running migrations. Throws rather than
    /// silently continuing on a schema it does not understand.
    public static func open(at url: URL) throws -> LauncherRepository {
        let dbQueue = try DatabaseQueue(path: url.path)
        try dbQueue.write { db in
            try SchemaMigrator.migrate(db)
        }
        return LauncherRepository(dbQueue: dbQueue)
    }

    public static func inMemory() throws -> LauncherRepository {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in try SchemaMigrator.migrate(db) }
        return LauncherRepository(dbQueue: dbQueue)
    }

    public var schemaVersion: Int {
        (try? dbQueue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        }) ?? 0
    }

    // MARK: - Sources

    public func saveApplication(_ app: SourceApplication) throws {
        try dbQueue.write { db in try app.save(db) }
    }

    public func application(id: RecordID) throws -> SourceApplication? {
        try dbQueue.read { db in try SourceApplication.fetchOne(db, key: id.rawValue) }
    }

    /// All cloneable sources. Used by the UI so the user can pick which app a
    /// new clone is created from.
    public func allApplications() throws -> [SourceApplication] {
        try dbQueue.read { db in
            try SourceApplication
                .order(SourceApplication.Columns.displayName.asc)
                .fetchAll(db)
        }
    }

    public func saveSourceVersion(_ version: SourceVersion) throws {
        try dbQueue.write { db in try version.save(db) }
    }

    // MARK: - Profiles

    /// Inserts a profile, enforcing the (engine, handle) uniqueness invariant.
    /// Returns the stored profile.
    @discardableResult
    public func insertProfile(_ profile: Profile) throws -> Profile {
        try dbQueue.write { db in
            // Unique constraint is in the schema; surface a typed error instead
            // of a raw SQLite one.
            let existing = try Profile
                .filter(Profile.Columns.engineKind == profile.engineKind.rawValue)
                .filter(Profile.Columns.engineHandle == profile.engineHandle)
                .fetchOne(db)
            if existing != nil {
                throw StorageError.duplicateHandle(profile.engineKind, profile.engineHandle)
            }
            try profile.insert(db)
            return profile
        }
    }

    /// Commits a profile plus its completing job in a single transaction so the
    /// journal and the profile can never disagree (plan §10.1 step 5).
    public func commitCreatedProfile(_ profile: Profile, job: OperationJob) throws {
        try dbQueue.write { db in
            let existing = try Profile
                .filter(Profile.Columns.engineKind == profile.engineKind.rawValue)
                .filter(Profile.Columns.engineHandle == profile.engineHandle)
                .fetchOne(db)
            if existing != nil {
                throw StorageError.duplicateHandle(profile.engineKind, profile.engineHandle)
            }
            try profile.insert(db)
            var done = job
            done.stage = job.kind.stages.last!
            done.outcome = .succeeded
            done.profileID = profile.id
            done.updatedAt = Date()
            try done.update(db)
        }
    }

    public func profiles() throws -> [Profile] {
        try dbQueue.read { db in
            try Profile
                .order(Profile.Columns.isPinned.desc, Profile.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    public func profile(id: RecordID) throws -> Profile? {
        try dbQueue.read { db in try Profile.fetchOne(db, key: id.rawValue) }
    }

    public func profile(engineKind: EngineKind, handle: String) throws -> Profile? {
        try dbQueue.read { db in
            try Profile
                .filter(Profile.Columns.engineKind == engineKind.rawValue)
                .filter(Profile.Columns.engineHandle == handle)
                .fetchOne(db)
        }
    }

    public func updateProfile(_ profile: Profile) throws {
        try dbQueue.write { db in try profile.update(db) }
    }

    /// Marks a profile as recently launched without implying the guest is
    /// online (plan §7.4).
    public func recordLaunch(profileID: RecordID, at date: Date = Date()) throws {
        try dbQueue.write { db in
            guard var profile = try Profile.fetchOne(db, key: profileID.rawValue) else {
                throw StorageError.profileNotFound(profileID)
            }
            profile.lastOpenedAt = date
            profile.state = .recentlyLaunched
            profile.generation += 1
            try profile.update(db)
        }
    }

    /// Deletes a profile's metadata and writes a tombstone in one transaction.
    /// The engine container may still exist; the tombstone tracks that
    /// (plan §9.1). Refuses to touch a profile that is not owned by us, which
    /// structurally protects the original app's record.
    public func deleteProfileMetadata(profileID: RecordID, at date: Date = Date()) throws {
        try dbQueue.write { db in
            guard let profile = try Profile.fetchOne(db, key: profileID.rawValue) else {
                throw StorageError.profileNotFound(profileID)
            }
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO tombstones
                    (profileID, engineKind, engineHandle, deletedAt, containerConfirmedGone)
                    VALUES (?, ?, ?, ?, 0)
                    """,
                arguments: [profile.id.rawValue, profile.engineKind.rawValue,
                            profile.engineHandle, date]
            )
            _ = try profile.delete(db)
        }
    }

    public func tombstone(profileID: RecordID) throws -> TombstoneRow? {
        try dbQueue.read { db in
            try TombstoneRow.fetchOne(db, key: profileID.rawValue)
        }
    }

    public func markContainerConfirmedGone(profileID: RecordID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE tombstones SET containerConfirmedGone = 1 WHERE profileID = ?",
                arguments: [profileID.rawValue]
            )
        }
    }

    // MARK: - Jobs

    /// Records a job before any mutation. Fails if another active job already
    /// uses this idempotency key, which makes retries safe (plan §10.1).
    public func beginJob(_ job: OperationJob) throws {
        try dbQueue.write { db in
            let active = try OperationJob
                .filter(OperationJob.Columns.idempotencyKey == job.idempotencyKey)
                .filter(OperationJob.Columns.outcome == nil)
                .fetchOne(db)
            if active != nil {
                throw StorageError.activeJobConflict(key: job.idempotencyKey)
            }
            try job.insert(db)
        }
    }

    /// Finds an existing active job for an idempotency key, if any. Callers use
    /// this to avoid creating a second container on a retried user action.
    public func activeJob(idempotencyKey: String) throws -> OperationJob? {
        try dbQueue.read { db in
            try OperationJob
                .filter(OperationJob.Columns.idempotencyKey == idempotencyKey)
                .filter(OperationJob.Columns.outcome == nil)
                .fetchOne(db)
        }
    }

    /// Most recent job for a key, terminal or not. Lets a repeated user action
    /// resolve to the profile the first attempt created.
    public func latestJob(idempotencyKey: String) throws -> OperationJob? {
        try dbQueue.read { db in
            try OperationJob
                .filter(OperationJob.Columns.idempotencyKey == idempotencyKey)
                .order(OperationJob.Columns.updatedAt.desc)
                .fetchOne(db)
        }
    }

    public func updateJob(_ job: OperationJob) throws {
        try dbQueue.write { db in try job.update(db) }
    }

    public func job(id: RecordID) throws -> OperationJob? {
        try dbQueue.read { db in try OperationJob.fetchOne(db, key: id.rawValue) }
    }

    /// All jobs that were not terminal when the process last ran.
    public func unfinishedJobs() throws -> [OperationJob] {
        try dbQueue.read { db in
            try OperationJob
                .filter(OperationJob.Columns.outcome == nil)
                .order(OperationJob.Columns.updatedAt.asc)
                .fetchAll(db)
        }
    }

    public func recentJobs(limit: Int = 50) throws -> [OperationJob] {
        try dbQueue.read { db in
            try OperationJob
                .order(OperationJob.Columns.updatedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Capabilities

    /// Replaces the snapshot for one fingerprint. Stale snapshots are deleted so
    /// a changed environment cannot inherit old "supported" answers
    /// (plan §9, `capability_snapshots`).
    public func saveCapabilitySnapshot(report: EnvironmentReport) throws {
        let fingerprint = EnvironmentFingerprintCodec.encode(report.fingerprint)
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM capability_snapshots WHERE fingerprint = ?",
                arguments: [fingerprint]
            )
            for record in report.capabilities {
                let row = CapabilitySnapshotRow(
                    id: RecordID.generate().rawValue,
                    fingerprint: fingerprint,
                    capability: record.capability.rawValue,
                    status: record.status.rawValue,
                    reason: record.reason,
                    evidence: record.evidence,
                    recordedAt: record.recordedAt
                )
                try row.insert(db)
            }
        }
    }

    public func capabilitySnapshot(fingerprint: EnvironmentFingerprint) throws -> [CapabilitySnapshotRow] {
        let key = EnvironmentFingerprintCodec.encode(fingerprint)
        return try dbQueue.read { db in
            try CapabilitySnapshotRow
                .filter(sql: "fingerprint = ?", arguments: [key])
                .fetchAll(db)
        }
    }
}

/// Stable, order-independent encoding of a fingerprint, used as a cache key.
public enum EnvironmentFingerprintCodec {
    public static func encode(_ fp: EnvironmentFingerprint) -> String {
        [
            fp.engineKind.rawValue,
            fp.engineVersion ?? "-",
            fp.adapterVersion,
            fp.osVersion,
            fp.jailbreakFlavor ?? "-",
            fp.configFingerprint ?? "-",
        ].joined(separator: "|")
    }
}

extension LauncherRepository: LauncherRepositoryProtocol {}
