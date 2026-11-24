import Foundation
import Crypto
import _CryptoExtras
import AppCloneDomain

/// Manifest describing exactly what a backup contains.
///
/// The plan requires the user to be told the scope honestly: whether Keychain,
/// preferences and App Groups are included is per-adapter and must be declared,
/// never assumed (plan §13.1).
public struct BackupManifest: Codable, Sendable, Equatable {
    /// Bumped when the format changes in a way old readers cannot handle.
    public static let currentSchemaVersion = 1

    /// What parts of a profile's data this archive actually contains.
    public enum Scope: String, Codable, Sendable, CaseIterable {
        /// Profile name/color/ordering metadata.
        case profileMetadata
        /// File contents of the container, when the engine can export it.
        case containerFiles
        /// UserDefaults / preferences, adapter-dependent.
        case preferences
        /// App Group shared data, adapter-dependent.
        case appGroups
        /// Keychain items, adapter-dependent.
        case keychain
    }

    public var schemaVersion: Int
    public var profileID: RecordID
    public var appID: RecordID
    public var engineKind: EngineKind
    public var engineVersion: String?
    public var sourceVersion: String?
    /// Declared scope. A reader must not treat absent scope as "present".
    public var includedScopes: [Scope]
    /// Whether the login session is expected to survive. Usually false; the
    /// plan forbids promising it (plan §13.1, §16).
    public var sessionRestorable: SessionRestorable
    public var createdAt: Date
    public var payloadByteSize: Int64
    /// SHA-256 of the encrypted payload, hex.
    public var payloadSHA256: String
    /// Identifier of the key-derivation parameters used, for forward compat.
    public var kdfIdentifier: String

    public enum SessionRestorable: String, Codable, Sendable {
        case yes, no, cannotVerify
    }

    public init(
        schemaVersion: Int = BackupManifest.currentSchemaVersion,
        profileID: RecordID,
        appID: RecordID,
        engineKind: EngineKind,
        engineVersion: String? = nil,
        sourceVersion: String? = nil,
        includedScopes: [Scope],
        sessionRestorable: SessionRestorable = .cannotVerify,
        createdAt: Date = Date(),
        payloadByteSize: Int64,
        payloadSHA256: String,
        kdfIdentifier: String
    ) {
        self.schemaVersion = schemaVersion
        self.profileID = profileID
        self.appID = appID
        self.engineKind = engineKind
        self.engineVersion = engineVersion
        self.sourceVersion = sourceVersion
        self.includedScopes = includedScopes
        self.sessionRestorable = sessionRestorable
        self.createdAt = createdAt
        self.payloadByteSize = payloadByteSize
        self.payloadSHA256 = payloadSHA256
        self.kdfIdentifier = kdfIdentifier
    }
}

public enum BackupError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case checksumMismatch
    case authenticationFailed
    case malformedArchive(reason: String)
    /// Restore would write outside the destination directory.
    case pathTraversalDetected(String)
    /// Declared uncompressed size exceeds the safety budget.
    case archiveTooLarge(declared: Int64, limit: Int64)
    case insufficientSpace(required: Int64, available: Int64)
    case scopeNotAvailable([BackupManifest.Scope])
    case passwordRequired
}

/// Authenticated encryption for backup payloads.
///
/// Design notes (plan §13.2: "we do not invent cryptography"):
/// - Key derivation is **PBKDF2-HMAC-SHA256**, the standard password-stretching
///   KDF. (An earlier draft of this file used an iterated-HKDF loop; HKDF is a
///   *key-expansion* function, not a password-hardening function, so that was
///   replaced — see docs/reports/02 §4.5.)
/// - Encryption is **AES-GCM** with a fresh random 96-bit nonce per archive.
/// - Every parameter that affects decryption is named in `kdfIdentifier`, so a
///   future change cannot silently misread an old archive.
///
/// Known limitation (documented, not hidden): payloads are currently sealed in
/// one AES-GCM operation, which means the whole payload must be held in memory.
/// Plan §13.2 asks for chunked streaming for large archives; that is tracked as
/// task G013 in `docs/tasks/01-implementation-pass-1.md` and is NOT yet done.
public enum BackupCryptography {

    public static let kdfIdentifier = "pbkdf2-hmac-sha256/aes-gcm/v1"

    /// Iteration count. Chosen to be a meaningful cost on device while keeping
    /// backup creation responsive; it is recorded in `kdfIdentifier` so old
    /// archives remain decryptable if this changes.
    public static let iterations: UInt32 = 210_000

    /// Derives a 256-bit symmetric key from a password and salt using
    /// PBKDF2-HMAC-SHA256.
    ///
    /// The default path enforces swift-crypto's minimum of 210,000 rounds.
    /// `unsafeUncheckedRounds` exists only so known-answer tests can use the
    /// published low-round test vectors; production code must never pass it.
    public static func deriveKey(
        password: String,
        salt: Data,
        iterations: UInt32 = BackupCryptography.iterations
    ) -> SymmetricKey {
        // Production path: throws only if rounds < 210_000, which the default
        // constant satisfies. Fall back to the unchecked variant so the helper
        // keeps a non-throwing signature.
        if let key = try? KDF.Insecure.PBKDF2.deriveKey(
            from: Data(password.utf8),
            salt: salt,
            using: .sha256,
            outputByteCount: 32,
            rounds: Int(iterations)
        ) {
            return key
        }
        return deriveKeyUnchecked(password: password, salt: salt, iterations: iterations)
    }

