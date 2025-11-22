import Foundation

/// Errors that can occur when communicating with the GitHub API.
public struct GitHubAPIError: Error, Sendable, CustomStringConvertible {
    /// HTTP status code from the response.
    public let statusCode: Int

    /// Error message (decoded from GitHub error JSON when present).
    public let message: String

    /// The API endpoint that was called.
    public let endpoint: String

    /// GitHub request ID for debugging.
    public let requestID: String?

    /// Whether this error is retryable.
    public let retryable: Bool

    /// Raw response body (useful for debugging).
    public let responseBody: String?

    public var description: String {
        var desc = "GitHub API Error (\(statusCode)): \(message)"
        if let requestID = requestID {
            desc += " [Request-ID: \(requestID)]"
        }
        desc += " - Endpoint: \(endpoint)"
        return desc
    }

    /// Creates a new API error.
    public init(
        statusCode: Int,
        message: String,
        endpoint: String,
        requestID: String? = nil,
        retryable: Bool = false,
        responseBody: String? = nil
    ) {
        self.statusCode = statusCode
        self.message = message
        self.endpoint = endpoint
        self.requestID = requestID
        self.retryable = retryable
        self.responseBody = responseBody
    }

    /// Create an error from an HTTP response and data.
    public static func from(
        response: HTTPURLResponse,
        data: Data,
        endpoint: String
    ) -> GitHubAPIError {
        let statusCode = response.statusCode
        let requestID = response.value(forHTTPHeaderField: "X-GitHub-Request-Id")
        let responseBody = String(data: data, encoding: .utf8)

        // Try to parse GitHub error message
        var message = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errorMessage = json["message"] as? String {
                message = errorMessage
            }
            if let errors = json["errors"] as? [[String: Any]] {
                let errorMessages = errors.compactMap { $0["message"] as? String }
                if !errorMessages.isEmpty {
                    message += ": " + errorMessages.joined(separator: ", ")
                }
            }
        }

        // Determine if retryable
        let retryableCodes: Set<Int> = [429, 500, 502, 503, 504]
        let retryable = retryableCodes.contains(statusCode) ||
            (statusCode == 403 && (message.contains("rate limit") || message.contains("secondary")))

        return GitHubAPIError(
            statusCode: statusCode,
            message: message,
            endpoint: endpoint,
            requestID: requestID,
            retryable: retryable,
            responseBody: responseBody
        )
    }
}

/// Network-level errors.
public enum NetworkError: Error, Sendable {
    case invalidURL(String)
    case noData
    case invalidResponse
    case timeout
    case connectionFailed(String)
}
