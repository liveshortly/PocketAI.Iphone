import Foundation
import PocketKit

/// In-memory ring buffer for app lifecycle and status lines (capacity 50).
/// Thread-safe and strictly non-content: never pass prompts, messages,
/// file contents, API keys, or license keys here.
public final class DiagnosticsLog: @unchecked Sendable {
    public static let shared = DiagnosticsLog()

    private let lock = NSLock()
    private var buffer: [String] = []
    private let capacity: Int = 50

    public init(seedLines: [String]? = nil) {
        if let seedLines {
            for line in seedLines {
                append(line)
            }
        } else {
            // Seed with non-content lifecycle status strings so payload is non-empty
            append("App lifecycle: process started")
            append("Diagnostics: ring buffer initialized")
            append("Core: local runtime ready")
            append("Server: local inference server active")
        }
    }

    public func append(_ line: String) {
        let redacted = DiagnosticsReport.redact(line)
        lock.lock()
        defer { lock.unlock() }
        buffer.append(redacted)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
    }

    public func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll()
    }
}

/// QA-11: Redacted diagnostics JSON report for user review before sending.
public struct DiagnosticsReport: Codable, Equatable, Sendable {
    public let app_version: String
    public let build: String
    public let os: String
    public let device: DeviceInfo
    public let generated_at: String
    public let log_tail: [String]

    public struct DeviceInfo: Codable, Equatable, Sendable {
        public let chip: String
        public let model: String
        public let totalRam: UInt64
        public let freeDisk: UInt64

        public init(chip: String, model: String, totalRam: UInt64, freeDisk: UInt64) {
            self.chip = chip
            self.model = model
            self.totalRam = totalRam
            self.freeDisk = freeDisk
        }
    }

    public init(
        app_version: String,
        build: String,
        os: String,
        device: DeviceInfo,
        generated_at: String,
        log_tail: [String]
    ) {
        self.app_version = app_version
        self.build = build
        self.os = os
        self.device = device
        self.generated_at = generated_at
        self.log_tail = log_tail
    }

    /// Builds a current diagnostics report using live device profile, bundle versions, and log tail.
    public static func current() -> DiagnosticsReport {
        generate()
    }

    public static func generate(
        profile: DeviceProfile? = nil,
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo,
        logTail: [String]? = nil,
        date: Date = Date()
    ) -> DiagnosticsReport {
        let deviceProfile = profile ?? LivePlatformHooks().deviceProfile()
        let appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let os = processInfo.operatingSystemVersionString

        let rawLogs = logTail ?? DiagnosticsLog.shared.snapshot()
        let redactedLogs = rawLogs.suffix(50).map { redact($0) }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let generatedAt = formatter.string(from: date)

        return DiagnosticsReport(
            app_version: appVersion,
            build: build,
            os: os,
            device: DeviceInfo(
                chip: deviceProfile.chip,
                model: deviceProfile.modelIdentifier,
                totalRam: deviceProfile.totalRamBytes,
                freeDisk: deviceProfile.freeDiskBytes
            ),
            generated_at: generatedAt,
            log_tail: Array(redactedLogs)
        )
    }

    /// Serializes to formatted JSON for preview and export.
    public func toPrettyJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    /// Strips anything that looks like an API key, token, or secret
    /// (e.g. sk-..., auth headers, license keys, long base64/hex runs) as a safety net.
    public static func redact(_ input: String) -> String {
        var text = input

        // 1. Auth/token headers or key-value pairs
        let authPattern = #"(?i)\b(bearer|token|api[_-]?key|secret|password|passwd)\s*[:=]\s*['"]?[A-Za-z0-9_\-\.\+\/=]{8,}['"]?"#
        if let regex = try? NSRegularExpression(pattern: authPattern) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1: [REDACTED]")
        }

        // 2. Prefixed API keys: sk-..., pk-..., key-...
        let prefixedKeyPattern = #"\b(?:sk|pk|key)-[A-Za-z0-9_\-]{16,}\b"#
        if let regex = try? NSRegularExpression(pattern: prefixedKeyPattern) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "[REDACTED]")
        }

        // 3. License key hyphenated format (e.g. groups of 4-8 alphanumerics, 3+ hyphens)
        let licensePattern = #"\b(?:[A-Za-z0-9]{4,8}-){3,}[A-Za-z0-9]{4,8}\b"#
        if let regex = try? NSRegularExpression(pattern: licensePattern) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "[REDACTED]")
        }

        // 4. Long hex strings (>= 24 hex chars)
        let hexPattern = #"\b[0-9a-fA-F]{24,}\b"#
        if let regex = try? NSRegularExpression(pattern: hexPattern) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "[REDACTED]")
        }

        // 5. Long base64 / token strings (>= 32 chars of base64/urlsafe characters)
        let base64Pattern = #"\b[A-Za-z0-9+/=_-]{32,}\b"#
        if let regex = try? NSRegularExpression(pattern: base64Pattern) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "[REDACTED]")
        }

        return text
    }
}
