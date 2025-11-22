#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

/// Context from GitHub Actions environment.
public struct GitHubContext: Sendable {
    /// GitHub API token for authentication.
    public let token: String

    /// Repository in `owner/repo` format.
    public let repository: String

    /// Repository owner (derived from repository).
    public let owner: String

    /// Repository name (derived from repository).
    public let repo: String

    /// Pull request number (if applicable).
    public let pullRequest: Int?

    /// Commit SHA to annotate.
    public let commitSHA: String

    /// Source branch for PRs/forks (GITHUB_HEAD_REF).
    public let headRef: String?

    /// Target branch for PRs (GITHUB_BASE_REF).
    public let baseRef: String?

    /// Workflow run ID (GITHUB_RUN_ID).
    public let runID: Int?

    /// Workflow run attempt number for idempotency (GITHUB_RUN_ATTEMPT).
    public let runAttempt: Int

    /// Event name that triggered the workflow (GITHUB_EVENT_NAME).
    public let eventName: String

    /// Whether this is a PR from a fork (likely read-only token).
    public let isFork: Bool

    /// API base URL (github.com only for v1.0; Enterprise support planned for future).
    public static let apiBaseURL = URL(string: "https://api.github.com")!

    /// Initialize from GitHub Actions environment variables.
    /// - Throws: `ContextError.missingVariable` for required vars.
    /// - Throws: `ContextError.invalidEventPayload` if GITHUB_EVENT_PATH unreadable.
    public static func fromEnvironment() throws -> GitHubContext {
        try EnvironmentParser.parseFromEnvironment()
    }

    /// Initialize with explicit values (for testing or non-Actions environments).
    /// - Parameters:
    ///   - token: GitHub API token.
    ///   - repository: Repository in `owner/repo` format.
    ///   - pullRequest: Pull request number (if applicable).
    ///   - commitSHA: Commit SHA to annotate.
    ///   - headRef: Source branch for PRs/forks.
    ///   - baseRef: Target branch for PRs.
    ///   - runID: Workflow run ID.
    ///   - runAttempt: Workflow run attempt number.
    ///   - eventName: Event name that triggered the workflow.
    ///   - isFork: Whether this is a PR from a fork.
    public init(
        token: String,
        repository: String,
        pullRequest: Int?,
        commitSHA: String,
        headRef: String? = nil,
        baseRef: String? = nil,
        runID: Int? = nil,
        runAttempt: Int = 1,
        eventName: String = "workflow_dispatch",
        isFork: Bool = false
    ) {
        self.token = token
        self.repository = repository
        self.pullRequest = pullRequest
        self.commitSHA = commitSHA
        self.headRef = headRef
        self.baseRef = baseRef
        self.runID = runID
        self.runAttempt = runAttempt
        self.eventName = eventName
        self.isFork = isFork

        let components = repository.split(separator: "/")
        self.owner = String(components.first ?? "")
        self.repo = String(components.dropFirst().first ?? "")
    }

    /// Returns true if this is a PR from a fork (likely read-only token).
    public var isForkPR: Bool {
        isFork
    }

    /// Validates that write operations can be performed.
    /// - Throws: `ContextError.readOnlyToken` if this is a fork PR.
    public func validateWriteAccess() throws {
        if isForkPR {
            throw ContextError.readOnlyToken(
                "Cannot write to PR from fork. Token has read-only access."
            )
        }
    }
}
