# PRReporterKit

A pure Swift library for posting automated feedback to GitHub pull requests. Surface build errors, warnings, and informational messages directly in your PR diff with support for updating and deleting on re-runs.

## Features

- **Native Swift** - No Ruby, Node.js, or other runtime dependencies
- **Zero external dependencies** - Pure Swift with Foundation only
- **Multiple reporting strategies** - Check run annotations, PR comments, and inline review comments
- **Smart comment tracking** - Updates existing comments on re-runs instead of creating duplicates
- **Swift 6 concurrency** - Full Sendable conformance and actor-based API client
- **GitHub Actions integration** - Auto-detects context from environment variables

## Requirements

- Swift 6.2+
- macOS 13+ or Linux (Ubuntu 22.04+)
- GitHub Actions environment (or manually provided context)

## Installation

### Swift Package Manager

Add PRReporterKit to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/diogot/swift-pr-reporter.git", from: "1.0.0")
]
```

Then add it to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: ["PRReporterKit"]
)
```

## Quick Start

```swift
import PRReporterKit

// Auto-detect context from GitHub Actions environment
let context = try GitHubContext.fromEnvironment()

// Create a check run reporter
let reporter = CheckRunReporter(
    context: context,
    name: "Xcode Build",
    identifier: "xcode-build"
)

// Report annotations
let result = try await reporter.report([
    Annotation(
        path: "Sources/MyApp/ViewController.swift",
        line: 42,
        level: .warning,
        message: "Variable 'foo' was never used"
    )
])

// Post a summary
try await reporter.postSummary("""
## Build Results
- \(result.annotationsPosted) warnings posted
""")
```

## Reporters

PRReporterKit provides three different reporters for different use cases:

### CheckRunReporter

Posts annotations via the GitHub Checks API. Annotations appear in the Checks tab and inline in the diff.

```swift
let reporter = CheckRunReporter(
    context: context,
    name: "SwiftLint",      // Display name in GitHub
    identifier: "swiftlint" // Unique identifier for tracking
)

try await reporter.report([
    Annotation(
        path: "Sources/App/File.swift",
        line: 10,
        level: .warning,
        message: "Line should be 120 characters or less"
    )
])
```

**Best for:** Build errors, linter warnings, test failures

### PRCommentReporter

Posts summary comments on the pull request. Supports updating existing comments on re-runs.

```swift
let reporter = PRCommentReporter(
    context: context,
    identifier: "build-summary",
    commentMode: .update  // Updates existing comment instead of creating new
)

try await reporter.postSummary("""
## Build Results

| Metric | Value |
|--------|-------|
| Errors | 0 |
| Warnings | 5 |
| Duration | 2m 30s |
""")
```

**Best for:** Build summaries, coverage reports, release notes

### PRReviewReporter

Posts inline review comments on specific lines in the diff. Annotations outside the diff can be handled via configurable strategies.

```swift
let reporter = PRReviewReporter(
    context: context,
    identifier: "code-review",
    outOfRangeStrategy: .fallbackToComment  // Default: post out-of-diff annotations as PR comment
)

try await reporter.report(annotations)
```

**Best for:** Code review feedback, inline suggestions

## Annotation Levels

```swift
public enum Level {
    case notice   // Informational
    case warning  // Warning (yellow)
    case failure  // Error (red)
}
```

## GitHub Actions Setup

### Required Permissions

Add the following permissions to your workflow:

```yaml
permissions:
  checks: write        # For CheckRunReporter
  pull-requests: write # For PRReviewReporter, PRCommentReporter
```

### Example Workflow

```yaml
name: Build & Report
on:
  pull_request:
    types: [opened, synchronize]

permissions:
  checks: write
  pull-requests: write

jobs:
  build:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build and Report
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: swift run your-reporter-tool
```

### Environment Variables

PRReporterKit automatically reads these GitHub Actions environment variables:

| Variable | Description |
|----------|-------------|
| `GITHUB_TOKEN` | Authentication token |
| `GITHUB_REPOSITORY` | Owner/repo format |
| `GITHUB_SHA` | Commit SHA |
| `GITHUB_EVENT_PATH` | Path to event JSON |
| `GITHUB_EVENT_NAME` | Event type (pull_request, push, etc.) |

## API Reference

### Annotation

```swift
Annotation(
    path: String,           // File path relative to repo root
    line: Int,              // Line number
    endLine: Int? = nil,    // End line for multi-line
    column: Int? = nil,     // Column number
    level: Level,           // .notice, .warning, .failure
    message: String,        // The message to display
    title: String? = nil,   // Optional title
    sticky: Bool = false    // Show strikethrough instead of deleting
)
```

### ReportResult

```swift
struct ReportResult {
    let annotationsPosted: Int   // New annotations posted
    let annotationsUpdated: Int  // Existing annotations updated
    let annotationsDeleted: Int  // Stale annotations removed
    let checkRunURL: URL?        // URL to check run (if applicable)
    let commentURL: URL?         // URL to comment (if applicable)
}
```

### CommentMode

```swift
enum CommentMode {
    case update   // Update existing comment
    case append   // Append to existing comment
    case replace  // Delete old and create new
}
```

### OutOfRangeStrategy

For `PRReviewReporter`, controls how annotations outside the diff are handled:

```swift
enum OutOfRangeStrategy {
    case dismiss            // Silently ignore
    case fallbackToComment  // Post as PR comment (default)
    case fallbackToCheckRun // Post via CheckRunReporter
}
```

## Fork PRs

Fork PRs have read-only tokens and cannot post annotations. PRReporterKit detects this condition and throws `ContextError.readOnlyToken`, allowing you to handle it gracefully:

```swift
do {
    let context = try GitHubContext.fromEnvironment()
    // ...
} catch ContextError.readOnlyToken {
    print("Running on fork PR - skipping annotations")
}
```

## Building from Source

```bash
# Clone the repository
git clone https://github.com/diogot/swift-pr-reporter.git
cd swift-pr-reporter

# Build
swift build

# Run tests
swift test

# Build release
swift build -c release
```

## License

MIT License - see [LICENSE](LICENSE) for details.
