import Foundation

/// Utility for mapping line numbers to positions in unified diffs.
public struct DiffMapper: Sendable {
    /// Represents a hunk in a unified diff.
    public struct Hunk: Sendable {
        public let oldStart: Int
        public let oldCount: Int
        public let newStart: Int
        public let newCount: Int
        public let startPosition: Int // Position in diff where this hunk starts
        public let lines: [DiffLine]
    }

    /// Represents a line in a diff.
    public struct DiffLine: Sendable {
        public enum Kind: Sendable {
            case context
            case addition
            case deletion
            case header
        }

        public let kind: Kind
        public let content: String
        public let position: Int // 1-based position in the diff
        public let oldLineNumber: Int? // Line number in old file
        public let newLineNumber: Int? // Line number in new file
    }

    /// Result of mapping a line number to a diff position.
    public struct MappingResult: Sendable {
        public let position: Int
        public let side: DiffSide
    }

    /// Parse a unified diff patch into hunks.
    /// - Parameter patch: The unified diff patch string.
    /// - Returns: Array of parsed hunks.
    public static func parseHunks(from patch: String) -> [Hunk] {
        var hunks: [Hunk] = []
        let lines = patch.components(separatedBy: "\n")
        var position = 0
        var currentHunkLines: [DiffLine] = []
        var currentHunkHeader: (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)?
        var hunkStartPosition = 0
        var oldLine = 0
        var newLine = 0

        for line in lines {
            position += 1

            // Parse hunk header: @@ -oldStart,oldCount +newStart,newCount @@
            if line.hasPrefix("@@") {
                // Save previous hunk if exists
                if let header = currentHunkHeader {
                    hunks.append(Hunk(
                        oldStart: header.oldStart,
                        oldCount: header.oldCount,
                        newStart: header.newStart,
                        newCount: header.newCount,
                        startPosition: hunkStartPosition,
                        lines: currentHunkLines
                    ))
                }

                // Parse new hunk header
                if let parsed = parseHunkHeader(line) {
                    currentHunkHeader = parsed
                    hunkStartPosition = position
                    currentHunkLines = []
                    oldLine = parsed.oldStart
                    newLine = parsed.newStart

                    // Add the header line itself
                    currentHunkLines.append(DiffLine(
                        kind: .header,
                        content: line,
                        position: position,
                        oldLineNumber: nil,
                        newLineNumber: nil
                    ))
                }
                continue
            }

            guard currentHunkHeader != nil else { continue }

            // Determine line kind
            let kind: DiffLine.Kind
            var lineOldNum: Int?
            var lineNewNum: Int?

            if line.hasPrefix("+") {
                kind = .addition
                lineNewNum = newLine
                newLine += 1
            } else if line.hasPrefix("-") {
                kind = .deletion
                lineOldNum = oldLine
                oldLine += 1
            } else if line.hasPrefix(" ") || line.isEmpty {
                kind = .context
                lineOldNum = oldLine
                lineNewNum = newLine
                oldLine += 1
                newLine += 1
            } else {
                // Unknown line type, treat as context
                kind = .context
                lineOldNum = oldLine
                lineNewNum = newLine
                oldLine += 1
                newLine += 1
            }

            currentHunkLines.append(DiffLine(
                kind: kind,
                content: line,
                position: position,
                oldLineNumber: lineOldNum,
                newLineNumber: lineNewNum
            ))
        }

        // Save last hunk
        if let header = currentHunkHeader {
            hunks.append(Hunk(
                oldStart: header.oldStart,
                oldCount: header.oldCount,
                newStart: header.newStart,
                newCount: header.newCount,
                startPosition: hunkStartPosition,
                lines: currentHunkLines
            ))
        }

        return hunks
    }

