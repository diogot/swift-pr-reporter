#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

/// A mock URL protocol for testing network requests without making real HTTP calls.
/// Thread-safe implementation for use with async/await tests.
final class MockURLProtocol: URLProtocol {
    /// Lock for thread-safe access to shared state.
    private static let lock = NSLock()

    /// Flag to indicate if mocking is enabled (only intercept when enabled).
    nonisolated(unsafe) private static var _isMockingEnabled = false

    /// Internal storage for request handler.
    nonisolated(unsafe) private static var _requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// Internal storage for URL-based handlers (prefix -> handler).
    nonisolated(unsafe) private static var _routedHandlers: [String: (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]

    /// Internal storage for recorded requests.
    nonisolated(unsafe) private static var _recordedRequests: [URLRequest] = []

    /// Check if mocking is currently enabled.
    static var isMockingEnabled: Bool {
        lock.withLock { _isMockingEnabled }
    }

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

    /// Start mocking - registers the protocol globally.
    /// Note: This clears all handlers. For tests that only need routed handlers,
    /// use ensureMockingEnabled() instead.
    static func startMocking() {
        lock.withLock {
            _isMockingEnabled = true
            _requestHandler = nil
            _routedHandlers = [:]
            _recordedRequests = []
        }
        _ = URLProtocol.registerClass(MockURLProtocol.self)
    }

    /// Ensure mocking is enabled without clearing existing handlers.
    /// Safe to call from multiple test suites concurrently.
    static func ensureMockingEnabled() {
        lock.withLock {
            guard !_isMockingEnabled else { return }
            _isMockingEnabled = true
        }
        _ = URLProtocol.registerClass(MockURLProtocol.self)
    }

    /// Stop mocking - unregisters the protocol.
    static func stopMocking() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        lock.withLock {
            _isMockingEnabled = false
            _requestHandler = nil
            _routedHandlers = [:]
            _recordedRequests = []
        }
    }

    /// Reset the mock state (for use between tests). Thread-safe.
    static func reset() {
        lock.withLock {
            _requestHandler = nil
            _recordedRequests = []
        }
    }

    /// Register a handler for a specific URL path prefix.
    /// Routed handlers have priority over the default requestHandler.
    /// - Parameters:
    ///   - prefix: URL path prefix to match (e.g., "/repos/test/repo")
    ///   - handler: Handler for matching requests
    static func registerHandler(
        forPathPrefix prefix: String,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) {
        lock.withLock {
            _routedHandlers[prefix] = handler
        }
    }

    /// Unregister a handler for a specific URL path prefix.
    static func unregisterHandler(forPathPrefix prefix: String) {
        lock.withLock {
            _routedHandlers.removeValue(forKey: prefix)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        // Only intercept if mocking is enabled
        return isMockingEnabled
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let resolvedRequest = Self.resolveRequestBody(request)
        Self.appendRequest(resolvedRequest)

        // First, try to find a routed handler based on URL path
        if let handler = Self.findRoutedHandler(for: resolvedRequest) {
            do {
                let (response, data) = try handler(resolvedRequest)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
            return
        }

        // Fall back to the default handler
        guard let handler = Self.getHandler() else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: 1, userInfo: [NSLocalizedDescriptionKey: "requestHandler not set"]))
            return
        }

        do {
            let (response, data) = try handler(resolvedRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    /// Find a routed handler for the given request.
    private static func findRoutedHandler(
        for request: URLRequest
    ) -> ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        guard let url = request.url, let path = url.path.isEmpty ? nil : url.path else {
            return nil
        }

        return lock.withLock {
            // Find the longest matching prefix
            var bestMatch: (prefix: String, handler: (URLRequest) throws -> (HTTPURLResponse, Data))?
            for (prefix, handler) in _routedHandlers {
                if path.hasPrefix(prefix) {
                    if bestMatch == nil || prefix.count > bestMatch!.prefix.count {
                        bestMatch = (prefix, handler)
                    }
                }
            }
            return bestMatch?.handler
        }
    }

    override func stopLoading() {}

    /// Append a request to the recorded list. Thread-safe.
    private static func appendRequest(_ request: URLRequest) {
        lock.withLock {
            _recordedRequests.append(request)
        }
    }

    /// Ensure httpBody is available even when the request was constructed with a body stream.
    private static func resolveRequestBody(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else {
            return request
        }

        guard let bodyData = readStream(stream) else {
            return request
        }

        var copy = request
        copy.httpBodyStream = nil
        copy.httpBody = bodyData
        return copy
    }

    /// Read the full contents of an InputStream into Data.
    private static func readStream(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)

        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read < 0 {
                return nil
            }
            if read == 0 {
                break
            }

            data.append(buffer, count: read)
        }

        return data
    }

    /// Get the handler. Thread-safe.
    private static func getHandler() -> ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        lock.withLock { _requestHandler }
    }
}

// MARK: - Test Helpers

extension MockURLProtocol {
    /// Create a URLSession configured to use MockURLProtocol.
    /// Note: Also requires startMocking() to be called for the protocol to intercept requests.
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
