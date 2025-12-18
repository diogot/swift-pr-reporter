#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

/// Strategy for handling annotations on lines not in the diff.
public enum OutOfRangeStrategy: Sendable {
    /// Silently ignore annotations outside diff.
    case dismiss

    /// Include out-of-range annotations in PR summary comment.
    case fallbackToComment

    /// Post via CheckRunReporter instead (can annotate any line).
    case fallbackToCheckRun
}

/// Reporter that posts PR review comments on specific lines in the diff.
public final class PRReviewReporter: Reporter, Sendable {
    private let context: GitHubContext
    private let api: GitHubAPI
    private let pullRequestsAPI: PullRequestsAPI
    private let identifier: String
    private let outOfRangeStrategy: OutOfRangeStrategy

    /// Fallback reporters for out-of-range annotations.
    private let fallbackCommentReporter: PRCommentReporter?
    private let fallbackCheckRunReporter: CheckRunReporter?

    /// Creates a new PR Review reporter.
    /// - Parameters:
    ///   - context: GitHub context with authentication and repository info.
    ///   - identifier: Used to identify and track comments.
    ///   - outOfRangeStrategy: How to handle annotations outside the diff.
    ///   - urlSession: URL session to use for API requests (default: shared).
    public init(
        context: GitHubContext,
        identifier: String,
        outOfRangeStrategy: OutOfRangeStrategy = .fallbackToComment,
        urlSession: URLSession = .shared
    ) {
        self.context = context
        self.identifier = identifier
        self.outOfRangeStrategy = outOfRangeStrategy

        self.api = GitHubAPI(token: context.token, urlSession: urlSession)
        self.pullRequestsAPI = PullRequestsAPI(api: api, owner: context.owner, repo: context.repo)

        // Initialize fallback reporters based on strategy
        switch outOfRangeStrategy {
        case .fallbackToComment:
            self.fallbackCommentReporter = PRCommentReporter(
                context: context,
                identifier: "\(identifier)-overflow"
            )
            self.fallbackCheckRunReporter = nil
        case .fallbackToCheckRun:
            self.fallbackCommentReporter = nil
            self.fallbackCheckRunReporter = CheckRunReporter(
                context: context,
                name: "\(identifier) (Overflow)",
                identifier: "\(identifier)-overflow"
            )
        case .dismiss:
            self.fallbackCommentReporter = nil
            self.fallbackCheckRunReporter = nil
        }
    }

