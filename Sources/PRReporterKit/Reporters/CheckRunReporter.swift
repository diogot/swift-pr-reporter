#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

/// Strategy for handling overflow when more than 50 annotations need to be posted.
public enum OverflowStrategy: Sendable {
    /// Show "and X more..." in summary (default).
    case truncate

    /// Create additional check runs (name + " (2/3)").
    case multipleRuns

    /// Post overflow as PR comment.
    case fallbackToComment
}

/// Reporter that creates/updates GitHub Check Runs with annotations.
public final class CheckRunReporter: Reporter, Sendable {
    /// Maximum annotations per API request.
    private static let maxAnnotationsPerRequest = 50

    private let context: GitHubContext
    private let api: GitHubAPI
    private let checksAPI: ChecksAPI
    private let name: String
    private let identifier: String
    private let overflowStrategy: OverflowStrategy

    /// The check run ID (set after creation).
    private let checkRunIDLock = NSLock()
    nonisolated(unsafe) private var _checkRunID: Int?
    private var checkRunID: Int? {
        get { checkRunIDLock.withLock { _checkRunID } }
        set { checkRunIDLock.withLock { _checkRunID = newValue } }
    }

    /// Stored summary for final completion.
    private let summaryLock = NSLock()
    nonisolated(unsafe) private var _storedSummary: String?
    private var storedSummary: String? {
        get { summaryLock.withLock { _storedSummary } }
        set { summaryLock.withLock { _storedSummary = newValue } }
    }

    /// Creates a new Check Run reporter.
    /// - Parameters:
    ///   - context: GitHub context with authentication and repository info.
    ///   - name: Check run name shown in UI.
    ///   - identifier: Used as external_id for idempotent updates.
    ///   - overflowStrategy: Strategy for handling more than 50 annotations.
    public init(
        context: GitHubContext,
        name: String,
        identifier: String,
        overflowStrategy: OverflowStrategy = .truncate
    ) {
        self.context = context
        self.name = name
        self.identifier = identifier
        self.overflowStrategy = overflowStrategy

        self.api = GitHubAPI(token: context.token)
        self.checksAPI = ChecksAPI(api: api, owner: context.owner, repo: context.repo)
    }

    /// Generate the external ID for idempotent check run identification.
    private var externalID: String {
        var id = identifier
        if let runID = context.runID {
            id += "-\(runID)"
        }
        id += "-\(context.runAttempt)"
        return id
    }

    /// Post annotations to the check run.
    /// - Parameter annotations: The annotations to post.
    /// - Returns: Result with counts.
    public func report(_ annotations: [Annotation]) async throws -> ReportResult {
        // Validate write access
        try context.validateWriteAccess()

        // Find or create check run
        let checkRun = try await findOrCreateCheckRun()
        checkRunID = checkRun.id

        // Determine conclusion based on annotations
        let hasFailures = annotations.contains { $0.level == .failure }

        // Chunk annotations into batches of 50
        let chunks = annotations.chunked(into: Self.maxAnnotationsPerRequest)
        var annotationsPosted = 0

        // Generate summary
        let summary = generateSummary(annotations: annotations)

        if chunks.isEmpty {
            // No annotations, just complete the check run
            let updateRequest = UpdateCheckRunRequest(
                status: .completed,
                conclusion: .success,
                completedAt: ISO8601DateFormatter().string(from: Date()),
                output: CheckRunOutput(
                    title: name,
                    summary: storedSummary ?? summary
                )
            )
            _ = try await checksAPI.updateCheckRun(checkRun.id, updateRequest)
        } else {
            // Post annotations in chunks
            for (index, chunk) in chunks.enumerated() {
                let isLast = index == chunks.count - 1
                let checkAnnotations = chunk.map { CheckRunAnnotation.from($0) }

                let updateRequest: UpdateCheckRunRequest
                if isLast {
                    // Final update: complete the run
                    updateRequest = UpdateCheckRunRequest(
                        status: .completed,
                        conclusion: hasFailures ? .failure : .success,
                        completedAt: ISO8601DateFormatter().string(from: Date()),
                        output: CheckRunOutput(
                            title: name,
                            summary: storedSummary ?? summary,
                            annotations: checkAnnotations
                        )
                    )
                } else {
                    // Intermediate update: just add annotations
                    updateRequest = UpdateCheckRunRequest(
                        output: CheckRunOutput(
                            title: name,
                            summary: summary,
                            annotations: checkAnnotations
                        )
                    )
                }

                _ = try await checksAPI.updateCheckRun(checkRun.id, updateRequest)
                annotationsPosted += chunk.count
            }
        }

        // Handle overflow annotations based on strategy
        if annotations.count > Self.maxAnnotationsPerRequest && overflowStrategy == .truncate {
            // Truncation summary is already included
        }

        return ReportResult(
            annotationsPosted: annotationsPosted,
            checkRunURL: checkRun.url
        )
    }

