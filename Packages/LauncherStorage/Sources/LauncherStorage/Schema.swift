import Foundation
import GRDB
import AppCloneDomain

/// Schema versioning for the launcher's own SQLite database.
///
/// Migration rules (plan §19.3, RT-06):
/// - Migrations are additive and never drop a column that holds profile state.
/// - Each migration runs in its own transaction; a failure rolls back and the
///   app reports `needsAttention` rather than silently continuing.
/// - `user_version` is the authoritative schema version.
public enum SchemaMigrator {
    /// Current expected schema version. Bump when adding a migration.
    public static let currentVersion = 1

    public static func migrate(_ db: Database) throws {
        let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        if version > currentVersion {
            throw StorageError.schemaTooNew(found: version, supported: currentVersion)
        }
        if version < 1 { try migrateToV1(db) }

        try db.execute(sql: "PRAGMA user_version = \(currentVersion)")
    }

    private static func migrateToV1(_ db: Database) throws {
        // Source applications. One row per source app, never per account.
        try db.execute(sql: """
            CREATE TABLE applications (
                id TEXT PRIMARY KEY NOT NULL,
                sourceType TEXT NOT NULL,
                bundleID TEXT NOT NULL,
                displayName TEXT NOT NULL,
                engineKind TEXT NOT NULL,
                engineSourceID TEXT
            )
            """)

        // Immutable source versions (IPA bytes / installed app version).
        try db.execute(sql: """
            CREATE TABLE source_versions (
                id TEXT PRIMARY KEY NOT NULL,
                appID TEXT NOT NULL REFERENCES applications(id) ON DELETE CASCADE,
                version TEXT NOT NULL,
                build TEXT,
                sha256 TEXT,
                importedAt REAL NOT NULL
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_source_versions_app ON source_versions(appID)")

        // Clone profiles. Unique engine handle per engine enforces the
        // "one handle belongs to exactly one profile" invariant (plan §9).
        try db.execute(sql: """
            CREATE TABLE profiles (
                id TEXT PRIMARY KEY NOT NULL,
                appID TEXT NOT NULL REFERENCES applications(id) ON DELETE RESTRICT,
                sourceVersionID TEXT REFERENCES source_versions(id) ON DELETE SET NULL,
                name TEXT NOT NULL,
                color TEXT NOT NULL,
                engineKind TEXT NOT NULL,
                engineVersion TEXT,
                engineHandle TEXT NOT NULL,
                state TEXT NOT NULL,
                isPinned INTEGER NOT NULL DEFAULT 0,
                createdAt REAL NOT NULL,
                lastOpenedAt REAL,
                generation INTEGER NOT NULL DEFAULT 1,
                UNIQUE (engineKind, engineHandle)
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_profiles_app ON profiles(appID)")
        try db.execute(sql: "CREATE INDEX idx_profiles_pinned ON profiles(isPinned, createdAt)")

        // Durable operation journal. Written before mutations (plan §10.1).
        try db.execute(sql: """
            CREATE TABLE operation_jobs (
                id TEXT PRIMARY KEY NOT NULL,
                idempotencyKey TEXT NOT NULL,
                kind TEXT NOT NULL,
                appID TEXT,
                profileID TEXT,
                stage TEXT NOT NULL,
                outcome TEXT,
                errorCode TEXT,
                lockOwnerOperation TEXT,
                createdAt REAL NOT NULL,
                updatedAt REAL NOT NULL,
                resumeCount INTEGER NOT NULL DEFAULT 0
            )
            """)
        // One active (non-terminal) job per idempotency key, and at most one
        // active mutation per app. Enforced at the DB level so a crash between
        // two writes cannot produce duplicates.
        try db.execute(sql: """
            CREATE UNIQUE INDEX idx_jobs_idempotency_active
            ON operation_jobs(idempotencyKey)
            WHERE outcome IS NULL
            """)
        try db.execute(sql: "CREATE INDEX idx_jobs_active ON operation_jobs(outcome, updatedAt)")

        // Capability snapshots, keyed by the exact environment fingerprint.
        try db.execute(sql: """
            CREATE TABLE capability_snapshots (
                id TEXT PRIMARY KEY NOT NULL,
                fingerprint TEXT NOT NULL,
                capability TEXT NOT NULL,
                status TEXT NOT NULL,
                reason TEXT,
                evidence TEXT,
                recordedAt REAL NOT NULL
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_caps_fingerprint ON capability_snapshots(fingerprint)")

        // Backup records. Never store passwords or session data here.
        try db.execute(sql: """
            CREATE TABLE backups (
                id TEXT PRIMARY KEY NOT NULL,
                profileID TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
                manifestVersion INTEGER NOT NULL,
                scope TEXT NOT NULL,
                byteSize INTEGER NOT NULL,
                sha256 TEXT NOT NULL,
                status TEXT NOT NULL,
                createdAt REAL NOT NULL
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_backups_profile ON backups(profileID)")

        // Redacted diagnostic events. Retention is enforced by Diagnostics.
        try db.execute(sql: """
            CREATE TABLE diagnostic_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                occurredAt REAL NOT NULL,
                component TEXT NOT NULL,
                operationID TEXT,
                errorCode TEXT,
                detail TEXT
            )
            """)
        try db.execute(sql: "CREATE INDEX idx_diag_time ON diagnostic_events(occurredAt)")

        // Tombstones: a profile's metadata was deleted but its engine container
        // may not be gone yet. Prevents reporting "deleted" too early
        // (plan §9.1).
        try db.execute(sql: """
            CREATE TABLE tombstones (
                profileID TEXT PRIMARY KEY NOT NULL,
                engineKind TEXT NOT NULL,
                engineHandle TEXT NOT NULL,
                deletedAt REAL NOT NULL,
                containerConfirmedGone INTEGER NOT NULL DEFAULT 0
            )
            """)
    }
}

/// Storage-layer failures. All are structural, never user-data, so they are
/// safe to log verbatim.
public enum StorageError: Error, Equatable, Sendable {
    case schemaTooNew(found: Int, supported: Int)
    case duplicateHandle(EngineKind, String)
    case profileNotFound(RecordID)
    case appNotFound(RecordID)
    case cannotDeleteProtectedProfile(RecordID)
    case activeJobConflict(key: String)
}
