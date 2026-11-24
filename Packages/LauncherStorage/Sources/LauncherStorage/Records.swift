import Foundation
import GRDB
import AppCloneDomain

// GRDB record conformances. These live in the storage package so the domain
// stays free of persistence concerns.

extension RecordID: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { rawValue.databaseValue }
    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> RecordID? {
        String.fromDatabaseValue(dbValue).map(RecordID.init)
    }
}

extension SourceApplication: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "applications"
    public enum Columns: String, ColumnExpression {
        case id, sourceType, bundleID, displayName, engineKind, engineSourceID
    }
}

extension SourceVersion: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "source_versions"
    public enum Columns: String, ColumnExpression {
        case id, appID, version, build, sha256, importedAt
    }
}

extension Profile: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "profiles"
    public enum Columns: String, ColumnExpression {
        case id, appID, sourceVersionID, name, color, engineKind, engineVersion,
             engineHandle, state, isPinned, createdAt, lastOpenedAt, generation
    }
}

extension OperationJob: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "operation_jobs"
    public enum Columns: String, ColumnExpression {
        case id, idempotencyKey, kind, appID, profileID, stage, outcome,
             errorCode, lockOwnerOperation, createdAt, updatedAt, resumeCount
    }

    public func didInsert(_ inserted: InsertionSuccess) {}
}

/// Row types for tables that are not direct domain models.

public struct CapabilitySnapshotRow: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "capability_snapshots"
    public var id: String
    public var fingerprint: String
    public var capability: String
    public var status: String
    public var reason: String?
    public var evidence: String?
    public var recordedAt: Date
}

public enum BackupStatus: String, Codable, Sendable {
    case staged, verified, failed
}

public struct BackupRow: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "backups"
    public var id: String
    public var profileID: String
    public var manifestVersion: Int
    public var scope: String
    public var byteSize: Int64
    public var sha256: String
    public var status: String
    public var createdAt: Date
}

public struct DiagnosticEventRow: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "diagnostic_events"
    public var id: Int64?
    public var occurredAt: Date
    public var component: String
    public var operationID: String?
    public var errorCode: String?
    public var detail: String?
}

public struct TombstoneRow: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tombstones"
    public var profileID: String
    public var engineKind: String
    public var engineHandle: String
    public var deletedAt: Date
    public var containerConfirmedGone: Bool
}
