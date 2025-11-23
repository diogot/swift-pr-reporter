#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

/// Low-level REST client for GitHub API with retry and pagination support.
public actor GitHubAPI {
    /// GitHub API token.
    private let token: String

    /// Base URL for the API.
    private let baseURL: URL

    /// URL session for making requests.
    private let urlSession: URLSession

    /// Retry policy configuration.
    private let retryPolicy: RetryPolicy

    /// Logger for debugging.
    private let logger: SafeLogger

    /// JSON encoder for request bodies.
    private let encoder: JSONEncoder

    /// JSON decoder for responses.
    private let decoder: JSONDecoder

    /// Creates a new GitHub API client.
    /// - Parameters:
    ///   - token: GitHub API token.
    ///   - baseURL: Base URL for the API (default: api.github.com).
    ///   - urlSession: URL session to use (default: shared).
    ///   - retryPolicy: Retry policy configuration (default: standard).
    ///   - logger: Logger for debugging (default: info level).
    public init(
        token: String,
        baseURL: URL = URL(string: "https://api.github.com")!,
        urlSession: URLSession = .shared,
        retryPolicy: RetryPolicy = .default,
        logger: SafeLogger? = nil
    ) {
        self.token = token
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.retryPolicy = retryPolicy
        self.logger = logger ?? SafeLogger(level: .info, tokenToRedact: token)

        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    // MARK: - Public HTTP Methods

    /// Perform a GET request.
    /// - Parameters:
    ///   - path: API path (e.g., "/repos/owner/repo/issues").
    ///   - query: Optional query parameters.
    /// - Returns: The response data.
    public func get(_ path: String, query: [String: String]? = nil) async throws -> Data {
        try await request(method: "GET", path: path, query: query, body: nil)
    }

    /// Perform a GET request and decode the response.
    /// - Parameters:
    ///   - path: API path.
    ///   - query: Optional query parameters.
    /// - Returns: The decoded response.
    public func get<T: Decodable>(_ path: String, query: [String: String]? = nil) async throws -> T {
        let data = try await get(path, query: query)
        return try decoder.decode(T.self, from: data)
    }

    /// Perform a POST request.
    /// - Parameters:
    ///   - path: API path.
    ///   - body: Request body to encode as JSON.
    /// - Returns: The response data.
    public func post<B: Encodable>(_ path: String, body: B) async throws -> Data {
        let bodyData = try encoder.encode(body)
        return try await request(method: "POST", path: path, query: nil, body: bodyData)
    }

    /// Perform a POST request and decode the response.
    /// - Parameters:
    ///   - path: API path.
    ///   - body: Request body to encode as JSON.
    /// - Returns: The decoded response.
    public func post<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        let data = try await post(path, body: body)
        return try decoder.decode(T.self, from: data)
    }

    /// Perform a PATCH request.
    /// - Parameters:
    ///   - path: API path.
    ///   - body: Request body to encode as JSON.
    /// - Returns: The response data.
    public func patch<B: Encodable>(_ path: String, body: B) async throws -> Data {
        let bodyData = try encoder.encode(body)
        return try await request(method: "PATCH", path: path, query: nil, body: bodyData)
    }

    /// Perform a PATCH request and decode the response.
    /// - Parameters:
    ///   - path: API path.
    ///   - body: Request body to encode as JSON.
    /// - Returns: The decoded response.
    public func patch<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        let data = try await patch(path, body: body)
        return try decoder.decode(T.self, from: data)
    }

    /// Perform a DELETE request.
    /// - Parameter path: API path.
    public func delete(_ path: String) async throws {
        _ = try await request(method: "DELETE", path: path, query: nil, body: nil)
    }

    // MARK: - Pagination

    /// Fetch all pages of a paginated endpoint.
    /// - Parameters:
    ///   - path: API path.
    ///   - query: Optional query parameters.
    ///   - maxPages: Maximum number of pages to fetch (default: 100).
    /// - Returns: Array of all items across all pages.
    public func getAllPages<T: Decodable>(_ path: String, query: [String: String]? = nil, maxPages: Int = 100) async throws -> [T] {
        var allItems: [T] = []
        var page = 1
        var params = query ?? [:]
        params["per_page"] = "100"

        while page <= maxPages {
            params["page"] = "\(page)"
            let items: [T] = try await get(path, query: params)

            allItems.append(contentsOf: items)

            // Stop if we got fewer items than requested
            if items.count < 100 {
                break
            }

            page += 1
        }

        return allItems
    }

    // MARK: - Private Implementation

    private func request(method: String, path: String, query: [String: String]?, body: Data?) async throws -> Data {
        var urlComponents = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true)

        if let query = query {
            urlComponents?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        guard let url = urlComponents?.url else {
            throw NetworkError.invalidURL(path)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        if let body = body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        logger.logRequest(request)

        return try await executeWithRetry(request: request, path: path)
    }

    private func executeWithRetry(request: URLRequest, path: String) async throws -> Data {
        var lastError: Error?

        for attempt in 0..<retryPolicy.maxAttempts {
            do {
                let start = ContinuousClock.now
                let (data, response) = try await urlSession.data(for: request)
                let duration = ContinuousClock.now - start

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NetworkError.invalidResponse
                }

                logger.logResponse(httpResponse, duration: duration)

                // Success
                if (200..<300).contains(httpResponse.statusCode) {
                    return data
                }

                // Check if retryable
                let error = GitHubAPIError.from(response: httpResponse, data: data, endpoint: path)

                if error.retryable && attempt < retryPolicy.maxAttempts - 1 {
                    // Check for Retry-After header
                    let backoff: Duration
                    if let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After"),
                       let seconds = Int(retryAfter) {
                        backoff = .seconds(seconds)
                    } else {
                        backoff = retryPolicy.backoff(forAttempt: attempt)
                    }

                    logger.warning("Request failed with \(httpResponse.statusCode), retrying in \(backoff) (attempt \(attempt + 1)/\(retryPolicy.maxAttempts))")
                    try await Task.sleep(for: backoff)
                    continue
                }

                throw error

            } catch let error as GitHubAPIError {
                throw error
            } catch let error as NetworkError {
                throw error
            } catch {
                lastError = error

                // Network errors are retryable
                if attempt < retryPolicy.maxAttempts - 1 {
                    let backoff = retryPolicy.backoff(forAttempt: attempt)
                    logger.warning("Network error: \(error.localizedDescription), retrying in \(backoff)")
                    try await Task.sleep(for: backoff)
                    continue
                }
            }
        }

        throw lastError ?? NetworkError.connectionFailed("Unknown error after \(retryPolicy.maxAttempts) attempts")
    }
}
