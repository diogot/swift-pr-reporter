import Foundation

/// Utility for generating and parsing HTML comment markers for tracking bot comments.
public enum CommentMarker {
    /// The prefix used for all markers.
    private static let prefix = "pr-reporter"

    /// Generate a marker string to embed in comments.
    /// - Parameters:
    ///   - identifier: User-provided identifier (e.g., "xcode-build", "swiftlint").
    ///   - contentHash: Optional hash of the content for change detection.
    /// - Returns: An HTML comment marker string.
    public static func generate(identifier: String, contentHash: String? = nil) -> String {
        if let hash = contentHash {
            return "<!-- \(prefix):\(identifier):\(hash) -->"
        }
        return "<!-- \(prefix):\(identifier) -->"
    }

    /// Parse a marker from a comment body.
    /// - Parameter body: The comment body to search.
    /// - Returns: A tuple of (identifier, contentHash) if a marker is found.
    public static func parse(from body: String) -> (identifier: String, contentHash: String?)? {
        // Pattern: <!-- pr-reporter:identifier:hash --> or <!-- pr-reporter:identifier -->
        let pattern = "<!-- \(prefix):([^:>]+)(?::([^>]+))? -->"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let range = NSRange(body.startIndex..., in: body)
        guard let match = regex.firstMatch(in: body, options: [], range: range) else {
            return nil
        }

        // Extract identifier
        guard let identifierRange = Range(match.range(at: 1), in: body) else {
            return nil
        }
        let identifier = String(body[identifierRange])

        // Extract optional hash
        var contentHash: String?
        if match.numberOfRanges > 2,
           let hashRange = Range(match.range(at: 2), in: body) {
            contentHash = String(body[hashRange])
        }

        return (identifier, contentHash)
    }

    /// Check if a comment body contains a marker with the specified identifier.
    /// - Parameters:
    ///   - body: The comment body to search.
    ///   - identifier: The identifier to look for.
    /// - Returns: True if a matching marker is found.
    public static func contains(identifier: String, in body: String) -> Bool {
        guard let parsed = parse(from: body) else {
            return false
        }
        return parsed.identifier == identifier
    }

    /// Generate a content hash for change detection.
    /// - Parameter content: The content to hash.
    /// - Returns: A short hash string.
    public static func hash(content: String) -> String {
        // Simple hash using the built-in hasher
        var hasher = Hasher()
        hasher.combine(content)
        let hashValue = hasher.finalize()
        // Return first 8 hex characters
        return String(format: "%08x", abs(hashValue))
    }

    /// Add a marker to the beginning of a comment body.
    /// - Parameters:
    ///   - body: The original comment body.
    ///   - identifier: The identifier for the marker.
    ///   - includeContentHash: Whether to include a content hash.
    /// - Returns: The comment body with the marker prepended.
    public static func addMarker(to body: String, identifier: String, includeContentHash: Bool = true) -> String {
        let contentHash = includeContentHash ? hash(content: body) : nil
        let marker = generate(identifier: identifier, contentHash: contentHash)
        return "\(marker)\n\(body)"
    }

    /// Remove the marker from a comment body.
    /// - Parameter body: The comment body with a marker.
    /// - Returns: The comment body without the marker.
    public static func removeMarker(from body: String) -> String {
        let pattern = "<!-- \(prefix):[^>]+ -->\\n?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return body
        }
        let range = NSRange(body.startIndex..., in: body)
        return regex.stringByReplacingMatches(in: body, options: [], range: range, withTemplate: "")
    }
}
