// PRReporterKit - A pure Swift library for posting automated feedback to GitHub PRs
//
// This module provides reporters for different GitHub API endpoints:
// - CheckRunReporter: Creates check run annotations (best for build errors)
// - PRCommentReporter: Posts summary comments on PRs
// - PRReviewReporter: Posts inline review comments on specific lines
//
// All public types are automatically available when importing PRReporterKit.
//
// Example usage:
//
//     import PRReporterKit
//
//     let context = try GitHubContext.fromEnvironment()
//     let reporter = CheckRunReporter(
//         context: context,
//         name: "Build",
//         identifier: "xcode-build"
//     )
//
//     let result = try await reporter.report([
//         Annotation(
//             path: "Sources/App/File.swift",
//             line: 42,
//             level: .warning,
//             message: "Variable 'foo' was never used"
//         )
//     ])
