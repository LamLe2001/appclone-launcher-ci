import Foundation
import AppCloneDomain

/// Severity for diagnostics. Nothing above `warning` may be shown as a normal
/// app state; errors carry a stable code.
public enum DiagnosticLevel: String, Codable, Sendable, CaseIterable {
    case debug, info, warning, error
}

/// A single redaction rule. Rules are applied before anything is written, so a
/// raw secret can never reach storage in the first place (plan §14.1).
public struct RedactionRule: Sendable {
    public let name: String
    public let pattern: String
    public let replacement: String

    public init(name: String, pattern: String, replacement: String) {
        self.name = name
        self.pattern = pattern
        self.replacement = replacement
    }
}

/// Ordered redactor. Default rules cover the categories the plan forbids in
/// logs: passwords, OTPs, tokens, cookies, auth headers, and URLs with query
/// strings that may carry account identifiers.
public struct Redactor: Sendable {
    public let rules: [RedactionRule]

    public init(rules: [RedactionRule] = Redactor.defaultRules) {
        self.rules = rules
    }

    public static let defaultRules: [RedactionRule] = [
        RedactionRule(name: "bearer", pattern: #"(?i)\bbearer\s+[A-Za-z0-9._\-+/=]+"#,
                      replacement: "Bearer [REDACTED]"),
        RedactionRule(name: "authorization-header",
                      pattern: #"(?i)(authorization|proxy-authorization)\s*:\s*[^\r\n]+"#,
                      replacement: "$1: [REDACTED]"),
        RedactionRule(name: "cookie-header", pattern: #"(?i)\b(cookie|set-cookie)\s*:\s*[^\r\n]+"#,
                      replacement: "$1: [REDACTED]"),
        RedactionRule(name: "password-field",
                      pattern: #"(?i)\b(password|passwd|pwd|otp|passcode)\b\s*[=:]\s*[^\s,&;]+"#,
                      replacement: "$1=[REDACTED]"),
        RedactionRule(name: "token-field",
                      pattern: #"(?i)\b(access_token|refresh_token|id_token|token|secret|api_key|apikey)\b\s*[=:]\s*[^\s,&;]+"#,
                      replacement: "$1=[REDACTED]"),
        RedactionRule(name: "url-query", pattern: #"(https?://[^\s?#]+)\?[^\s#]*"#,
                      replacement: "$1?[REDACTED_QUERY]"),
        RedactionRule(name: "email", pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,
                      replacement: "[REDACTED_EMAIL]"),
        RedactionRule(name: "jwt", pattern: #"eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"#,
                      replacement: "[REDACTED_JWT]"),
    ]

    public func redact(_ input: String) -> String {
        var output = input
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: []) else {
                continue
            }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(
                in: output, options: [], range: range, withTemplate: rule.replacement)
        }
        return output
    }
}

/// A structured diagnostic event. `detail` is always stored already redacted.
public struct DiagnosticEvent: Sendable, Equatable {
    public var occurredAt: Date
    public var component: String
    public var operationID: String?
    public var errorCode: String?
    public var detail: String

    public init(occurredAt: Date = Date(), component: String,
                operationID: String? = nil, errorCode: String? = nil, detail: String) {
        self.occurredAt = occurredAt
        self.component = component
        self.operationID = operationID
        self.errorCode = errorCode
        self.detail = detail
    }

    /// Builds an event, redacting `detail` in the initializer so callers cannot
    /// forget. This is the single entry point used by the app.
    public static func make(component: String, operationID: String? = nil,
                            errorCode: String? = nil, detail: String,
                            redactor: Redactor = Redactor()) -> DiagnosticEvent {
        DiagnosticEvent(
            component: component,
            operationID: operationID,
            errorCode: errorCode,
            detail: redactor.redact(detail)
        )
    }
}

/// Retention policy for diagnostic history (plan §14.1: 14 days OR 20 MB,
/// whichever hits first).
public struct DiagnosticRetentionPolicy: Sendable, Equatable {
    public var maxAge: TimeInterval
    public var maxBytes: Int64

    public init(maxAge: TimeInterval = 14 * 24 * 60 * 60, maxBytes: Int64 = 20 * 1024 * 1024) {
        self.maxAge = maxAge
        self.maxBytes = maxBytes
    }

    public static let `default` = DiagnosticRetentionPolicy()

    /// Given events (newest first) and their sizes, returns the IDs that survive.
    /// Kept pure so retention is unit-testable without touching disk.
    public func survivors(from events: [(id: Int64, date: Date, bytes: Int64)],
                          now: Date) -> [Int64] {
        var kept: [Int64] = []
        var totalBytes: Int64 = 0
        let cutoff = now.addingTimeInterval(-maxAge)
        for event in events {
            // Events are expected newest-first; once older than cutoff, stop.
            if event.date < cutoff { break }
            if totalBytes + event.bytes > maxBytes { break }
            totalBytes += event.bytes
            kept.append(event.id)
        }
        return kept
    }
}

/// The traps that indicate a secret survived redaction, and how to check for
/// them. Used by tests and by the export screen's preview before a bundle
/// leaves the device.
///
/// Design note: this checks for *unredacted secret material*, not for the mere
/// presence of header names. A correctly redacted line still reads
/// `Authorization: [REDACTED]`, which is safe and must not be flagged — flagging
/// it would make every legitimately redacted bundle fail the check.
public enum SupportBundlePolicy {
    /// Header/field names whose *values* must have been replaced.
    /// Requiring the literal "[REDACTED]" after them catches a value that slipped
    /// through while accepting the redacted form.
    public static let sensitiveHeaders: [String] = [
        "authorization:", "proxy-authorization:", "cookie:", "set-cookie:",
    ]

    /// Patterns that must not appear anywhere in an exported bundle.
    public static let forbiddenSecretPatterns: [String] = [
        "access_token=", "refresh_token=", "id_token=",
        "eyJ",           // JWT header prefix
        "password=", "passwd=", "otp=",
        "Bearer ",
    ]

    /// Returns a human-readable description of each violation found.
    /// An empty array is required before the bundle may leave the device.
    public static func violations(in text: String) -> [String] {
        var found: [String] = []
        let lowered = text.lowercased()

        // 1. Any raw secret-looking token.
        for pattern in forbiddenSecretPatterns where lowered.contains(pattern.lowercased()) {
            found.append("contains unredacted pattern: \(pattern)")
        }

        // 2. A sensitive header whose value was not replaced.
        for header in sensitiveHeaders {
            var searchRange = text.startIndex..<text.endIndex
            while let range = text.range(of: header, options: [.caseInsensitive], range: searchRange) {
                let valueStart = range.upperBound
                let lineEnd = text[valueStart...].firstIndex(of: "\n") ?? text.endIndex
                let value = text[valueStart..<lineEnd].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty && !value.contains("[REDACTED]") {
                    found.append("unredacted value after \(header)")
                }
                searchRange = valueStart..<text.endIndex
            }
        }
        return found
    }
}
