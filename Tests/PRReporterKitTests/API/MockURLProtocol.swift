#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

/// A mock URL protocol for testing network requests without making real HTTP calls.
final class MockURLProtocol: URLProtocol {
    /// Handler for incoming requests. Set this before making requests.
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// Recorded requests for verification.
    nonisolated(unsafe) static var recordedRequests: [URLRequest] = []

    /// Reset the mock state.
    static func reset() {
        requestHandler = nil
        recordedRequests = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        MockURLProtocol.recordedRequests.append(request)

        guard let handler = MockURLProtocol.requestHandler else {
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
