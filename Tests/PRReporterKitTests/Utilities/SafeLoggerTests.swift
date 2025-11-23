import Testing
@testable import PRReporterKit

@Suite("SafeLogger Tests")
struct SafeLoggerTests {
    @Test("Redacts provided token")
    func redactsProvidedToken() {
        let logger = SafeLogger(level: .debug, tokenToRedact: "secret-token-123")

        let result = logger.redact("Authorization: Bearer secret-token-123")
        #expect(result == "Authorization: Bearer [REDACTED]")
    }

    @Test("Redacts GitHub PAT pattern")
    func redactsGitHubPAT() {
        let logger = SafeLogger(level: .debug)

        let result = logger.redact("token: ghp_1234567890abcdefghijklmnopqrstuvwxyz")
        #expect(result == "token: [REDACTED]")
    }

    @Test("Redacts GitHub OAuth token pattern")
    func redactsOAuthToken() {
        let logger = SafeLogger(level: .debug)

        let result = logger.redact("gho_1234567890abcdefghijklmnopqrstuvwxyz")
        #expect(result == "[REDACTED]")
    }

    @Test("Does not redact regular text")
    func preservesRegularText() {
        let logger = SafeLogger(level: .debug)

        let text = "This is a normal log message"
        let result = logger.redact(text)
        #expect(result == text)
    }

    @Test("Log level comparison")
    func logLevelComparison() {
        #expect(LogLevel.debug < LogLevel.info)
        #expect(LogLevel.info < LogLevel.warning)
        #expect(LogLevel.warning < LogLevel.error)
    }
}
