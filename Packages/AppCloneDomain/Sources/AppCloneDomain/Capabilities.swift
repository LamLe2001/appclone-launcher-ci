import Foundation

/// Engine that owns a clone profile. A profile is always bound to exactly one
/// engine; moving a profile between engines is a migration job, never a
/// property flip (plan §6.3).
public enum EngineKind: String, Codable, Sendable, CaseIterable {
    /// Jailbreak branch: clones containers of an already-installed app.
    case jailbreak
    /// Non-jailbreak branch: loads a user-supplied IPA inside a host runtime.
    case ipa
    /// UI development only. Never a source of truth for shipping features.
    case mock
}

/// Where a clone's source application comes from.
public enum SourceType: String, Codable, Sendable, CaseIterable {
    /// App already installed on the device, validated by an adapter.
    case installedApp
    /// IPA imported by the user through the Files picker.
    case importedIPA
}

/// Whether an operation is proven to work on a given configuration.
///
/// `unknown` must be treated as "not usable yet" by the UI; it is the honest
/// answer when the device/engine was never exercised under test (plan §7.4).
public enum CapabilityStatus: String, Codable, Sendable, CaseIterable {
    case supported
    case unsupported
    case unknown
}

/// The capability surface described in plan §8. Each case is a launcher-side
/// contract, not a claim that libCrane/LiveContainer exposes it today.
public enum Capability: String, Codable, Sendable, CaseIterable {
    case probeEnvironment
    case listSources
    case validateSource
    case createBlankProfile
    case listProfiles
    case inspectProfile
    case prepareLaunch
    case launch
    case quiesce
    case exportData
    case importData
    case resetProfile
    case deleteProfile

    /// Capabilities that can destroy or hide data. Never default-enable these.
    public var isDestructive: Bool {
        switch self {
        case .resetProfile, .deleteProfile: return true
        default: return false
        }
    }
}

/// A single capability observation for one configuration. Snapshots are only
/// valid for the exact configuration/build they were recorded against
/// (plan §9, `capability_snapshots`).
public struct CapabilityRecord: Codable, Sendable, Equatable {
    public var capability: Capability
    public var status: CapabilityStatus
    /// Short, non-sensitive explanation shown in the UI.
    public var reason: String?
    /// Reference to a test-evidence artifact, if any.
    public var evidence: String?
    public var recordedAt: Date

    public init(
        capability: Capability,
        status: CapabilityStatus,
        reason: String? = nil,
        evidence: String? = nil,
        recordedAt: Date = Date()
    ) {
        self.capability = capability
        self.status = status
        self.reason = reason
        self.evidence = evidence
        self.recordedAt = recordedAt
    }
}

/// Immutable description of the environment a capability snapshot applies to.
/// Changing any of these fields invalidates prior snapshots (plan §7.4/§16).
public struct EnvironmentFingerprint: Codable, Sendable, Equatable {
    public var engineKind: EngineKind
    public var engineVersion: String?
    public var adapterVersion: String
    public var osVersion: String
    /// e.g. "rootless", "rootful", "n/a"
    public var jailbreakFlavor: String?
    /// Fingerprint of toolchain/signing config; never raw secrets.
    public var configFingerprint: String?

    public init(
        engineKind: EngineKind,
        engineVersion: String? = nil,
        adapterVersion: String,
        osVersion: String,
        jailbreakFlavor: String? = nil,
        configFingerprint: String? = nil
    ) {
        self.engineKind = engineKind
        self.engineVersion = engineVersion
        self.adapterVersion = adapterVersion
        self.osVersion = osVersion
        self.jailbreakFlavor = jailbreakFlavor
        self.configFingerprint = configFingerprint
    }
}

/// Result of probing the environment. Drives whether the launcher may mutate
/// anything at all (plan §7.4 "Cần xử lý" / "Không hỗ trợ").
public struct EnvironmentReport: Codable, Sendable, Equatable {
    public var fingerprint: EnvironmentFingerprint
    public var capabilities: [CapabilityRecord]
    public var probedAt: Date
    /// User-facing summary; technical detail stays in diagnostics.
    public var summary: String

    public init(
        fingerprint: EnvironmentFingerprint,
        capabilities: [CapabilityRecord],
        probedAt: Date = Date(),
        summary: String
    ) {
        self.fingerprint = fingerprint
        self.capabilities = capabilities
        self.probedAt = probedAt
        self.summary = summary
    }

    public func status(for capability: Capability) -> CapabilityStatus {
        capabilities.first { $0.capability == capability }?.status ?? .unknown
    }

    /// True only when the capability is explicitly supported.
    public func canUse(_ capability: Capability) -> Bool {
        status(for: capability) == .supported
    }

    /// Mutations require a healthy environment. Anything not proven supported
    /// blocks destructive work rather than being optimistically allowed.
    public var mayMutate: Bool {
        canUse(.probeEnvironment)
            && (canUse(.createBlankProfile) || canUse(.importData))
    }
}
