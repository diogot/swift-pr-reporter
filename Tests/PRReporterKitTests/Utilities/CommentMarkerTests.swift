import Testing
@testable import PRReporterKit

@Suite("CommentMarker Tests")
struct CommentMarkerTests {
    @Test("Generate marker without hash")
    func generateWithoutHash() {
        let marker = CommentMarker.generate(identifier: "test-id")
        #expect(marker == "<!-- pr-reporter:test-id -->")
    }

    @Test("Generate marker with hash")
    func generateWithHash() {
        let marker = CommentMarker.generate(identifier: "test-id", contentHash: "abc123")
        #expect(marker == "<!-- pr-reporter:test-id:abc123 -->")
    }

    @Test("Parse marker without hash")
    func parseWithoutHash() {
        let body = "<!-- pr-reporter:my-identifier -->\nSome content"
        let result = CommentMarker.parse(from: body)

        #expect(result != nil)
        #expect(result?.identifier == "my-identifier")
        #expect(result?.contentHash == nil)
    }

    @Test("Parse marker with hash")
    func parseWithHash() {
        let body = "<!-- pr-reporter:my-identifier:xyz789 -->\nSome content"
        let result = CommentMarker.parse(from: body)

        #expect(result != nil)
        #expect(result?.identifier == "my-identifier")
        #expect(result?.contentHash == "xyz789")
    }

    @Test("Parse returns nil for no marker")
    func parseNoMarker() {
        let body = "Just a regular comment"
        let result = CommentMarker.parse(from: body)
        #expect(result == nil)
    }

    @Test("Contains identifier returns true when present")
    func containsIdentifierTrue() {
        let body = "<!-- pr-reporter:swiftlint -->\n## Results"
        #expect(CommentMarker.contains(identifier: "swiftlint", in: body))
    }

    @Test("Contains identifier returns false when not present")
    func containsIdentifierFalse() {
        let body = "<!-- pr-reporter:other-id -->\n## Results"
        #expect(!CommentMarker.contains(identifier: "swiftlint", in: body))
    }

    @Test("Hash generates consistent output")
    func hashConsistent() {
        let content = "Test content here"
        let hash1 = CommentMarker.hash(content: content)
        let hash2 = CommentMarker.hash(content: content)

        #expect(hash1 == hash2)
        #expect(hash1.count == 8) // 8 hex characters
    }

    @Test("Hash differs for different content")
    func hashDiffers() {
        let hash1 = CommentMarker.hash(content: "Content A")
        let hash2 = CommentMarker.hash(content: "Content B")

        #expect(hash1 != hash2)
    }

    @Test("Hash is deterministic across calls (FNV-1a)")
    func hashDeterministic() {
        // Verify that hashing the same content always produces the same result.
        // This is critical for cross-run change detection via HTML comment markers.
        let content = "## Build Results\n- 1 warning\n- 0 errors"
        let expectedHash = CommentMarker.hash(content: content)

        // Multiple calls must return the exact same value
        for _ in 0..<100 {
            #expect(CommentMarker.hash(content: content) == expectedHash)
        }

        // A marker generated with this hash must be parseable back to the same hash
        let marker = CommentMarker.generate(identifier: "test", contentHash: expectedHash)
        let parsed = CommentMarker.parse(from: marker)
        #expect(parsed?.contentHash == expectedHash)
    }

    @Test("Add marker to body")
    func addMarker() {
        let body = "## Build Results\n\n- 1 error"
        let result = CommentMarker.addMarker(to: body, identifier: "build")

        #expect(result.hasPrefix("<!-- pr-reporter:build:"))
        #expect(result.contains("## Build Results"))
    }

    @Test("Remove marker from body")
    func removeMarker() {
        let body = "<!-- pr-reporter:test:abc -->\n## Content"
        let result = CommentMarker.removeMarker(from: body)

        #expect(!result.contains("pr-reporter"))
        #expect(result.contains("## Content"))
    }
}
