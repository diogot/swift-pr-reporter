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
            }

        case .append:
            // Always create a new comment
            let newComment = try await issuesAPI.createComment(issueNumber: prNumber, body: markedBody)
            commentID = newComment.id
            commentURL = newComment.url

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
        // Deduplicate annotations on the same file:line with same message
        let deduplicated = deduplicateAnnotations(annotations)

        let failures = deduplicated.filter { $0.annotation.level == .failure }
        let warnings = deduplicated.filter { $0.annotation.level == .warning }
        let notices = deduplicated.filter { $0.annotation.level == .notice }

        var body = ""

        // Summary header
        if !failures.isEmpty {
            let totalCount = failures.reduce(0) { $0 + $1.count }
            body += "## :x: Errors (\(totalCount))\n\n"
            body += formatAnnotationsGroupedByFile(failures)
        }

        if !warnings.isEmpty {
            let totalCount = warnings.reduce(0) { $0 + $1.count }
            body += "## :warning: Warnings (\(totalCount))\n\n"
            body += formatAnnotationsGroupedByFile(warnings)
        }

        if !notices.isEmpty {
            let totalCount = notices.reduce(0) { $0 + $1.count }
            body += "## :information_source: Notices (\(totalCount))\n\n"
            body += formatAnnotationsGroupedByFile(notices)
        }

        if annotations.isEmpty {
            body = ":white_check_mark: No issues found.\n"
        }

        // Add workflow run link
        if let runID = context.runID {
            let runURL = "https://github.com/\(context.owner)/\(context.repo)/actions/runs/\(runID)"
            body += "\n---\n[View full logs →](\(runURL))\n"
        }

        return body
    }

    private struct DeduplicatedAnnotation {
        let annotation: Annotation
        let count: Int
    }

    private func deduplicateAnnotations(_ annotations: [Annotation]) -> [DeduplicatedAnnotation] {
        var seen: [String: (annotation: Annotation, count: Int)] = [:]

        for annotation in annotations {
            let key = "\(annotation.path):\(annotation.line):\(annotation.message)"
            if let existing = seen[key] {
                seen[key] = (existing.annotation, existing.count + 1)
            } else {
                seen[key] = (annotation, 1)
            }
        }

        // Sort by file path, then line number
        return seen.values
            .map { DeduplicatedAnnotation(annotation: $0.annotation, count: $0.count) }
            .sorted { lhs, rhs in
                if lhs.annotation.path != rhs.annotation.path {
                    return lhs.annotation.path < rhs.annotation.path
                }
                return lhs.annotation.line < rhs.annotation.line
            }
    }

    private func formatAnnotationsGroupedByFile(_ annotations: [DeduplicatedAnnotation]) -> String {
        // Group by file
        var byFile: [String: [DeduplicatedAnnotation]] = [:]
        for item in annotations {
            byFile[item.annotation.path, default: []].append(item)
        }

        var body = ""
        let sortedFiles = byFile.keys.sorted()

        for file in sortedFiles {
            guard let fileAnnotations = byFile[file] else { continue }

            // File header with link
            let fileLink = "https://github.com/\(context.owner)/\(context.repo)/blob/\(context.commitSHA)/\(file)"
            body += "### [`\(file)`](\(fileLink))\n\n"

            // Annotations for this file
            for item in fileAnnotations {
                body += formatAnnotationInGroup(item.annotation, count: item.count)
            }
            body += "\n"
        }

        return body
    }

    private func formatAnnotationInGroup(_ annotation: Annotation, count: Int) -> String {
        // Line link
        let lineLink = "https://github.com/\(context.owner)/\(context.repo)/blob/\(context.commitSHA)/\(annotation.path)#L\(annotation.line)"

        var line = "- **[Line \(annotation.line)](\(lineLink))**"
        if let title = annotation.title {
            line += " — \(title)"
        }
        if count > 1 {
            line += " ×\(count)"
        }
        line += "\n  > \(annotation.message)\n"

        if annotation.sticky {
            line += "  <!-- sticky -->\n"
        }

        return line
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

        // Create clickable link to the file on GitHub
        let fileLink = "https://github.com/\(context.owner)/\(context.repo)/blob/\(context.commitSHA)/\(annotation.path)#L\(annotation.line)"
        var line = "\(icon) [`\(annotation.path):\(annotation.line)`](\(fileLink))"
        if let title = annotation.title {
            line += " — \(title)"
        }
        line += "\n> \(annotation.message)\n"

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
