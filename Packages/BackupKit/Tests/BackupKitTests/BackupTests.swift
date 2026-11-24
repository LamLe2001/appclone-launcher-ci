import XCTest
import Crypto
@testable import BackupKit
import AppCloneDomain

final class PBKDF2KnownAnswerTests: XCTestCase {

    /// Known-answer tests against PBKDF2-HMAC-SHA256, computed independently
    /// with Python's `hashlib.pbkdf2_hmac`. If these fail, the KDF is wrong and
    /// every backup is at risk — this is deliberately a hard check, not a
    /// self-consistency round trip.
    private func hex(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
    }

    func testVectorRounds1() {
        let k = BackupCryptography.deriveKeyUnchecked(
            password: "password", salt: Data("salt".utf8), iterations: 1)
        XCTAssertEqual(hex(k), "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    }

    func testVectorRounds2() {
        let k = BackupCryptography.deriveKeyUnchecked(
            password: "password", salt: Data("salt".utf8), iterations: 2)
        XCTAssertEqual(hex(k), "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
    }

    func testVectorRounds4096() {
        let k = BackupCryptography.deriveKeyUnchecked(
            password: "password", salt: Data("salt".utf8), iterations: 4096)
        XCTAssertEqual(hex(k), "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
    }

    func testVectorEmptyPassword() {
        let k = BackupCryptography.deriveKeyUnchecked(
            password: "", salt: Data("salt".utf8), iterations: 1)
        XCTAssertEqual(hex(k), "f135c27993baf98773c5cdb40a5706ce6a345cde61b000a67858650cd6a324d7")
    }

    func testDefaultIterationCountIsRecorded() {
        // The identifier must name the parameters that produced the key, so an
        // archive's manifest is self-describing.
        XCTAssertEqual(BackupCryptography.kdfIdentifier, "pbkdf2-hmac-sha256/aes-gcm/v1")
        XCTAssertEqual(BackupCryptography.iterations, 210_000)
    }
}

final class BackupCryptographyTests: XCTestCase {

    func testRoundTripWithCorrectPassword() throws {
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let key = BackupCryptography.deriveKey(password: "correct horse", salt: salt)
        let plaintext = Data("clone container bytes".utf8)

        let (nonce, sealed) = try BackupCryptography.encrypt(plaintext, key: key)
        let recovered = try BackupCryptography.decrypt(nonce: nonce, sealed: sealed, key: key)
        XCTAssertEqual(recovered, plaintext)
    }

    func testWrongPasswordFailsAuthenticationNotChecksum() throws {
        // RT-04: "sai mật khẩu backup" must be a safe, explicit failure — and
        // distinguishable from a corrupt archive.
        let salt = Data(repeating: 7, count: 16)
        let good = BackupCryptography.deriveKey(password: "right", salt: salt)
        let wrong = BackupCryptography.deriveKey(password: "wrong", salt: salt)
        let (nonce, sealed) = try BackupCryptography.encrypt(Data("x".utf8), key: good)

        XCTAssertThrowsError(try BackupCryptography.decrypt(nonce: nonce, sealed: sealed, key: wrong)) { error in
            XCTAssertEqual(error as? BackupError, .authenticationFailed)
        }
    }

    func testTamperedCiphertextIsRejected() throws {
        // Authenticated encryption must catch a flipped bit.
        let salt = Data(repeating: 1, count: 16)
        let key = BackupCryptography.deriveKey(password: "pw", salt: salt)
        var (nonce, sealed) = try BackupCryptography.encrypt(Data("important".utf8), key: key)
        sealed[0] ^= 0xFF
        XCTAssertThrowsError(try BackupCryptography.decrypt(nonce: nonce, sealed: sealed, key: key))
        _ = nonce
    }

    func testNoncesDifferPerEncryption() throws {
        // Reusing a nonce with GCM is catastrophic; each call must get a fresh one.
        let salt = Data(repeating: 2, count: 16)
        let key = BackupCryptography.deriveKey(password: "pw", salt: salt)
        let (n1, _) = try BackupCryptography.encrypt(Data("a".utf8), key: key)
        let (n2, _) = try BackupCryptography.encrypt(Data("a".utf8), key: key)
        XCTAssertNotEqual(n1, n2)
    }

    func testKeyDerivationIsDeterministicAndPasswordSensitive() {
        let salt = Data(repeating: 3, count: 16)
        let k1 = BackupCryptography.deriveKey(password: "abc", salt: salt)
        let k2 = BackupCryptography.deriveKey(password: "abc", salt: salt)
        let k3 = BackupCryptography.deriveKey(password: "abd", salt: salt)
        XCTAssertEqual(k1.withUnsafeBytes { Data($0) }, k2.withUnsafeBytes { Data($0) })
        XCTAssertNotEqual(k1.withUnsafeBytes { Data($0) }, k3.withUnsafeBytes { Data($0) })
    }

    func testSaltChangesKey() {
        let k1 = BackupCryptography.deriveKey(password: "abc", salt: Data(repeating: 1, count: 16))
        let k2 = BackupCryptography.deriveKey(password: "abc", salt: Data(repeating: 2, count: 16))
        XCTAssertNotEqual(k1.withUnsafeBytes { Data($0) }, k2.withUnsafeBytes { Data($0) })
    }
}

final class RestoreValidatorTests: XCTestCase {

    private func manifest(schema: Int = BackupManifest.currentSchemaVersion,
                          bytes: Int64 = 100) -> BackupManifest {
        BackupManifest(
            schemaVersion: schema,
            profileID: RecordID("p"), appID: RecordID("a"),
            engineKind: .mock,
            includedScopes: [.containerFiles],
            payloadByteSize: bytes,
            payloadSHA256: "deadbeef",
            kdfIdentifier: BackupCryptography.kdfIdentifier)
    }

    func testPathTraversalRejected() throws {
        // RT-04: classic traversal and absolute paths must be refused.
        try RestoreValidator.validateRelativePaths(["Documents/ok.txt"])
        XCTAssertThrowsError(try RestoreValidator.validateRelativePaths(["../../etc/passwd"]))
        XCTAssertThrowsError(try RestoreValidator.validateRelativePaths(["/etc/passwd"]))
        XCTAssertThrowsError(try RestoreValidator.validateRelativePaths(["..\\..\\Windows\\System32"]))
        XCTAssertThrowsError(try RestoreValidator.validateRelativePaths(["C:/Windows/System32"]))
    }

    func testNestedTraversalRejected() throws {
        XCTAssertThrowsError(try RestoreValidator.validateRelativePaths(["Library/../../escape.db"]))
    }

    func testResolvedPathStaysWithinDestination() {
        let dest = URL(fileURLWithPath: "/tmp/staging")
        XCTAssertNotNil(RestoreValidator.resolvedPath("Documents/a.txt", within: dest))
        XCTAssertNil(RestoreValidator.resolvedPath("../../etc/passwd", within: dest))
    }

    func testArchiveBombRejected() throws {
        XCTAssertThrowsError(try RestoreValidator.validateDeclaredSize(manifest(bytes: 10_000), limit: 1_000)) { error in
            XCTAssertNotNil(error as? BackupError)
        }
        XCTAssertNoThrow(try RestoreValidator.validateDeclaredSize(manifest(bytes: 10), limit: 1_000))
    }

    func testNewerSchemaIsHardStop() throws {
        XCTAssertThrowsError(try RestoreValidator.validateSchema(manifest(schema: 99))) { error in
            XCTAssertEqual(error as? BackupError,
                           .unsupportedSchemaVersion(found: 99, supported: BackupManifest.currentSchemaVersion))
        }
    }

    func testScopeDescriptionDoesNotPromiseSession() {
        // The UI must never imply login survives unless proven.
        let m = manifest()
        let lines = BackupScopeReporter.describe(m)
        XCTAssertTrue(lines.contains { $0.contains("cannot be verified") || $0.contains("not included") })
    }
}
