#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

/// A mock URL protocol for testing network requests without making real HTTP calls.
/// Thread-safe implementation for use with async/await tests.
final class MockURLProtocol: URLProtocol {
    /// Lock for thread-safe access to shared state.
    private static let lock = NSLock()

    /// Internal storage for request handler.
    nonisolated(unsafe) private static var _requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// Internal storage for recorded requests.
    nonisolated(unsafe) private static var _recordedRequests: [URLRequest] = []

    /// Handler for incoming requests. Set this before making requests.
    /// Thread-safe accessor.
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { lock.withLock { _requestHandler } }
        set { lock.withLock { _requestHandler = newValue } }
    }

    /// Recorded requests for verification.
    /// Thread-safe accessor that returns a copy of the array.
    static var recordedRequests: [URLRequest] {
        lock.withLock { Array(_recordedRequests) }
    }

    /// Reset the mock state. Thread-safe.
    static func reset() {
        lock.withLock {
            _requestHandler = nil
            _recordedRequests = []
        }
    }

    /// Append a request to the recorded list. Thread-safe.
    private static func appendRequest(_ request: URLRequest) {
        lock.withLock {
            _recordedRequests.append(request)
        }
    }

    /// Get the handler. Thread-safe.
    private static func getHandler() -> ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        lock.withLock { _requestHandler }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.appendRequest(request)

        guard let handler = Self.getHandler() else {
            fatalError("MockURLProtocol.requestHandler not set")
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Test Helpers

extension MockURLProtocol {
    /// Create a URLSession configured to use MockURLProtocol.
    static func createMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Set up a simple success response.
    static func setupSuccessResponse(json: Any, statusCode: Int = 200) {
        requestHandler = { request in
            let data = try! JSONSerialization.data(withJSONObject: json)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }
    }

    /// Set up an error response.
    static func setupErrorResponse(statusCode: Int, message: String) {
        requestHandler = { request in
            let json: [String: Any] = ["message": message]
            let data = try! JSONSerialization.data(withJSONObject: json)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }
    }
}
