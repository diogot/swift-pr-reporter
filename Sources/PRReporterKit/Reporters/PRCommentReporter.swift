#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

/// Reporter that posts/updates a single summary comment on the PR.
public final class PRCommentReporter: Reporter, Sendable {
    private let context: GitHubContext
    private let api: GitHubAPI
    private let issuesAPI: IssuesAPI
    private let identifier: String
    private let commentMode: CommentMode

    /// The current comment ID (if found/created).
    private let commentIDLock = NSLock()
    nonisolated(unsafe) private var _commentID: Int?
    private var commentID: Int? {
        get { commentIDLock.withLock { _commentID } }
        set { commentIDLock.withLock { _commentID = newValue } }
    }

    /// Creates a new PR Comment reporter.
    /// - Parameters:
    ///   - context: GitHub context with authentication and repository info.
    ///   - identifier: Used to identify and track comments.
    ///   - commentMode: How to handle existing comments.
    public init(
        context: GitHubContext,
        identifier: String,
        commentMode: CommentMode = .update
    ) {
        self.context = context
        self.identifier = identifier
        self.commentMode = commentMode

        self.api = GitHubAPI(token: context.token)
        self.issuesAPI = IssuesAPI(api: api, owner: context.owner, repo: context.repo)
    }

    /// Post annotations as a summary comment.
    /// - Parameter annotations: The annotations to post.
    /// - Returns: Result with counts.
    public func report(_ annotations: [Annotation]) async throws -> ReportResult {
        // Validate write access and PR context
        try context.validateWriteAccess()

        guard let prNumber = context.pullRequest else {
            throw ContextError.missingPullRequestNumber
        }

        // Generate comment body from annotations
        let body = generateCommentBody(annotations: annotations)
        let markedBody = CommentMarker.addMarker(to: body, identifier: identifier)

        var posted = 0
        var updated = 0
        var deleted = 0
        var commentURL: URL?

        switch commentMode {
        case .update:
            // Find existing comment and update, or create new
            let existingComments = try await issuesAPI.findComments(issueNumber: prNumber, withIdentifier: identifier)

            if let existing = existingComments.first {
                // Check if content changed
                let existingHash = CommentMarker.parse(from: existing.body)?.contentHash
                let newHash = CommentMarker.hash(content: body)

                if existingHash != newHash {
                    let updatedComment = try await issuesAPI.updateComment(commentID: existing.id, body: markedBody)
                    commentID = updatedComment.id
                    commentURL = updatedComment.url
                    updated = 1
                } else {
                    // No change needed
                    commentID = existing.id
                    commentURL = existing.url
                }
            } else {
                // Create new comment
                let newComment = try await issuesAPI.createComment(issueNumber: prNumber, body: markedBody)
                commentID = newComment.id
                commentURL = newComment.url
                posted = 1
            }

        case .append:
            // Always create a new comment
            let newComment = try await issuesAPI.createComment(issueNumber: prNumber, body: markedBody)
            commentID = newComment.id
            commentURL = newComment.url
            posted = 1

        case .replace:
            // Delete existing comments, then create new
            let existingComments = try await issuesAPI.findComments(issueNumber: prNumber, withIdentifier: identifier)

            for comment in existingComments {
                try await issuesAPI.deleteComment(commentID: comment.id)
                deleted += 1
            }

            let newComment = try await issuesAPI.createComment(issueNumber: prNumber, body: markedBody)
            commentID = newComment.id
            commentURL = newComment.url
            posted = 1
        }

        return ReportResult(
            annotationsPosted: annotations.count,
            annotationsUpdated: updated > 0 ? annotations.count : 0,
            annotationsDeleted: deleted,
            commentURL: commentURL
        )
    }

