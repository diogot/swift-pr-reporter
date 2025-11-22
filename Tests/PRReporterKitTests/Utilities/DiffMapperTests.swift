import Testing
@testable import PRReporterKit

@Suite("DiffMapper Tests")
struct DiffMapperTests {
    let simpleAdditionPatch = """
        @@ -1,5 +1,7 @@
         import Foundation

        +// New comment added
        +
         class MyClass {
        -    func hello() {}
        +    func hello() {
        +        print("Hello")
        +    }
         }
        """

    let multipleHunksPatch = """
        @@ -1,4 +1,5 @@
         import Foundation
        +import UIKit

         class MyClass {
             var name: String
        @@ -10,6 +11,9 @@ class MyClass {
                 self.name = name
             }

        +    func greet() {
        +        print("Hello, \\(name)")
        +    }
         }

         // End of file
        """

    @Test("Parse hunk header with counts")
    func parseHunkHeaderWithCounts() {
        let result = DiffMapper.parseHunkHeader("@@ -1,5 +1,7 @@")

        #expect(result != nil)
        #expect(result?.oldStart == 1)
        #expect(result?.oldCount == 5)
        #expect(result?.newStart == 1)
        #expect(result?.newCount == 7)
    }

    @Test("Parse hunk header without counts defaults to 1")
    func parseHunkHeaderWithoutCounts() {
        let result = DiffMapper.parseHunkHeader("@@ -5 +10 @@")

        #expect(result != nil)
        #expect(result?.oldStart == 5)
        #expect(result?.oldCount == 1)
        #expect(result?.newStart == 10)
        #expect(result?.newCount == 1)
    }

    @Test("Parse hunk header with function context")
    func parseHunkHeaderWithContext() {
        let result = DiffMapper.parseHunkHeader("@@ -10,6 +11,9 @@ class MyClass {")

        #expect(result != nil)
        #expect(result?.oldStart == 10)
        #expect(result?.oldCount == 6)
        #expect(result?.newStart == 11)
        #expect(result?.newCount == 9)
    }

    @Test("Parse hunks from simple patch")
    func parseHunksSimple() {
        let hunks = DiffMapper.parseHunks(from: simpleAdditionPatch)

        #expect(hunks.count == 1)
        #expect(hunks[0].newStart == 1)
        #expect(hunks[0].newCount == 7)
    }

    @Test("Parse hunks from multiple hunk patch")
    func parseHunksMultiple() {
        let hunks = DiffMapper.parseHunks(from: multipleHunksPatch)

        #expect(hunks.count == 2)
        #expect(hunks[0].newStart == 1)
        #expect(hunks[1].newStart == 11)
    }

    @Test("Find position for added line")
    func positionForAddedLine() {
        // Line 3 in the new file is the "// New comment added" line
        let position = DiffMapper.position(forLine: 3, inPatch: simpleAdditionPatch)

        #expect(position != nil)
        #expect(position! > 0)
    }

    @Test("Find position for context line")
    func positionForContextLine() {
        // Line 1 "import Foundation" is a context line
        let position = DiffMapper.position(forLine: 1, inPatch: simpleAdditionPatch)

        #expect(position != nil)
    }

    @Test("Returns nil for line outside diff")
    func positionForLineOutsideDiff() {
        // Line 100 is definitely not in the diff
        let position = DiffMapper.position(forLine: 100, inPatch: simpleAdditionPatch)

        #expect(position == nil)
    }

    @Test("Check if line is in diff")
    func isLineInDiff() {
        #expect(DiffMapper.isLineInDiff(1, patch: simpleAdditionPatch))
        #expect(DiffMapper.isLineInDiff(3, patch: simpleAdditionPatch))
        #expect(!DiffMapper.isLineInDiff(100, patch: simpleAdditionPatch))
    }

    @Test("Map line with side information")
    func mapLineWithSide() {
        let result = DiffMapper.mapLine(3, inPatch: simpleAdditionPatch)

        #expect(result != nil)
        #expect(result?.side == .right)
    }

    @Test("Resolve path for exact match")
    func resolvePathExact() {
        let files = [
            PullRequestFile(
                sha: "abc",
                filename: "Sources/App/File.swift",
                status: "modified",
                additions: 5,
                deletions: 2,
                changes: 7,
                patch: nil,
                previousFilename: nil
            )
        ]

        let annotation = Annotation(
            path: "Sources/App/File.swift",
            line: 10,
            level: .warning,
            message: "test"
        )

        let resolved = DiffMapper.resolvedPath(for: annotation, files: files)
        #expect(resolved == "Sources/App/File.swift")
    }

    @Test("Resolve path for renamed file")
    func resolvePathRenamed() {
        let files = [
            PullRequestFile(
                sha: "abc",
                filename: "Sources/App/NewName.swift",
                status: "renamed",
                additions: 0,
                deletions: 0,
                changes: 0,
                patch: nil,
                previousFilename: "Sources/App/OldName.swift"
            )
        ]

        let annotation = Annotation(
            path: "Sources/App/OldName.swift",
            line: 10,
            level: .warning,
            message: "test"
        )

        let resolved = DiffMapper.resolvedPath(for: annotation, files: files)
        #expect(resolved == "Sources/App/NewName.swift")
    }
}