    /// Parse a hunk header line.
    /// - Parameter line: The hunk header line (e.g., "@@ -1,5 +1,7 @@").
    /// - Returns: Tuple of (oldStart, oldCount, newStart, newCount) or nil if parsing fails.
    public static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        // Pattern: @@ -oldStart,oldCount +newStart,newCount @@
        // Or: @@ -oldStart +newStart @@ (count defaults to 1)
        let pattern = #"@@\s*-(\d+)(?:,(\d+))?\s*\+(\d+)(?:,(\d+))?\s*@@"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range) else {
            return nil
        }

        guard let oldStartRange = Range(match.range(at: 1), in: line),
              let oldStart = Int(line[oldStartRange]) else {
            return nil
        }

        let oldCount: Int
        if let oldCountRange = Range(match.range(at: 2), in: line),
           let count = Int(line[oldCountRange]) {
            oldCount = count
        } else {
            oldCount = 1
        }

        guard let newStartRange = Range(match.range(at: 3), in: line),
              let newStart = Int(line[newStartRange]) else {
            return nil
        }

        let newCount: Int
        if let newCountRange = Range(match.range(at: 4), in: line),
           let count = Int(line[newCountRange]) {
            newCount = count
        } else {
            newCount = 1
        }

        return (oldStart, oldCount, newStart, newCount)
    }

    /// Map a line number to a position in the diff.
    /// - Parameters:
    ///   - line: The line number in the new file.
    ///   - patch: The unified diff patch.
    /// - Returns: The diff position, or nil if the line is not in the diff.
    public static func position(forLine line: Int, inPatch patch: String) -> Int? {
        let hunks = parseHunks(from: patch)

        for hunk in hunks {
            for diffLine in hunk.lines {
                // We can only comment on additions and context lines (not deletions)
                if diffLine.kind == .deletion || diffLine.kind == .header {
                    continue
                }

                if diffLine.newLineNumber == line {
                    return diffLine.position
                }
            }
        }

        return nil
    }

    /// Map a line number to a position in the diff (returns MappingResult).
    /// - Parameters:
    ///   - line: The line number in the file.
    ///   - patch: The unified diff patch.
    ///   - isOldFile: Whether we're looking for a line in the old file (deletion).
    /// - Returns: MappingResult with position and side, or nil if not found.
    public static func mapLine(_ line: Int, inPatch patch: String, isOldFile: Bool = false) -> MappingResult? {
        let hunks = parseHunks(from: patch)

        for hunk in hunks {
            for diffLine in hunk.lines {
                if diffLine.kind == .header {
                    continue
                }

                if isOldFile {
                    if diffLine.oldLineNumber == line && (diffLine.kind == .deletion || diffLine.kind == .context) {
                        return MappingResult(position: diffLine.position, side: .left)
                    }
                } else {
                    if diffLine.newLineNumber == line && (diffLine.kind == .addition || diffLine.kind == .context) {
                        return MappingResult(position: diffLine.position, side: .right)
                    }
                }
            }
        }

        return nil
    }

    /// Check if a line is within the diff range (even if not directly commentable).
    /// - Parameters:
    ///   - line: The line number to check.
    ///   - patch: The unified diff patch.
    /// - Returns: True if the line falls within any hunk's range.
    public static func isLineInDiff(_ line: Int, patch: String) -> Bool {
        let hunks = parseHunks(from: patch)

        for hunk in hunks {
            let rangeEnd = hunk.newStart + hunk.newCount - 1
            if line >= hunk.newStart && line <= rangeEnd {
                return true
            }
        }

        return false
    }

    /// Find the resolved path for an annotation, handling file renames.
    /// - Parameters:
    ///   - annotation: The annotation to resolve.
    ///   - files: List of files from the PR.
    /// - Returns: The resolved path, or nil if file not found.
    public static func resolvedPath(for annotation: Annotation, files: [PullRequestFile]) -> String? {
        // First try exact match on filename
        if files.contains(where: { $0.filename == annotation.path }) {
            return annotation.path
        }

        // Check for renamed files (match by previous filename)
        for file in files {
            if file.previousFilename == annotation.path {
                return file.filename
            }
        }

        // Check for partial matches (in case of path differences)
        let annotationName = (annotation.path as NSString).lastPathComponent
        if let match = files.first(where: { ($0.filename as NSString).lastPathComponent == annotationName }) {
            return match.filename
        }

        return nil
    }
}