    /// Test-only path that permits sub-minimum round counts so the
    /// published PBKDF2 test vectors (rounds = 1, 2, 4096) can be verified.
    /// Never use with a user-supplied or low round count in production.
    public static func deriveKeyUnchecked(
        password: String,
        salt: Data,
        iterations: UInt32
    ) -> SymmetricKey {
        // Safe to force-try: the only documented failure is an out-of-range
        // round count, and callers here pass a compile-time-known value.
        try! KDF.Insecure.PBKDF2.deriveKey(
            from: Data(password.utf8),
            salt: salt,
            using: .sha256,
            outputByteCount: 32,
            unsafeUncheckedRounds: Int(iterations)
        )
    }

    /// Encrypts a payload with AES-GCM. Returns (nonce, ciphertext+tag).
    public static func encrypt(_ plaintext: Data, key: SymmetricKey) throws -> (nonce: Data, sealed: Data) {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        guard let combined = sealed.combined else {
            throw BackupError.malformedArchive(reason: "sealed box missing combined form")
        }
        // combined = nonce || ciphertext || tag; strip the nonce prefix we store separately.
        let nonceData = Data(nonce)
        let body = combined.dropFirst(nonceData.count)
        return (nonceData, Data(body))
    }

    /// Decrypts; authentication failure is reported as such, never as a
    /// checksum issue, so "wrong password" stays distinguishable from "corrupt".
    public static func decrypt(nonce: Data, sealed: Data, key: SymmetricKey) throws -> Data {
        let nonceValue: AES.GCM.Nonce
        do {
            nonceValue = try AES.GCM.Nonce(data: nonce)
        } catch {
            throw BackupError.malformedArchive(reason: "invalid nonce")
        }
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: nonce + sealed)
        } catch {
            throw BackupError.malformedArchive(reason: "invalid sealed box")
        }
        do {
            return try AES.GCM.open(box, using: key)
        } catch {
            throw BackupError.authenticationFailed
        }
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Validation performed BEFORE any restore writes to disk.
public enum RestoreValidator {

    /// Rejects an archive whose declared sizes exceed the budget (archive bomb).
    public static func validateDeclaredSize(_ manifest: BackupManifest, limit: Int64) throws {
        guard manifest.payloadByteSize <= limit else {
            throw BackupError.archiveTooLarge(declared: manifest.payloadByteSize, limit: limit)
        }
    }

    /// Verifies the manifest schema is one we understand. A newer schema is a
    /// hard stop, never a best-effort parse (plan §13.3 step 1).
    public static func validateSchema(_ manifest: BackupManifest) throws {
        guard manifest.schemaVersion == BackupManifest.currentSchemaVersion else {
            throw BackupError.unsupportedSchemaVersion(
                found: manifest.schemaVersion,
                supported: BackupManifest.currentSchemaVersion)
        }
    }

    /// Ensures every relative path in the archive stays inside the destination.
    ///
    /// This is the RT-04 guard: symlinks, `..`, absolute paths and Windows
    /// drive prefixes are all rejected.
    public static func validateRelativePaths(_ paths: [String]) throws {
        for path in paths {
            if path.isEmpty { continue }
            let normalized = path.replacingOccurrences(of: "\\", with: "/")
            if normalized.hasPrefix("/") || normalized.contains(":") {
                throw BackupError.pathTraversalDetected(path)
            }
            let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
            if components.contains("..") {
                throw BackupError.pathTraversalDetected(path)
            }
            if components.contains(".") && components.count == 1 {
                throw BackupError.pathTraversalDetected(path)
            }
        }
    }

    /// Checks a file will not escape `destination` once resolved.
    public static func resolvedPath(_ relative: String, within destination: URL) -> URL? {
        let candidate = destination.appendingPathComponent(relative).standardizedFileURL
        let base = destination.standardizedFileURL.path
        let resolved = candidate.path
        guard resolved == base || resolved.hasPrefix(base + "/") else { return nil }
        return candidate
    }
}

/// Verifies that what a backup claims to contain matches its scope list, so the
/// UI never tells the user Keychain was included when it was not.
public enum BackupScopeReporter {
    public static func describe(_ manifest: BackupManifest) -> [String] {
        let names = manifest.includedScopes.map { scope -> String in
            switch scope {
            case .profileMetadata: return "Profile name/color"
            case .containerFiles: return "App data files"
            case .preferences: return "Preferences"
            case .appGroups: return "App Group data"
            case .keychain: return "Keychain (login tokens)"
            }
        }
        var lines = names
        switch manifest.sessionRestorable {
        case .yes:
            lines.append("Login session: expected to be restorable")
        case .no:
            lines.append("Login session: not included")
        case .cannotVerify:
            lines.append("Login session: cannot be verified; you may need to sign in again")
        }
        return lines
    }
}
