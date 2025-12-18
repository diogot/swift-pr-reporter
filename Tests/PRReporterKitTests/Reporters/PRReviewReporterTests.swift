#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation
import Testing
@testable import PRReporterKit

// Tests for PRReviewReporter duplicate key handling and content merging.
// These tests verify that:
// 1. New content with no existing comments creates a new comment
// 2. New content with existing comments on the same line appends to the most recent
// 3. Duplicate content (already exists in any section) is skipped
// 4. Multiple existing comments on the same line don't crash (the original bug)

#if !os(Linux)
@Suite("PRReviewReporter Tests", .serialized)
struct PRReviewReporterTests {
    // Test identifier used for all tests
    let identifier = "test-reporter"

    // URL prefix for routing - all our tests use this repo
    let routePrefix = "/repos/test/repo"

    // MARK: - Test: New content with no existing comments creates new comment

    @Test("Creates new comment when no existing comments on line")
    func createsNewCommentWhenNoExisting() async throws {
        MockURLProtocol.ensureMockingEnabled()

        var createCommentCalled = false
        var createdBody: String?

        MockURLProtocol.registerHandler(forPathPrefix: routePrefix) { request in
            let url = request.url!.absoluteString

            // List files endpoint
            if url.contains("/pulls/1/files") {
                let files: [[String: Any]] = [[
                    "sha": "abc123",
                    "filename": "Sources/App.swift",
                    "status": "modified",
                    "additions": 10,
                    "deletions": 2,
                    "changes": 12,
                    "patch": "@@ -1,5 +1,10 @@\n context\n+added line\n context"
                ]]
                return try Self.jsonResponse(json: files, for: request)
            }

            // List review comments endpoint (returns empty - no existing comments)
            if url.contains("/pulls/1/comments") && request.httpMethod == "GET" {
                return try Self.jsonResponse(json: [] as [[String: Any]], for: request)
            }

            // Create review comment endpoint
            if url.contains("/pulls/1/comments") && request.httpMethod == "POST" {
                createCommentCalled = true
                if let body = request.httpBody,
                   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    createdBody = json["body"] as? String
                }
                let response: [String: Any] = [
                    "id": 100,
                    "body": createdBody ?? "",
                    "path": "Sources/App.swift",
                    "position": 2,
                    "line": 2,
                    "side": "RIGHT",
                    "commit_id": "sha123",
                    "html_url": "https://github.com/test/repo/pull/1#comment-100"
                ]
                return try Self.jsonResponse(json: response, for: request, statusCode: 201)
            }

            // Return 404 for unexpected requests
            return try Self.notFoundResponse(for: request)
        }

        defer { MockURLProtocol.unregisterHandler(forPathPrefix: routePrefix) }

        let context = GitHubContext(
            token: "test-token",
            repository: "test/repo",
            pullRequest: 1,
            commitSHA: "sha123"
        )

        let reporter = PRReviewReporter(
            context: context,
            identifier: identifier,
            outOfRangeStrategy: .dismiss,
            urlSession: MockURLProtocol.createMockSession()
        )

        let annotation = Annotation(
            path: "Sources/App.swift",
            line: 2,
            level: .warning,
            message: "Test warning message"
        )

        let result = try await reporter.report([annotation])

