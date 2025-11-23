import Testing
@testable import PRReporterKit

@Suite("Sendable Conformance Tests")
struct SendableConformanceTests {
    @Test("Annotation is Sendable")
    func annotationIsSendable() async {
        let annotation = Annotation(
            path: "test.swift",
            line: 1,
            level: .warning,
            message: "test"
        )

        // Verify we can use it across task boundaries
        await Task {
            let _ = annotation.path
            let _ = annotation.message
        }.value
    }

    @Test("GitHubContext is Sendable")
    func contextIsSendable() async {
        let context = GitHubContext(
            token: "token",
            repository: "owner/repo",
            pullRequest: 1,
            commitSHA: "abc123"
        )

        await Task {
            let _ = context.owner
            let _ = context.repo
        }.value
    }

    @Test("ReportResult is Sendable")
    func resultIsSendable() async {
        let result = ReportResult(
            annotationsPosted: 5,
            annotationsUpdated: 2,
            annotationsDeleted: 1
        )

        await Task {
            let _ = result.annotationsPosted
        }.value
    }

    @Test("RetryPolicy is Sendable")
    func policyIsSendable() async {
        let policy = RetryPolicy.default

        await Task {
            let _ = policy.maxAttempts
        }.value
    }

    @Test("CommentMode is Sendable")
    func modeIsSendable() async {
        let mode = CommentMode.update

        await Task {
            let _ = mode
        }.value
    }

    @Test("OverflowStrategy is Sendable")
    func overflowStrategyIsSendable() async {
        let strategy = OverflowStrategy.truncate

        await Task {
            let _ = strategy
        }.value
    }

    @Test("OutOfRangeStrategy is Sendable")
    func outOfRangeStrategyIsSendable() async {
        let strategy = OutOfRangeStrategy.dismiss

        await Task {
            let _ = strategy
        }.value
    }

    @Test("Annotation.Level is Sendable")
    func levelIsSendable() async {
        let level = Annotation.Level.failure

        await Task {
            let _ = level.rawValue
        }.value
    }
}
