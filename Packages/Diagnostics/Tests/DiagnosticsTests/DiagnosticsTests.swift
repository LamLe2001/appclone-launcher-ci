import XCTest
@testable import Diagnostics

final class RedactorTests: XCTestCase {

    func testBearerTokenRemoved() {
        let out = Redactor().redact("GET /me\nAuthorization: Bearer abc123def456")
        XCTAssertFalse(out.contains("abc123def456"))
        XCTAssertTrue(out.contains("[REDACTED]"))
    }

    func testAccessTokenFieldRemoved() {
        let out = Redactor().redact("access_token=EAAXYZ123&expires=5")
        XCTAssertFalse(out.contains("EAAXYZ123"))
    }

    func testPasswordFieldRemoved() {
        let out = Redactor().redact("password=hunter2 login attempt")
        XCTAssertFalse(out.contains("hunter2"))
    }

    func testJWTRemoved() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcdefghij"
        let out = Redactor().redact("token \(jwt) used")
        XCTAssertFalse(out.contains("eyJhbGciOiJIUzI1NiJ9"))
    }

    func testEmailRemoved() {
        let out = Redactor().redact("user john.doe@example.com failed")
        XCTAssertFalse(out.contains("john.doe@example.com"))
        XCTAssertTrue(out.contains("[REDACTED_EMAIL]"))
    }

    func testURLQueryRemoved() {
        let out = Redactor().redact("GET https://graph.facebook.com/v1/me?access_token=SECRET&id=42")
        XCTAssertFalse(out.contains("SECRET"))
        XCTAssertTrue(out.contains("https://graph.facebook.com/v1/me"))
    }

    func testCookieRemoved() {
        let out = Redactor().redact("Cookie: c_user=1000; xs=abcdef")
        XCTAssertFalse(out.contains("xs=abcdef"))
    }

    func testHarmlessTextUnchanged() {
        let clean = "profile 5f3a created at stage engineHandleReturned"
        XCTAssertEqual(Redactor().redact(clean), clean)
    }

    func testRedactionIsIdempotent() {
        let r = Redactor()
        let once = r.redact("Authorization: Bearer xyz.abc")
        XCTAssertEqual(r.redact(once), once)
    }
}

final class DiagnosticEventTests: XCTestCase {

    func testMakeRedactsBeforeStorage() {
        // The single entry point must not let a raw secret be stored.
        let event = DiagnosticEvent.make(
            component: "adapter",
            operationID: "op-1",
            errorCode: "AUTH",
            detail: "failed with access_token=SUPERSECRET"
        )
        XCTAssertFalse(event.detail.contains("SUPERSECRET"))
    }

    func testSupportBundlePolicyDetectsLeaks() {
        let leaky = "GET /x\nAuthorization: Bearer abc"
        XCTAssertFalse(SupportBundlePolicy.violations(in: leaky).isEmpty)

        let clean = Redactor().redact(leaky)
        XCTAssertTrue(SupportBundlePolicy.violations(in: clean).isEmpty)
    }
}

final class RetentionTests: XCTestCase {

    func testOldEventsDropped() {
        let policy = DiagnosticRetentionPolicy(maxAge: 100, maxBytes: .max)
        let now = Date(timeIntervalSince1970: 10_000)
        let events: [(id: Int64, date: Date, bytes: Int64)] = [
            (1, now.addingTimeInterval(-10), 10),
            (2, now.addingTimeInterval(-50), 10),
            (3, now.addingTimeInterval(-150), 10),  // too old
        ]
        XCTAssertEqual(policy.survivors(from: events, now: now), [1, 2])
    }

    func testByteCapRespected() {
        let policy = DiagnosticRetentionPolicy(maxAge: .infinity, maxBytes: 25)
        let now = Date(timeIntervalSince1970: 10_000)
        let events: [(id: Int64, date: Date, bytes: Int64)] = [
            (1, now, 10),
            (2, now, 10),
            (3, now, 10),  // would exceed 25
        ]
        XCTAssertEqual(policy.survivors(from: events, now: now), [1, 2])
    }

    func testDefaultPolicyMatchesPlanNumbers() {
        // Plan §14.1: 14 days or 20 MB.
        XCTAssertEqual(DiagnosticRetentionPolicy.default.maxAge, 14 * 24 * 60 * 60)
        XCTAssertEqual(DiagnosticRetentionPolicy.default.maxBytes, 20 * 1024 * 1024)
    }
}
