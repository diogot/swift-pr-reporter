import Foundation

/// Errors that can occur when parsing GitHub context.
public enum ContextError: Error, CustomStringConvertible, Sendable {
    /// A required environment variable is missing.
    case missingVariable(String)

    /// The event payload file is missing or invalid.
    case invalidEventPayload(String)

    /// No pull request number could be determined.
    case missingPullRequestNumber

    /// The event type is not supported for this operation.
    case unsupportedEvent(String)

    /// Token has read-only access (e.g., fork PR).
    case readOnlyToken(String)

    public var description: String {
        switch self {
        case .missingVariable(let name):
            return "Missing required environment variable: \(name)"
        case .invalidEventPayload(let reason):
            return "Invalid event payload: \(reason)"
        case .missingPullRequestNumber:
            return "Pull request number could not be determined. Ensure this is a PR event or provide the PR number explicitly."
        case .unsupportedEvent(let event):
            return "Unsupported event type '\(event)' for this operation"
        case .readOnlyToken(let reason):
            return "Read-only token: \(reason)"
        }
    }
}
