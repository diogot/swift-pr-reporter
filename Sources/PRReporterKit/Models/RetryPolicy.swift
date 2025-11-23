import Foundation

/// Configuration for retry behavior on failed requests.
public struct RetryPolicy: Sendable {
    /// Maximum number of retry attempts.
    public let maxAttempts: Int

    /// Initial backoff duration before first retry.
    public let initialBackoff: Duration

    /// Maximum backoff duration between retries.
    public let maxBackoff: Duration

    /// Multiplier applied to backoff after each attempt.
    public let backoffMultiplier: Double

    /// HTTP status codes that should trigger a retry.
    public let retryableStatusCodes: Set<Int>

    /// Jitter factor (0.0-1.0) to randomize backoff and avoid thundering herd.
    public let jitter: Double

    /// Creates a new retry policy.
    /// - Parameters:
    ///   - maxAttempts: Maximum number of retry attempts (default: 3).
    ///   - initialBackoff: Initial backoff duration (default: 1 second).
    ///   - maxBackoff: Maximum backoff duration (default: 60 seconds).
    ///   - backoffMultiplier: Multiplier for exponential backoff (default: 2.0).
    ///   - retryableStatusCodes: Status codes that trigger retry (default: 429, 500, 502, 503, 504).
    ///   - jitter: Jitter factor for randomization (default: 0.2).
    public init(
        maxAttempts: Int = 3,
        initialBackoff: Duration = .seconds(1),
        maxBackoff: Duration = .seconds(60),
        backoffMultiplier: Double = 2.0,
        retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 504],
        jitter: Double = 0.2
    ) {
        self.maxAttempts = maxAttempts
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        self.backoffMultiplier = backoffMultiplier
        self.retryableStatusCodes = retryableStatusCodes
        self.jitter = jitter
    }

    /// Default retry policy with reasonable defaults for GitHub API.
    public static let `default` = RetryPolicy()

    /// Aggressive retry policy with more attempts and longer backoff.
    public static let aggressive = RetryPolicy(
        maxAttempts: 5,
        initialBackoff: .seconds(2)
    )

    /// No retry policy - fails immediately on first error. Useful for testing.
    public static let none = RetryPolicy(
        maxAttempts: 1,
        initialBackoff: .milliseconds(1)
    )

    /// Calculate backoff duration for a given attempt number.
    /// - Parameter attempt: The attempt number (0-based).
    /// - Returns: The duration to wait before the next attempt.
    public func backoff(forAttempt attempt: Int) -> Duration {
        let base = initialBackoff.components.seconds
        let multiplied = Double(base) * pow(backoffMultiplier, Double(attempt))
        let capped = min(multiplied, Double(maxBackoff.components.seconds))

        // Apply jitter
        let jitterRange = capped * jitter
        let jittered = capped + Double.random(in: -jitterRange...jitterRange)

        return .seconds(max(0, jittered))
    }
}
