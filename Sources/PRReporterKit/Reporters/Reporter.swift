/// Protocol for reporters that post annotations to GitHub.
public protocol Reporter: Sendable {
    /// Post annotations to GitHub.
    /// - Parameter annotations: The annotations to post.
    /// - Returns: Result containing counts of posted/updated/deleted annotations.
    func report(_ annotations: [Annotation]) async throws -> ReportResult

    /// Post a markdown summary.
    /// - Parameter markdown: The markdown content to post.
    func postSummary(_ markdown: String) async throws

    /// Remove stale comments/annotations from previous runs.
    func cleanup() async throws
}
