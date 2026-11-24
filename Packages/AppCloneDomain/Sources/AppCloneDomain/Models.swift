import Foundation

/// Stable identifier for launcher-owned records. A UUID string is used rather
/// than display names because names are user-editable and localized
/// (plan §9: "không dùng tên hiển thị làm đường dẫn").
public struct RecordID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static func generate() -> RecordID {
        RecordID(UUID().uuidString.lowercased())
    }

    public var description: String { rawValue }

    /// IDs are used in file staging paths, so they must be path-safe.
    public var isPathSafe: Bool {
        !rawValue.isEmpty
            && rawValue.allSatisfy { $0.isHexDigit || $0 == "-" }
    }
}

/// A source application the launcher can clone from.
public struct SourceApplication: Codable, Sendable, Equatable, Identifiable {
    public var id: RecordID
    public var sourceType: SourceType
    /// Bundle identifier of the source app (e.g. com.facebook.Facebook).
    public var bundleID: String
    public var displayName: String
    public var engineKind: EngineKind
    /// Handle/id the engine uses for this source, when known.
    public var engineSourceID: String?

    public init(
        id: RecordID = .generate(),
        sourceType: SourceType,
        bundleID: String,
        displayName: String,
        engineKind: EngineKind,
        engineSourceID: String? = nil
    ) {
        self.id = id
        self.sourceType = sourceType
        self.bundleID = bundleID
        self.displayName = displayName
        self.engineKind = engineKind
        self.engineSourceID = engineSourceID
    }
}

/// A specific immutable version of a source. Imported IPAs keep their source
/// bytes immutable; an update creates a new version record (plan §9).
public struct SourceVersion: Codable, Sendable, Equatable, Identifiable {
    public var id: RecordID
    public var appID: RecordID
    public var version: String
    public var build: String?
    /// SHA-256 of the source artifact, hex encoded. nil when not measurable.
    public var sha256: String?
    public var importedAt: Date

    public init(
        id: RecordID = .generate(),
        appID: RecordID,
        version: String,
        build: String? = nil,
        sha256: String? = nil,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.appID = appID
        self.version = version
        self.build = build
        self.sha256 = sha256
        self.importedAt = importedAt
    }
}

/// Lifecycle state of a clone profile. These map 1:1 to the statuses named in
/// plan §7.4. Crucially, `.launched` means "a launch request was recorded" and
/// never implies the guest is online or logged in.
public enum ProfileState: String, Codable, Sendable, CaseIterable {
    /// Engine confirmed the profile exists and can be asked to launch.
    case ready
    /// A create/import/restore job holds resources for this profile.
    case preparing
    /// Launch request dispatched; no evidence the guest actually started.
    case launching
    /// A launch was recorded recently. Not "online", not "logged in".
    case recentlyLaunched
    /// Engine missing, bad signature, or source changed underneath us.
    case needsAttention
    /// Configuration outside the verified matrix. Data is preserved; actions
    /// that could corrupt state are blocked.
    case unsupported
}

public extension ProfileState {
    /// Whether the launcher may start a destructive or state-changing job.
    var allowsMutation: Bool {
        switch self {
        case .ready, .recentlyLaunched: return true
        case .preparing, .launching, .needsAttention, .unsupported: return false
        }
    }

    /// Whether the profile can be opened right now.
    var allowsLaunch: Bool {
        self == .ready || self == .recentlyLaunched
    }
}

/// Presentation color choices. Stored as a token, not an arbitrary hex, so the
/// UI can keep contrast/accessibility guarantees (plan §7.1: colored identity).
public enum ProfileColor: String, Codable, Sendable, CaseIterable {
    case blue, green, purple, orange, pink, teal, red, indigo

    public var displayName: String { rawValue.capitalized }
}

/// A clone managed by the launcher.
public struct Profile: Codable, Sendable, Equatable, Identifiable {
    public var id: RecordID
    public var appID: RecordID
    public var sourceVersionID: RecordID?
    /// User-chosen label. Never derived from account data (plan §7.1).
    public var name: String
    public var color: ProfileColor
    /// The engine that owns this profile's data. Immutable in practice.
    public var engineKind: EngineKind
    public var engineVersion: String?
    /// Opaque handle assigned by the engine. Unique per engine.
    public var engineHandle: String
    public var state: ProfileState
    public var isPinned: Bool
    public var createdAt: Date
    public var lastOpenedAt: Date?
    /// Monotonic counter bumped on every mutation. Used for optimistic
    /// concurrency and to reject stale adapter replies (plan §8, generation).
    public var generation: Int

    public init(
        id: RecordID = .generate(),
        appID: RecordID,
        sourceVersionID: RecordID? = nil,
        name: String,
        color: ProfileColor = .blue,
        engineKind: EngineKind,
        engineVersion: String? = nil,
        engineHandle: String,
        state: ProfileState = .preparing,
        isPinned: Bool = false,
        createdAt: Date = Date(),
        lastOpenedAt: Date? = nil,
        generation: Int = 1
    ) {
        self.id = id
        self.appID = appID
        self.sourceVersionID = sourceVersionID
        self.name = name
        self.color = color
        self.engineKind = engineKind
        self.engineVersion = engineVersion
        self.engineHandle = engineHandle
        self.state = state
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.generation = generation
    }

    /// A profile whose data belongs to an engine other than the one currently
    /// active must not be mutated through the wrong adapter.
    public func isOwned(by kind: EngineKind) -> Bool {
        engineKind == kind
    }
}

/// Marker written into the launcher's own database to prove a container is
/// managed by us. Anything without a marker is treated as the original app or
/// a foreign container and is protected (plan §9, §10.3).
public struct OwnershipMarker: Codable, Sendable, Equatable {
    public var profileID: RecordID
    public var appID: RecordID
    public var writtenAt: Date

    public init(profileID: RecordID, appID: RecordID, writtenAt: Date = Date()) {
        self.profileID = profileID
        self.appID = appID
        self.writtenAt = writtenAt
    }
}