    /// Post annotations as review comments.
    /// - Parameter annotations: The annotations to post.
    /// - Returns: Result with counts.
    public func report(_ annotations: [Annotation]) async throws -> ReportResult {
        // Validate write access and PR context
        try context.validateWriteAccess()

        guard let prNumber = context.pullRequest else {
            throw ContextError.missingPullRequestNumber
        }

        // Fetch files to get diff information
        let files = try await pullRequestsAPI.listFiles(prNumber: prNumber)
        // Use reduce to handle potential duplicate filenames (last wins)
        let filesDict = files.reduce(into: [String: PullRequestFile]()) { dict, file in
            dict[file.filename] = file
        }

        // Categorize annotations
        var inRangeAnnotations: [(Annotation, PullRequestFile, Int)] = [] // (annotation, file, position)
        var outOfRangeAnnotations: [Annotation] = []

        for annotation in annotations {
            // Find the file
            guard let resolvedPath = DiffMapper.resolvedPath(for: annotation, files: files),
                  let file = filesDict[resolvedPath],
                  let patch = file.patch else {
                outOfRangeAnnotations.append(annotation)
                continue
            }

            // Find position in diff
            if let position = DiffMapper.position(forLine: annotation.line, inPatch: patch) {
                inRangeAnnotations.append((annotation, file, position))
            } else {
                outOfRangeAnnotations.append(annotation)
            }
        }

        var posted = 0
        var updated = 0

        // Find existing comments for update/cleanup
        let existingComments = try await pullRequestsAPI.findReviewComments(
            prNumber: prNumber,
            withIdentifier: identifier
        )
        // Group existing comments by path:line key, preserving all duplicates
        let existingByKey: [String: [ReviewComment]] = existingComments.reduce(into: [:]) { dict, comment in
            guard let line = comment.line else { return }
            let key = "\(comment.path):\(line)"
            dict[key, default: []].append(comment)
        }

        // Post in-range annotations
        for (annotation, file, position) in inRangeAnnotations {
            let key = "\(file.filename):\(annotation.line)"
            let body = formatAnnotationBody(annotation)
            let markedBody = CommentMarker.addMarker(to: body, identifier: identifier)

            if let existingComments = existingByKey[key], !existingComments.isEmpty {
                // Check if any existing comment already contains this content
                // (either as full body or as a section in a merged comment)
                let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
                let newHash = CommentMarker.hash(content: trimmedBody)
                let alreadyExists = existingComments.contains { comment in
                    let existingContent = CommentMarker.removeMarker(from: comment.body)
                    let sections = existingContent.components(separatedBy: "\n\n---\n\n")
                    return sections.contains { section in
                        let trimmedSection = section.trimmingCharacters(in: .whitespacesAndNewlines)
                        return CommentMarker.hash(content: trimmedSection) == newHash
                    }
                }

                if !alreadyExists {
                    // Append to the most recent comment (highest ID)
                    guard let mostRecent = existingComments.max(by: { $0.id < $1.id }) else {
                        // This should never happen since existingComments is verified non-empty above
                        print("[WARNING] Unexpected: no most recent comment found for \(key) despite non-empty array")
                        continue
                    }
                    let existingContent = CommentMarker.removeMarker(from: mostRecent.body)
                    let combinedBody = existingContent + "\n\n---\n\n" + body
                    let combinedMarkedBody = CommentMarker.addMarker(to: combinedBody, identifier: identifier)
                    _ = try await pullRequestsAPI.updateReviewComment(
                        commentID: mostRecent.id,
                        body: combinedMarkedBody
                    )
                    updated += 1
                }
            } else {
                // Create new comment
                _ = try await pullRequestsAPI.createReviewComment(
                    prNumber: prNumber,
                    body: markedBody,
                    commitID: context.commitSHA,
                    path: file.filename,
                    position: position
                )
                posted += 1
            }
        }

        // Handle out-of-range annotations based on strategy
        var fallbackResult: ReportResult?
        if !outOfRangeAnnotations.isEmpty {
            switch outOfRangeStrategy {
            case .dismiss:
                // Silently ignore
                break

            case .fallbackToComment:
                if let reporter = fallbackCommentReporter {
                    fallbackResult = try await reporter.report(outOfRangeAnnotations)
                }

            case .fallbackToCheckRun:
                if let reporter = fallbackCheckRunReporter {
                    fallbackResult = try await reporter.report(outOfRangeAnnotations)
                }
            }
        }

        return ReportResult(
            annotationsPosted: posted + (fallbackResult?.annotationsPosted ?? 0),
            annotationsUpdated: updated + (fallbackResult?.annotationsUpdated ?? 0),
            annotationsDeleted: 0,
            checkRunURL: fallbackResult?.checkRunURL,
            commentURL: fallbackResult?.commentURL
        )
    }

    /// Post a markdown summary.
    /// - Parameter markdown: The markdown content.
    public func postSummary(_ markdown: String) async throws {
        // Review comments don't have a natural place for summaries.
        // Use the fallback comment reporter if available.
        if let reporter = fallbackCommentReporter {
            try await reporter.postSummary(markdown)
        }
    }

    /// Clean up stale review comments.
    public func cleanup() async throws {
        guard let prNumber = context.pullRequest else {
            return
        }

        let existingComments = try await pullRequestsAPI.findReviewComments(
            prNumber: prNumber,
            withIdentifier: identifier
        )

        for comment in existingComments {
            // Check for sticky flag
            if comment.body.contains("<!-- sticky -->") {
                // Apply strikethrough instead of deleting
                let strickenBody = strikeThroughContent(comment.body)
                _ = try await pullRequestsAPI.updateReviewComment(
                    commentID: comment.id,
                    body: strickenBody
                )
            } else {
                try await pullRequestsAPI.deleteReviewComment(commentID: comment.id)
            }
        }

        // Also clean up fallback reporters
        try await fallbackCommentReporter?.cleanup()
        try await fallbackCheckRunReporter?.cleanup()
    }

    // MARK: - Private Helpers

    private func formatAnnotationBody(_ annotation: Annotation) -> String {
        let icon: String
        switch annotation.level {
        case .failure:
            icon = ":x:"
        case .warning:
            icon = ":warning:"
        case .notice:
            icon = ":information_source:"
        }

        var body = "\(icon) "
        if let title = annotation.title {
            body += "**\(title)**\n\n"
        }
        body += annotation.message

        if annotation.sticky {
            body += "\n<!-- sticky -->"
        }

        return body
    }

    private func strikeThroughContent(_ body: String) -> String {
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
        return CommentMarker.addMarker(to: content, identifier: identifier)
    }
}