        #expect(createCommentCalled, "Should have called create comment API")
        #expect(result.annotationsPosted == 1)
        #expect(result.annotationsUpdated == 0)
        #expect(createdBody?.contains("Test warning message") == true)
    }

    // MARK: - Test: New content appends to existing comment on same line

    @Test("Appends new content to existing comment on same line")
    func appendsToExistingComment() async throws {
        MockURLProtocol.ensureMockingEnabled()

        var updateCommentCalled = false
        var updatedBody: String?
        var updatedCommentId: Int?

        let existingBody = CommentMarker.addMarker(
            to: ":warning: **Previous Warning**\n\nOld message",
            identifier: identifier
        )

        MockURLProtocol.registerHandler(forPathPrefix: routePrefix) { request in
            let url = request.url!.absoluteString

            // List files endpoint
            if url.contains("/pulls/1/files") {
                let files: [[String: Any]] = [[
                    "sha": "abc123",
                    "filename": "Sources/App.swift",
                    "status": "modified",
                    "additions": 10,
                    "deletions": 2,
                    "changes": 12,
                    "patch": "@@ -1,5 +1,10 @@\n context\n+added line\n context"
                ]]
                return try Self.jsonResponse(json: files, for: request)
            }

            // List review comments endpoint (returns one existing comment)
            if url.contains("/pulls/1/comments") && request.httpMethod == "GET" {
                let comments: [[String: Any]] = [[
                    "id": 200,
                    "body": existingBody,
                    "path": "Sources/App.swift",
                    "position": 2,
                    "line": 2,
                    "side": "RIGHT",
                    "commit_id": "sha123",
                    "html_url": "https://github.com/test/repo/pull/1#comment-200"
                ]]
                return try Self.jsonResponse(json: comments, for: request)
            }

            // Update review comment endpoint
            if url.contains("/pulls/comments/200") && request.httpMethod == "PATCH" {
                updateCommentCalled = true
                if let body = request.httpBody,
                   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    updatedBody = json["body"] as? String
                }
                updatedCommentId = 200
                let response: [String: Any] = [
                    "id": 200,
                    "body": updatedBody ?? "",
                    "path": "Sources/App.swift",
                    "position": 2,
                    "line": 2,
                    "side": "RIGHT",
                    "commit_id": "sha123",
                    "html_url": "https://github.com/test/repo/pull/1#comment-200"
                ]
                return try Self.jsonResponse(json: response, for: request)
            }

            // Return 404 for unexpected requests
            return try Self.notFoundResponse(for: request)
        }

        defer { MockURLProtocol.unregisterHandler(forPathPrefix: routePrefix) }

        let context = GitHubContext(
            token: "test-token",
            repository: "test/repo",
            pullRequest: 1,
            commitSHA: "sha123"
        )

        let reporter = PRReviewReporter(
            context: context,
            identifier: identifier,
            outOfRangeStrategy: .dismiss,
            urlSession: MockURLProtocol.createMockSession()
        )

        let annotation = Annotation(
            path: "Sources/App.swift",
            line: 2,
            level: .failure,
            message: "New error message"
        )

        let result = try await reporter.report([annotation])

        #expect(updateCommentCalled, "Should have called update comment API")
        #expect(updatedCommentId == 200, "Should update the existing comment")
        #expect(result.annotationsPosted == 0)
        #expect(result.annotationsUpdated == 1)

        // Verify the body contains both old and new content
        #expect(updatedBody?.contains("Old message") == true, "Should preserve old content")
        #expect(updatedBody?.contains("New error message") == true, "Should include new content")
        #expect(updatedBody?.contains("\n\n---\n\n") == true, "Should have separator between sections")
    }

    // MARK: - Test: Duplicate content is skipped

    @Test("Skips posting when content already exists in comment")
    func skipsDuplicateContent() async throws {
        MockURLProtocol.ensureMockingEnabled()

        var createOrUpdateCalled = false

        // The exact content that will be generated for the annotation
        let annotationContent = ":warning: Test warning message"
        let existingBody = CommentMarker.addMarker(to: annotationContent, identifier: identifier)

        MockURLProtocol.registerHandler(forPathPrefix: routePrefix) { request in
            let url = request.url!.absoluteString

            // List files endpoint
            if url.contains("/pulls/1/files") {
                let files: [[String: Any]] = [[
                    "sha": "abc123",
                    "filename": "Sources/App.swift",
                    "status": "modified",
                    "additions": 10,
                    "deletions": 2,
                    "changes": 12,
                    "patch": "@@ -1,5 +1,10 @@\n context\n+added line\n context"
                ]]
                return try Self.jsonResponse(json: files, for: request)
            }

            // List review comments endpoint (returns comment with same content)
            if url.contains("/pulls/1/comments") && request.httpMethod == "GET" {
                let comments: [[String: Any]] = [[
                    "id": 300,
                    "body": existingBody,
                    "path": "Sources/App.swift",
                    "position": 2,
                    "line": 2,
                    "side": "RIGHT",
                    "commit_id": "sha123",
                    "html_url": "https://github.com/test/repo/pull/1#comment-300"
                ]]
                return try Self.jsonResponse(json: comments, for: request)
            }

            // Create or update should NOT be called
            if request.httpMethod == "POST" || request.httpMethod == "PATCH" {
                createOrUpdateCalled = true
            }

            // Return 404 for unexpected requests
            return try Self.notFoundResponse(for: request)
        }

        defer { MockURLProtocol.unregisterHandler(forPathPrefix: routePrefix) }

        let context = GitHubContext(
            token: "test-token",
            repository: "test/repo",
            pullRequest: 1,
            commitSHA: "sha123"
        )

        let reporter = PRReviewReporter(
            context: context,
            identifier: identifier,
            outOfRangeStrategy: .dismiss,
            urlSession: MockURLProtocol.createMockSession()
        )

        let annotation = Annotation(
            path: "Sources/App.swift",
            line: 2,
            level: .warning,
            message: "Test warning message"
        )

        let result = try await reporter.report([annotation])

        #expect(!createOrUpdateCalled, "Should NOT call create or update when content is duplicate")
        #expect(result.annotationsPosted == 0)
        #expect(result.annotationsUpdated == 0)
    }

    // MARK: - Test: Duplicate content in merged comment is skipped

    @Test("Skips posting when content exists as section in merged comment")
    func skipsDuplicateContentInMergedComment() async throws {
        MockURLProtocol.ensureMockingEnabled()

        var createOrUpdateCalled = false

        // Existing comment with multiple sections (previously merged)
        let section1 = ":x: **Error**\n\nFirst error message"
        let section2 = ":warning: Test warning message"
        let mergedContent = section1 + "\n\n---\n\n" + section2
        let existingBody = CommentMarker.addMarker(to: mergedContent, identifier: identifier)

        MockURLProtocol.registerHandler(forPathPrefix: routePrefix) { request in
            let url = request.url!.absoluteString

            // List files endpoint
            if url.contains("/pulls/1/files") {
                let files: [[String: Any]] = [[
                    "sha": "abc123",
                    "filename": "Sources/App.swift",
                    "status": "modified",
                    "additions": 10,
                    "deletions": 2,
                    "changes": 12,
                    "patch": "@@ -1,5 +1,10 @@\n context\n+added line\n context"
                ]]
                return try Self.jsonResponse(json: files, for: request)
            }

            // List review comments endpoint
            if url.contains("/pulls/1/comments") && request.httpMethod == "GET" {
                let comments: [[String: Any]] = [[
                    "id": 400,
                    "body": existingBody,
                    "path": "Sources/App.swift",
                    "position": 2,
                    "line": 2,
                    "side": "RIGHT",
                    "commit_id": "sha123",
                    "html_url": "https://github.com/test/repo/pull/1#comment-400"
                ]]
                return try Self.jsonResponse(json: comments, for: request)
            }

            // Create or update should NOT be called
            if request.httpMethod == "POST" || request.httpMethod == "PATCH" {
                createOrUpdateCalled = true
            }

            // Return 404 for unexpected requests
            return try Self.notFoundResponse(for: request)
        }

        defer { MockURLProtocol.unregisterHandler(forPathPrefix: routePrefix) }

        let context = GitHubContext(
            token: "test-token",
            repository: "test/repo",
            pullRequest: 1,
            commitSHA: "sha123"
        )

        let reporter = PRReviewReporter(
            context: context,
            identifier: identifier,
            outOfRangeStrategy: .dismiss,
            urlSession: MockURLProtocol.createMockSession()
        )

        // This annotation's content matches section2 in the merged comment
        let annotation = Annotation(
            path: "Sources/App.swift",
            line: 2,
            level: .warning,
            message: "Test warning message"
        )

        let result = try await reporter.report([annotation])

        #expect(!createOrUpdateCalled, "Should NOT call create or update when content exists in merged comment")
        #expect(result.annotationsPosted == 0)
        #expect(result.annotationsUpdated == 0)
    }

    // MARK: - Test: Multiple comments on same line don't crash (original bug)

    @Test("Handles multiple existing comments on same line without crashing")
    func handlesMultipleCommentsOnSameLine() async throws {
        MockURLProtocol.ensureMockingEnabled()

        var updateCommentCalled = false
        var updatedCommentId: Int?

        let body1 = CommentMarker.addMarker(to: ":warning: First warning", identifier: identifier)
        let body2 = CommentMarker.addMarker(to: ":x: Second error", identifier: identifier)

        MockURLProtocol.registerHandler(forPathPrefix: routePrefix) { request in
            let url = request.url!.absoluteString

            // List files endpoint
            if url.contains("/pulls/1/files") {
                let files: [[String: Any]] = [[
                    "sha": "abc123",
                    "filename": "Sources/App.swift",
                    "status": "modified",
                    "additions": 10,
                    "deletions": 2,
                    "changes": 12,
                    "patch": "@@ -1,5 +1,10 @@\n context\n+added line\n context"
                ]]
                return try Self.jsonResponse(json: files, for: request)
            }

            // List review comments endpoint (returns TWO comments on same line - the bug scenario)
            if url.contains("/pulls/1/comments") && request.httpMethod == "GET" {
                let comments: [[String: Any]] = [
                    [
                        "id": 100,  // Lower ID = older comment
                        "body": body1,
                        "path": "Sources/App.swift",
                        "position": 2,
                        "line": 2,
                        "side": "RIGHT",
                        "commit_id": "sha123",
                        "html_url": "https://github.com/test/repo/pull/1#comment-100"
                    ],
                    [
                        "id": 500,  // Higher ID = newer comment
                        "body": body2,
                        "path": "Sources/App.swift",
                        "position": 2,
                        "line": 2,
                        "side": "RIGHT",
                        "commit_id": "sha123",
                        "html_url": "https://github.com/test/repo/pull/1#comment-500"
                    ]
                ]
                return try Self.jsonResponse(json: comments, for: request)
            }

            // Update review comment endpoint - should update the MOST RECENT (id: 500)
            if url.contains("/pulls/comments/") && request.httpMethod == "PATCH" {
                updateCommentCalled = true
                // Extract comment ID from URL
                if let idString = url.components(separatedBy: "/pulls/comments/").last,
                   let id = Int(idString) {
                    updatedCommentId = id
                }
                let response: [String: Any] = [
                    "id": updatedCommentId ?? 0,
                    "body": "updated",
                    "path": "Sources/App.swift",
                    "position": 2,
                    "line": 2,
                    "side": "RIGHT",
                    "commit_id": "sha123",
                    "html_url": "https://github.com/test/repo/pull/1#comment-\(updatedCommentId ?? 0)"
                ]
                return try Self.jsonResponse(json: response, for: request)
            }

            // Return 404 for unexpected requests
            return try Self.notFoundResponse(for: request)
        }

        defer { MockURLProtocol.unregisterHandler(forPathPrefix: routePrefix) }

        let context = GitHubContext(
            token: "test-token",
            repository: "test/repo",
            pullRequest: 1,
            commitSHA: "sha123"
        )

        let reporter = PRReviewReporter(
            context: context,
            identifier: identifier,
            outOfRangeStrategy: .dismiss,
            urlSession: MockURLProtocol.createMockSession()
        )

        let annotation = Annotation(
            path: "Sources/App.swift",
            line: 2,
            level: .notice,
            message: "New notice message"
        )

        // This should NOT crash (the original bug was a fatal error here)
        let result = try await reporter.report([annotation])

        #expect(updateCommentCalled, "Should have called update comment API")
        #expect(updatedCommentId == 500, "Should update the most recent comment (highest ID)")
        #expect(result.annotationsPosted == 0)
        #expect(result.annotationsUpdated == 1)
    }

    // MARK: - Test: Duplicate filenames in PR files don't crash

    @Test("Handles duplicate filenames in PR files without crashing")
    func handlesDuplicateFilenames() async throws {
        MockURLProtocol.ensureMockingEnabled()

        var createCommentCalled = false

        MockURLProtocol.registerHandler(forPathPrefix: routePrefix) { request in
            let url = request.url!.absoluteString

            // List files endpoint - returns duplicate filenames (edge case)
            if url.contains("/pulls/1/files") {
                // Use a proper patch format that includes line 2
                let patch = """
                    @@ -1,3 +1,4 @@
                     line1
                    +new line at position 2
                     line3
                     line4
                    """
                let files: [[String: Any]] = [
                    [
                        "sha": "abc123",
                        "filename": "Sources/App.swift",
                        "status": "modified",
                        "additions": 1,
                        "deletions": 0,
                        "changes": 1,
                        "patch": patch
                    ],
                    [
                        "sha": "def456",
                        "filename": "Sources/App.swift",  // Same filename (edge case)
                        "status": "modified",
                        "additions": 1,
                        "deletions": 0,
                        "changes": 1,
                        "patch": patch
                    ]
                ]
                return try Self.jsonResponse(json: files, for: request)
            }

            // List review comments endpoint (no existing)
            if url.contains("/pulls/1/comments") && request.httpMethod == "GET" {
                return try Self.jsonResponse(json: [] as [[String: Any]], for: request)
            }

            // Create review comment endpoint
            if url.contains("/pulls/1/comments") && request.httpMethod == "POST" {
                createCommentCalled = true
                let response: [String: Any] = [
                    "id": 600,
                    "body": "test",
                    "path": "Sources/App.swift",
                    "position": 2,
                    "line": 2,
                    "side": "RIGHT",
                    "commit_id": "sha123",
                    "html_url": "https://github.com/test/repo/pull/1#comment-600"
                ]
                return try Self.jsonResponse(json: response, for: request, statusCode: 201)
            }

            // Return 404 for unexpected requests
            return try Self.notFoundResponse(for: request)
        }

        defer { MockURLProtocol.unregisterHandler(forPathPrefix: routePrefix) }

        let context = GitHubContext(
            token: "test-token",
            repository: "test/repo",
            pullRequest: 1,
            commitSHA: "sha123"
        )

        let reporter = PRReviewReporter(
            context: context,
            identifier: identifier,
            outOfRangeStrategy: .dismiss,
            urlSession: MockURLProtocol.createMockSession()
        )

        let annotation = Annotation(
            path: "Sources/App.swift",
            line: 2,
            level: .warning,
            message: "Test message"
        )

        // This should NOT crash (potential bug with Dictionary(uniqueKeysWithValues:))
        let result = try await reporter.report([annotation])

        #expect(createCommentCalled, "Should have created a comment")
        #expect(result.annotationsPosted == 1)
    }

    // MARK: - Helpers

    private static func jsonResponse(
        json: Any,
        for request: URLRequest,
        statusCode: Int = 200
    ) throws -> (HTTPURLResponse, Data) {
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, data)
    }

    private static func notFoundResponse(
        for request: URLRequest
    ) throws -> (HTTPURLResponse, Data) {
        let json: [String: Any] = ["message": "Not Found"]
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 404,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, data)
    }
}
#endif
