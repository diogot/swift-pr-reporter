import Testing
@testable import PRReporterKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

// Note: These tests use MockURLProtocol which doesn't work reliably on Linux
// due to FoundationNetworking limitations. The tests are conditionally disabled on Linux.
// Tests are run serially because they share static state in MockURLProtocol.
#if !os(Linux)
@Suite("GitHubAPI Tests", .serialized)
struct GitHubAPITests {
    @Test("GET request includes authorization header")
    func getIncludesAuth() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.setupSuccessResponse(json: ["result": "ok"])

        let session = MockURLProtocol.createMockSession()
        let api = GitHubAPI(
            token: "test-token-123",
            urlSession: session
        )

        let _: [String: String] = try await api.get("/test")

        let request = try #require(MockURLProtocol.recordedRequests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-123")
    }

    @Test("GET request includes correct headers")
    func getIncludesHeaders() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.setupSuccessResponse(json: ["result": "ok"])

        let session = MockURLProtocol.createMockSession()
        let api = GitHubAPI(token: "token", urlSession: session)

        let _: [String: String] = try await api.get("/test")

        let request = try #require(MockURLProtocol.recordedRequests.first)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }

    @Test("GET request with query parameters")
    func getWithQueryParams() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.setupSuccessResponse(json: ["result": "ok"])

        let session = MockURLProtocol.createMockSession()
        let api = GitHubAPI(token: "token", urlSession: session)

        let _: [String: String] = try await api.get("/test", query: ["page": "2", "per_page": "100"])

        let request = try #require(MockURLProtocol.recordedRequests.first)
        let url = try #require(request.url).absoluteString
        #expect(url.contains("page=2"))
        #expect(url.contains("per_page=100"))
    }

    @Test("POST request sends JSON body")
    func postSendsBody() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.setupSuccessResponse(json: ["id": 123])

        let session = MockURLProtocol.createMockSession()
        let api = GitHubAPI(token: "token", urlSession: session)

        struct TestBody: Encodable {
            let name: String
            let value: Int
        }

        let body = TestBody(name: "test", value: 42)
        let _: [String: Int] = try await api.post("/test", body: body)

        let request = try #require(MockURLProtocol.recordedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let sentBody = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: sentBody) as? [String: Any]
        #expect(json?["name"] as? String == "test")
        #expect(json?["value"] as? Int == 42)
    }

    @Test("PATCH request uses correct method")
    func patchMethod() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.setupSuccessResponse(json: ["updated": true])

        let session = MockURLProtocol.createMockSession()
        let api = GitHubAPI(token: "token", urlSession: session)

        struct UpdateBody: Encodable {
            let status: String
        }

        let _: [String: Bool] = try await api.patch("/test/1", body: UpdateBody(status: "completed"))

        let request = try #require(MockURLProtocol.recordedRequests.first)
        #expect(request.httpMethod == "PATCH")
    }

    @Test("DELETE request uses correct method")
    func deleteMethod() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 204,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Data())
        }

        let session = MockURLProtocol.createMockSession()
        let api = GitHubAPI(token: "token", urlSession: session)

        try await api.delete("/test/1")

        let request = try #require(MockURLProtocol.recordedRequests.first)
        #expect(request.httpMethod == "DELETE")
    }

    @Test("API error is thrown for 4xx responses")
    func apiErrorFor4xx() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.setupErrorResponse(statusCode: 404, message: "Not Found")

        let session = MockURLProtocol.createMockSession()
        let api = GitHubAPI(token: "token", urlSession: session)

        await #expect(throws: GitHubAPIError.self) {
            let _: [String: String] = try await api.get("/nonexistent")
        }
    }
}
#endif
