import Foundation

/// Errors surfaced by adapters. Each case maps to a user-facing message plus a
/// stable code for diagnostics. Adapters must never throw raw engine strings:
/// those can contain paths or account data (plan §14.1).
public enum EngineError: Error, Codable, Equatable, Sendable {
    /// Engine/runtime is not present or not answering.
    case engineUnavailable(reason: String)
    /// Environment not in the verified matrix.
    case unsupportedConfiguration(ConfigurationID?)
    /// Source (installed app or IPA) failed validation.
    case invalidSource(reason: String)
    /// Operation not proven on this build.
    case capabilityNotSupported(Capability)
    /// The adapter refused because an ownership check failed.
    case ownershipViolation(reason: String)
    /// Another job holds the resource.
    case resourceLocked(ownerOperation: String?)
    /// Stale generation / handle; caller must re-inspect before retrying.
    case staleHandle
    /// The request was rejected and no state was changed.
    case rejected(reason: String)
    /// Transport-level failure; outcome unknown, caller must reconcile.
    case transportFailure(isRetryable: Bool)

    /// Stable, low-cardinality code for logs. No free-form text.
    public var code: String {
        switch self {
        case .engineUnavailable: return "ENGINE_UNAVAILABLE"
        case .unsupportedConfiguration: return "UNSUPPORTED_CONFIGURATION"
        case .invalidSource: return "INVALID_SOURCE"
        case .capabilityNotSupported: return "CAPABILITY_NOT_SUPPORTED"
        case .ownershipViolation: return "OWNERSHIP_VIOLATION"
        case .resourceLocked: return "RESOURCE_LOCKED"
        case .staleHandle: return "STALE_HANDLE"
        case .rejected: return "REJECTED"
        case .transportFailure: return "TRANSPORT_FAILURE"
        }
    }

    /// Whether the caller may safely retry the *same* idempotency key.
    /// Only meaningful negative answers (nothing changed) may be retried
    /// blindly; unknown transport outcomes must be reconciled first.
    public var isSafeToRetryBlindly: Bool {
        switch self {
        case .resourceLocked, .rejected:
            return true
        case .transportFailure: return false
        default: return false
        }
    }
}

/// A configuration the project has explicitly exercised.
public struct ConfigurationID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let mockSimulator = ConfigurationID("mock/simulator")
    public static let unverified = ConfigurationID("unverified")
}

/// Engine-side profile handle. Opaque to the launcher beyond equality/transport.
public struct EngineHandle: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// What an adapter reports about a handle that already exists in the engine.
/// Used to reconcile launcher DB state against engine reality (plan §10.1).
public struct InspectedProfile: Codable, Sendable, Equatable {
    public var handle: EngineHandle
    /// Whether the handle currently exists in the engine.
    public var exists: Bool
    /// Ownership marker the launcher wrote, if it can be read back.
    public var marker: OwnershipMarker?
    /// Bytes on disk if the engine reports them.
    public var byteSize: Int64?
    /// Last modified time of the container's data, if available.
    public var lastModified: Date?

    public init(
        handle: EngineHandle,
        exists: Bool,
        marker: OwnershipMarker? = nil,
        byteSize: Int64? = nil,
        lastModified: Date? = nil
    ) {
        self.handle = handle
        self.exists = exists
        self.marker = marker
        self.byteSize = byteSize
        self.lastModified = lastModified
    }
}

/// A source the adapter says it can clone from.
public struct DiscoveredSource: Codable, Sendable, Equatable {
    public var sourceID: String
    public var bundleID: String
    public var displayName: String
    public var version: String?
    public var build: String?

    public init(sourceID: String, bundleID: String, displayName: String, version: String? = nil, build: String? = nil) {
        self.sourceID = sourceID
        self.bundleID = bundleID
        self.displayName = displayName
        self.version = version
        self.build = build
    }
}

/// Outcome of asking an engine to create a blank profile. Separate type so
/// adapters cannot claim success without an inspectable handle.
public struct CreatedProfile: Codable, Sendable, Equatable {
    public var handle: EngineHandle
    public var byteSize: Int64?

    public init(handle: EngineHandle, byteSize: Int64? = nil) {
        self.handle = handle
        self.byteSize = byteSize
    }
}

/// The engine contract from plan §8. Every method can fail with EngineError.
///
/// Implementations: JailbreakAdapter, IPAAdapter, and a MockAdapter used only
/// for UI development and contract tests — never as proof that Facebook runs.
public protocol CloneEngine: Sendable {
    var kind: EngineKind { get }
    var adapterVersion: String { get }

    func probeEnvironment() async throws -> EnvironmentReport
    func listSources() async throws -> [DiscoveredSource]
    func validateSource(_ sourceID: String) async throws -> Bool

    /// Must be idempotent for a given operationID: calling twice with the same
    /// operationID must not create a second container.
    func createBlankProfile(sourceID: String, operationID: String) async throws -> CreatedProfile

    func inspectProfile(_ handle: EngineHandle) async throws -> InspectedProfile

    /// Stops any running guest for this handle. Throwing `.capabilityNotSupported`
    /// means the caller must not proceed with a container switch.
    func quiesce(_ handle: EngineHandle) async throws

    func launch(_ handle: EngineHandle) async throws
    func resetProfile(_ handle: EngineHandle) async throws
    func deleteProfile(_ handle: EngineHandle) async throws
}

/// Storage-side abstraction for comparing what the DB believes with what the
/// engine reports. Implemented by LauncherStorage's repository.
public enum ReconciliationOutcome: String, Codable, Sendable {
    /// DB and engine agree.
    case consistent
    /// Engine has a container the DB does not know about.
    case orphanInEngine
    /// DB has a record whose container the engine no longer has.
    case missingInEngine
    /// Ownership marker is absent or belongs to another profile.
    case foreignContainer
    /// Could not determine; block mutation until resolved.
    case indeterminate
}
