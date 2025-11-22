#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

/// Log level for SafeLogger.
public enum LogLevel: Int, Sendable, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A logger that automatically redacts sensitive information like tokens.
public struct SafeLogger: Sendable {
    /// The minimum log level to output.
    public let level: LogLevel

    /// Optional token to redact from logs.
    private let tokenToRedact: String?

    /// Creates a new safe logger.
    /// - Parameters:
    ///   - level: Minimum log level to output.
    ///   - tokenToRedact: Token string to automatically redact.
    public init(level: LogLevel = .info, tokenToRedact: String? = nil) {
        self.level = level
        self.tokenToRedact = tokenToRedact
    }

    /// Log a debug message.
    public func debug(_ message: @autoclosure () -> String) {
        log(.debug, message())
    }

    /// Log an info message.
    public func info(_ message: @autoclosure () -> String) {
        log(.info, message())
    }

    /// Log a warning message.
    public func warning(_ message: @autoclosure () -> String) {
        log(.warning, message())
    }

    /// Log an error message.
    public func error(_ message: @autoclosure () -> String) {
        log(.error, message())
    }

    /// Log a request (redacting sensitive headers).
    public func logRequest(_ request: URLRequest) {
        guard level <= .debug else { return }

        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "unknown"
        debug("\(method) \(redact(url))")
    }

    /// Log a response with timing information.
    public func logResponse(_ response: HTTPURLResponse, duration: Duration) {
        guard level <= .debug else { return }

        let status = response.statusCode
        let seconds = duration.components.seconds
        let attoseconds = duration.components.attoseconds
        let msFromSeconds = Int(seconds * 1000)
        let msFromAttoseconds = Int(Double(attoseconds) / 1_000_000_000_000_000)
        let ms = msFromSeconds + msFromAttoseconds

        // Extract rate limit info if available
        var rateLimitInfo = ""
        if let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
           let limit = response.value(forHTTPHeaderField: "X-RateLimit-Limit") {
            rateLimitInfo = " RateLimit: \(remaining)/\(limit)"
        }

        debug("\(status) (\(ms)ms)\(rateLimitInfo)")
    }

    /// Redact sensitive information from a string.
    public func redact(_ string: String) -> String {
        var result = string

        // Redact the token if provided
        if let token = tokenToRedact, !token.isEmpty {
            result = result.replacingOccurrences(of: token, with: "[REDACTED]")
        }

        // Redact common token patterns
        let patterns = [
            "ghp_[a-zA-Z0-9]{36}",  // GitHub personal access token
            "gho_[a-zA-Z0-9]{36}",  // GitHub OAuth token
            "ghu_[a-zA-Z0-9]{36}",  // GitHub user-to-server token
            "ghs_[a-zA-Z0-9]{36}",  // GitHub server-to-server token
            "github_pat_[a-zA-Z0-9]{22}_[a-zA-Z0-9]{59}",  // Fine-grained PAT
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "[REDACTED]")
            }
        }

        return result
    }

    private func log(_ messageLevel: LogLevel, _ message: String) {
        guard messageLevel >= level else { return }

        let prefix: String
        switch messageLevel {
        case .debug:
            prefix = "[DEBUG]"
        case .info:
            prefix = "[INFO]"
        case .warning:
            prefix = "[WARNING]"
        case .error:
            prefix = "[ERROR]"
        }

        let redactedMessage = redact(message)
        print("\(prefix) \(redactedMessage)")
    }
}
