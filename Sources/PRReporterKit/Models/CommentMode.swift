/// Comment behavior mode (inspired by Danger's CLI flags).
public enum CommentMode: Sendable {
    /// Update existing comment in place (default).
    case update

    /// Create new comment, keep old ones (Danger's --new-comment).
    case append

    /// Delete old comments, create fresh at end (Danger's --remove-previous-comments).
    case replace
}
