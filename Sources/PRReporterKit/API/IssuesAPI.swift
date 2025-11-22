#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

/// API client for GitHub Issue Comments (used for PR summary comments).
public actor IssuesAPI {
    private let api: GitHubAPI
    private let owner: String
    private let repo: String

    /// Creates a new Issues API client.
    /// - Parameters:
    ///   - api: The underlying GitHub API client.
    ///   - owner: Repository owner.
    ///   - repo: Repository name.
    public init(api: GitHubAPI, owner: String, repo: String) {
        self.api = api
        self.owner = owner
        self.repo = repo
    }

    /// List all comments on an issue/PR.
    /// - Parameter issueNumber: The issue or PR number.
    /// - Returns: Array of all comments (paginated automatically).
    public func listComments(issueNumber: Int) async throws -> [IssueComment] {
        try await api.getAllPages("/repos/\(owner)/\(repo)/issues/\(issueNumber)/comments")
    }

    /// Create a new comment on an issue/PR.
    /// - Parameters:
    ///   - issueNumber: The issue or PR number.
    ///   - body: The comment body (markdown).
    /// - Returns: The created comment.
    public func createComment(issueNumber: Int, body: String) async throws -> IssueComment {
        try await api.post(
            "/repos/\(owner)/\(repo)/issues/\(issueNumber)/comments",
            body: CreateCommentRequest(body: body)
        )
    }

    /// Update an existing comment.
    /// - Parameters:
    ///   - commentID: The comment ID.
    ///   - body: The new comment body (markdown).
    /// - Returns: The updated comment.
    public func updateComment(commentID: Int, body: String) async throws -> IssueComment {
        try await api.patch(
            "/repos/\(owner)/\(repo)/issues/comments/\(commentID)",
            body: UpdateCommentRequest(body: body)
        )
    }

    /// Delete a comment.
    /// - Parameter commentID: The comment ID.
    public func deleteComment(commentID: Int) async throws {
        try await api.delete("/repos/\(owner)/\(repo)/issues/comments/\(commentID)")
    }

    /// Find comments with a specific marker.
    /// - Parameters:
    ///   - issueNumber: The issue or PR number.
    ///   - identifier: The marker identifier to search for.
    /// - Returns: Comments that contain the marker.
    public func findComments(issueNumber: Int, withIdentifier identifier: String) async throws -> [IssueComment] {
        let comments = try await listComments(issueNumber: issueNumber)
        return comments.filter { comment in
            CommentMarker.contains(identifier: identifier, in: comment.body)
        }
    }
}

// MARK: - Request/Response Models

/// Request to create a comment.
struct CreateCommentRequest: Encodable, Sendable {
    let body: String
}

/// Request to update a comment.
struct UpdateCommentRequest: Encodable, Sendable {
    let body: String
}

/// An issue comment response.
public struct IssueComment: Decodable, Sendable {
    public let id: Int
    public let body: String
    public let htmlUrl: String
    public let user: IssueCommentUser?
    public let createdAt: String
    public let updatedAt: String

    public var url: URL? {
        URL(string: htmlUrl)
    }
}

/// User who created a comment.
public struct IssueCommentUser: Decodable, Sendable {
    public let id: Int
    public let login: String
}
