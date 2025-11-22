#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

/// API client for GitHub Pull Request operations.
public actor PullRequestsAPI {
    private let api: GitHubAPI
    private let owner: String
    private let repo: String

    /// Creates a new Pull Requests API client.
    /// - Parameters:
    ///   - api: The underlying GitHub API client.
    ///   - owner: Repository owner.
    ///   - repo: Repository name.
    public init(api: GitHubAPI, owner: String, repo: String) {
        self.api = api
        self.owner = owner
        self.repo = repo
    }

    // MARK: - PR Files (for diff information)

    /// List files changed in a pull request.
    /// - Parameter prNumber: The pull request number.
    /// - Returns: Array of changed files with patch information.
    public func listFiles(prNumber: Int) async throws -> [PullRequestFile] {
        try await api.getAllPages("/repos/\(owner)/\(repo)/pulls/\(prNumber)/files")
    }

    // MARK: - Review Comments

    /// List review comments on a pull request.
    /// - Parameter prNumber: The pull request number.
    /// - Returns: Array of review comments.
    public func listReviewComments(prNumber: Int) async throws -> [ReviewComment] {
        try await api.getAllPages("/repos/\(owner)/\(repo)/pulls/\(prNumber)/comments")
    }

    /// Create a review comment on a specific line.
    /// - Parameters:
    ///   - prNumber: The pull request number.
    ///   - body: The comment body.
    ///   - commitID: The SHA of the commit to comment on.
    ///   - path: The file path.
    ///   - position: The position in the diff (not line number!).
    /// - Returns: The created comment.
    public func createReviewComment(
        prNumber: Int,
        body: String,
        commitID: String,
        path: String,
        position: Int
    ) async throws -> ReviewComment {
        let request = CreateReviewCommentRequest(
            body: body,
            commitId: commitID,
            path: path,
            position: position
        )
        return try await api.post("/repos/\(owner)/\(repo)/pulls/\(prNumber)/comments", body: request)
    }

    /// Create a review comment using line number (newer API).
    /// - Parameters:
    ///   - prNumber: The pull request number.
    ///   - body: The comment body.
    ///   - commitID: The SHA of the commit to comment on.
    ///   - path: The file path.
    ///   - line: The line number in the file.
    ///   - side: Which side of the diff (LEFT for deletion, RIGHT for addition/context).
    /// - Returns: The created comment.
    public func createReviewCommentOnLine(
        prNumber: Int,
        body: String,
        commitID: String,
        path: String,
        line: Int,
        side: DiffSide = .right
    ) async throws -> ReviewComment {
        let request = CreateReviewCommentLineRequest(
            body: body,
            commitId: commitID,
            path: path,
            line: line,
            side: side.rawValue
        )
        return try await api.post("/repos/\(owner)/\(repo)/pulls/\(prNumber)/comments", body: request)
    }

    /// Update an existing review comment.
    /// - Parameters:
    ///   - commentID: The comment ID.
    ///   - body: The new body.
    /// - Returns: The updated comment.
    public func updateReviewComment(commentID: Int, body: String) async throws -> ReviewComment {
        try await api.patch(
            "/repos/\(owner)/\(repo)/pulls/comments/\(commentID)",
            body: UpdateReviewCommentRequest(body: body)
        )
    }

    /// Delete a review comment.
    /// - Parameter commentID: The comment ID.
    public func deleteReviewComment(commentID: Int) async throws {
        try await api.delete("/repos/\(owner)/\(repo)/pulls/comments/\(commentID)")
    }

    /// Find review comments with a specific marker.
    /// - Parameters:
    ///   - prNumber: The pull request number.
    ///   - identifier: The marker identifier to search for.
    /// - Returns: Comments that contain the marker.
    public func findReviewComments(prNumber: Int, withIdentifier identifier: String) async throws -> [ReviewComment] {
        let comments = try await listReviewComments(prNumber: prNumber)
        return comments.filter { comment in
            CommentMarker.contains(identifier: identifier, in: comment.body)
        }
    }
}

// MARK: - Request/Response Models

/// A file changed in a pull request.
public struct PullRequestFile: Decodable, Sendable {
    public let sha: String
    public let filename: String
    public let status: String
    public let additions: Int
    public let deletions: Int
    public let changes: Int
    public let patch: String?
    public let previousFilename: String?
}

/// Side of the diff.
public enum DiffSide: String, Sendable {
    case left = "LEFT"
    case right = "RIGHT"
}

/// Request to create a review comment.
struct CreateReviewCommentRequest: Encodable, Sendable {
    let body: String
    let commitId: String
    let path: String
    let position: Int
}

/// Request to create a review comment using line numbers.
struct CreateReviewCommentLineRequest: Encodable, Sendable {
    let body: String
    let commitId: String
    let path: String
    let line: Int
    let side: String
}

/// Request to update a review comment.
struct UpdateReviewCommentRequest: Encodable, Sendable {
    let body: String
}

/// A review comment on a pull request.
public struct ReviewComment: Decodable, Sendable {
    public let id: Int
    public let body: String
    public let path: String
    public let position: Int?
    public let line: Int?
    public let side: String?
    public let commitId: String
    public let htmlUrl: String
    public let user: ReviewCommentUser?

    public var url: URL? {
        URL(string: htmlUrl)
    }
}

/// User who created a review comment.
public struct ReviewCommentUser: Decodable, Sendable {
    public let id: Int
    public let login: String
}
