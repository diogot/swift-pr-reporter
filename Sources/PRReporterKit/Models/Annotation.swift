/// Represents a single piece of feedback to post to GitHub.
public struct Annotation: Sendable, Equatable, Hashable {
    /// The severity level of the annotation.
    public enum Level: String, Sendable, Equatable, Hashable {
        case notice
        case warning
        case failure
    }

    /// File path relative to the repository root.
    public let path: String

    /// Line number where the annotation applies.
    public let line: Int

    /// Optional end line for multi-line annotations.
    public let endLine: Int?

    /// Optional column number for precise positioning.
    public let column: Int?

    /// Severity level of the annotation.
    public let level: Level

    /// The message to display.
    public let message: String

    /// Optional title for the annotation.
    public let title: String?

    /// When true, resolved annotations show strikethrough instead of being deleted.
    /// (Inspired by Danger's sticky flag)
    public let sticky: Bool

    /// Creates a new annotation.
    /// - Parameters:
    ///   - path: File path relative to the repository root.
    ///   - line: Line number where the annotation applies.
    ///   - endLine: Optional end line for multi-line annotations.
    ///   - column: Optional column number for precise positioning.
    ///   - level: Severity level of the annotation.
    ///   - message: The message to display.
    ///   - title: Optional title for the annotation.
    ///   - sticky: When true, resolved annotations show strikethrough instead of being deleted.
    public init(
        path: String,
        line: Int,
        endLine: Int? = nil,
        column: Int? = nil,
        level: Level,
        message: String,
        title: String? = nil,
        sticky: Bool = false
    ) {
        self.path = path
        self.line = line
        self.endLine = endLine
        self.column = column
        self.level = level
        self.message = message
        self.title = title
        self.sticky = sticky
    }
}