    /// Post a markdown summary to the check run.
    /// - Parameter markdown: The markdown content.
    public func postSummary(_ markdown: String) async throws {
        storedSummary = markdown

        // If check run already exists, update it
        if let id = checkRunID {
            let updateRequest = UpdateCheckRunRequest(
                output: CheckRunOutput(
                    title: name,
                    summary: markdown
                )
            )
            _ = try await checksAPI.updateCheckRun(id, updateRequest)
        }
    }

    /// Cleanup is a no-op for check runs (annotations cannot be deleted).
    public func cleanup() async throws {
        // Check run annotations cannot be individually deleted.
        // This is intentionally a no-op.
    }

    /// Complete the check run with a specific conclusion.
    /// Use this to finalize the check run after posting annotations and summary.
    /// - Parameter conclusion: The conclusion to set for the check run.
    public func complete(conclusion: CheckRunConclusion) async throws {
        // Validate write access
        try context.validateWriteAccess()

        let checkRun = try await findOrCreateCheckRun()
        checkRunID = checkRun.id

        let updateRequest = UpdateCheckRunRequest(
            status: .completed,
            conclusion: conclusion,
            completedAt: ISO8601DateFormatter().string(from: Date()),
            output: CheckRunOutput(
                title: name,
                summary: storedSummary ?? "Completed"
            )
        )
        _ = try await checksAPI.updateCheckRun(checkRun.id, updateRequest)
    }

    // MARK: - Private Helpers

    private func findOrCreateCheckRun() async throws -> CheckRun {
        // Try to find existing check run by external ID
        if let existing = try await checksAPI.findCheckRun(ref: context.commitSHA, externalID: externalID) {
            return existing
        }

        // Create new check run
        let request = CreateCheckRunRequest(
            name: name,
            headSha: context.commitSHA,
            externalId: externalID,
            status: .inProgress,
            startedAt: ISO8601DateFormatter().string(from: Date()),
            output: CheckRunOutput(
                title: name,
                summary: "Running..."
            )
        )

        return try await checksAPI.createCheckRun(request)
    }

    private func generateSummary(annotations: [Annotation]) -> String {
        let failures = annotations.filter { $0.level == .failure }.count
        let warnings = annotations.filter { $0.level == .warning }.count
        let notices = annotations.filter { $0.level == .notice }.count

        var summary = ""

        if failures > 0 {
            summary += "**\(failures) error\(failures == 1 ? "" : "s")**"
        }
        if warnings > 0 {
            if !summary.isEmpty { summary += ", " }
            summary += "\(warnings) warning\(warnings == 1 ? "" : "s")"
        }
        if notices > 0 {
            if !summary.isEmpty { summary += ", " }
            summary += "\(notices) notice\(notices == 1 ? "" : "s")"
        }

        if summary.isEmpty {
            summary = "No issues found"
        }

        // Add overflow note if truncating
        if annotations.count > Self.maxAnnotationsPerRequest && overflowStrategy == .truncate {
            let shown = Self.maxAnnotationsPerRequest
            let remaining = annotations.count - shown
            summary += "\n\n_Showing first \(shown) annotations. \(remaining) more not shown._"
        }

        return summary
    }
}

// MARK: - Array Extension

extension Array {
    /// Split array into chunks of specified size.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
