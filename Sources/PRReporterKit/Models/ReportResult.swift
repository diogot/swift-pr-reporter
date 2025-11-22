import Foundation

/// Result of a report operation.
public struct ReportResult: Sendable {
    /// Number of annotations successfully posted.
    public let annotationsPosted: Int

    /// Number of annotations that were updated (not newly created).
    public let annotationsUpdated: Int

    /// Number of annotations that were deleted.
    public let annotationsDeleted: Int

    /// URL to the check run (if applicable).
    public let checkRunURL: URL?

    /// URL to the comment (if applicable).
    public let commentURL: URL?

    /// Creates a new report result.
    /// - Parameters:
    ///   - annotationsPosted: Number of annotations successfully posted.
    ///   - annotationsUpdated: Number of annotations that were updated.
    ///   - annotationsDeleted: Number of annotations that were deleted.
    ///   - checkRunURL: URL to the check run (if applicable).
    ///   - commentURL: URL to the comment (if applicable).
    public init(
        annotationsPosted: Int = 0,
        annotationsUpdated: Int = 0,
        annotationsDeleted: Int = 0,
        checkRunURL: URL? = nil,
        commentURL: URL? = nil
    ) {
        self.annotationsPosted = annotationsPosted
        self.annotationsUpdated = annotationsUpdated
        self.annotationsDeleted = annotationsDeleted
        self.checkRunURL = checkRunURL
        self.commentURL = commentURL
    }
}