    /// Post a markdown summary directly.
    /// - Parameter markdown: The markdown content.
    public func postSummary(_ markdown: String) async throws {
        guard let prNumber = context.pullRequest else {
            throw ContextError.missingPullRequestNumber
        }

        let markedBody = CommentMarker.addMarker(to: markdown, identifier: identifier)

        switch commentMode {
        case .update:
            let existingComments = try await issuesAPI.findComments(issueNumber: prNumber, withIdentifier: identifier)

            if let existing = existingComments.first {
                let existingHash = CommentMarker.parse(from: existing.body)?.contentHash
                let newHash = CommentMarker.hash(content: markdown)

                if existingHash != newHash {
                    let updatedComment = try await issuesAPI.updateComment(commentID: existing.id, body: markedBody)
                    commentID = updatedComment.id
                } else {
                    commentID = existing.id
                }
            } else {
                let newComment = try await issuesAPI.createComment(issueNumber: prNumber, body: markedBody)
                commentID = newComment.id
            }

        case .append:
            let newComment = try await issuesAPI.createComment(issueNumber: prNumber, body: markedBody)
            commentID = newComment.id

        case .replace:
            let existingComments = try await issuesAPI.findComments(issueNumber: prNumber, withIdentifier: identifier)

            for comment in existingComments {
                try await issuesAPI.deleteComment(commentID: comment.id)
            }

            let newComment = try await issuesAPI.createComment(issueNumber: prNumber, body: markedBody)
            commentID = newComment.id
        }
    }

    /// Clean up stale comments.
    public func cleanup() async throws {
        guard let prNumber = context.pullRequest else {
            return // No PR, nothing to clean up
        }

        switch commentMode {
        case .update:
            // Delete comment if it exists (no new annotations)
            let existingComments = try await issuesAPI.findComments(issueNumber: prNumber, withIdentifier: identifier)
            for comment in existingComments {
                // Check for sticky annotations and strikethrough instead
                if commentContainsStickyContent(comment.body) {
                    let strickenBody = strikeThroughContent(comment.body)
                    _ = try await issuesAPI.updateComment(commentID: comment.id, body: strickenBody)
                } else {
                    try await issuesAPI.deleteComment(commentID: comment.id)
                }
            }

        case .append:
            // No-op: historical comments are preserved
            break

        case .replace:
            // Delete all previous comments with this identifier
            let existingComments = try await issuesAPI.findComments(issueNumber: prNumber, withIdentifier: identifier)
            for comment in existingComments {
                try await issuesAPI.deleteComment(commentID: comment.id)
            }
        }
    }

    // MARK: - Private Helpers

    private func generateCommentBody(annotations: [Annotation]) -> String {
        let failures = annotations.filter { $0.level == .failure }
        let warnings = annotations.filter { $0.level == .warning }
        let notices = annotations.filter { $0.level == .notice }

        var body = ""

        // Summary header
        if !failures.isEmpty {
            body += "## Errors (\(failures.count))\n\n"
            for annotation in failures {
                body += formatAnnotation(annotation)
            }
            body += "\n"
        }

        if !warnings.isEmpty {
            body += "## Warnings (\(warnings.count))\n\n"
            for annotation in warnings {
                body += formatAnnotation(annotation)
            }
            body += "\n"
        }

        if !notices.isEmpty {
            body += "## Notices (\(notices.count))\n\n"
            for annotation in notices {
                body += formatAnnotation(annotation)
            }
            body += "\n"
        }

        if annotations.isEmpty {
            body = "No issues found."
        }

        return body
    }

    private func formatAnnotation(_ annotation: Annotation) -> String {
        let icon: String
        switch annotation.level {
        case .failure:
            icon = ":x:"
        case .warning:
            icon = ":warning:"
        case .notice:
            icon = ":information_source:"
        }

        var line = "\(icon) **\(annotation.path):\(annotation.line)**"
        if let title = annotation.title {
            line += " - \(title)"
        }
        line += "\n  \(annotation.message)\n"

        // Apply strikethrough for sticky resolved annotations
        if annotation.sticky {
            // Mark as sticky for potential future strikethrough
            line += "<!-- sticky -->\n"
        }

        return line
    }

    private func commentContainsStickyContent(_ body: String) -> Bool {
        body.contains("<!-- sticky -->")
    }

    private func strikeThroughContent(_ body: String) -> String {
        // Remove the marker first
        var content = CommentMarker.removeMarker(from: body)

        // Apply strikethrough to non-empty lines
        let lines = content.components(separatedBy: "\n")
        let stricken = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("<!--") || trimmed.hasPrefix("~~") {
                return line
            }
            return "~~\(line)~~"
        }

        content = stricken.joined(separator: "\n")

        // Re-add marker
        return CommentMarker.addMarker(to: content, identifier: identifier)
    }
}
