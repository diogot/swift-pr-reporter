import Testing
@testable import PRReporterKit

@Suite("GitHubContext Tests")
struct GitHubContextTests {
    @Test("Initialize with explicit values")
    func initExplicit() {
        let context = GitHubContext(
            token: "test-token",
            repository: "owner/repo",
            pullRequest: 123,
            commitSHA: "abc123"
        )

        #expect(context.token == "test-token")
        #expect(context.repository == "owner/repo")
        #expect(context.owner == "owner")
        #expect(context.repo == "repo")
        #expect(context.pullRequest == 123)
        #expect(context.commitSHA == "abc123")
        #expect(context.runAttempt == 1)
        #expect(context.eventName == "workflow_dispatch")
        #expect(context.isFork == false)
    }

    @Test("Initialize with all parameters")
    func initFull() {
        let context = GitHubContext(
            token: "ghp_token123",
            repository: "myorg/myrepo",
            pullRequest: 456,
            commitSHA: "def456",
            headRef: "feature-branch",
            baseRef: "main",
            runID: 789,
            runAttempt: 2,
            eventName: "pull_request",
            isFork: true
        )

        #expect(context.owner == "myorg")
        #expect(context.repo == "myrepo")
        #expect(context.headRef == "feature-branch")
        #expect(context.baseRef == "main")
        #expect(context.runID == 789)
        #expect(context.runAttempt == 2)
        #expect(context.eventName == "pull_request")
        #expect(context.isFork == true)
        #expect(context.isForkPR == true)
    }

    @Test("API base URL is correct")
    func apiBaseURL() {
        #expect(GitHubContext.apiBaseURL.absoluteString == "https://api.github.com")
    }

    @Test("Validate write access throws for fork PR")
    func validateWriteAccessFork() {
        let context = GitHubContext(
            token: "token",
            repository: "owner/repo",
            pullRequest: 1,
            commitSHA: "abc",
            isFork: true
        )

        #expect(throws: ContextError.self) {
            try context.validateWriteAccess()
        }
    }

    @Test("Validate write access succeeds for non-fork PR")
    func validateWriteAccessNonFork() throws {
        let context = GitHubContext(
            token: "token",
            repository: "owner/repo",
            pullRequest: 1,
            commitSHA: "abc",
            isFork: false
        )

        try context.validateWriteAccess()
    }
}
