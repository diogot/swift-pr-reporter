# swift-pr-reporter - Swift Package Plan

## Overview

A pure Swift library for posting automated feedback to GitHub PRs - errors, warnings, and informational messages with support for updating/deleting on re-runs.

**Repository**: `swift-pr-reporter`
**Module**: `PRReporterKit`

**Goal**: Replace Danger (Ruby/Node.js) with a native Swift solution for surfacing build/test results to GitHub.

**Scope**: This library handles **only GitHub posting**. A separate library will handle Xcode result parsing.

**Requirements**:
- Swift 6.2 with strict concurrency
- Cross-platform: macOS and Linux
- Zero external dependencies
- GitHub.com only for v1; GitHub Enterprise support is a future enhancement

---

## GitHub API Options

| API | Use Case | Limitations |
|-----|----------|-------------|
| **Check Run Annotations** | Inline annotations in Checks tab + diff | Max 50 per run, can't delete (only update) |
| **PR Review Comments** | Line comments in diff (review style) | Only on changed lines in diff |
| **Issue Comments** | Summary comment on PR | Not line-specific |

**Recommendation**: Support all three, let consumer choose based on use case.

### Check Run Annotations
- Best for automated analysis results
- Can annotate **any line** in the codebase (not just changed lines)
- Appear in Checks tab AND inline on diff
- Cannot be deleted, only updated
- Limited to 50 annotations per check run

### PR Review Comments
- Comments on specific lines in the diff
- Good for code review style feedback
- Can only comment on lines that are part of the diff
- Can be deleted/updated

### Issue Comments
- General comments on the PR (not line-specific)
- Good for summary tables, build results overview
- Can be deleted/updated

---

## Core Design

### Models

```swift
// Annotation represents a single piece of feedback
public struct Annotation: Sendable, Equatable {
    public enum Level: String, Sendable {
        case notice
        case warning
        case failure
    }

    public let path: String
    public let line: Int
    public let endLine: Int?
    public let column: Int?
    public let level: Level
    public let message: String
    public let title: String?

    /// When true, resolved annotations show strikethrough instead of being deleted
    /// (Inspired by Danger's sticky flag)
    public let sticky: Bool

    public init(
        path: String,
        line: Int,
        endLine: Int? = nil,
        column: Int? = nil,
        level: Level,
        message: String,
        title: String? = nil,
        sticky: Bool = false
    )
}

// Context from GitHub Actions environment
public struct GitHubContext: Sendable {
    public let token: String           // GITHUB_TOKEN
    public let repository: String      // owner/repo
    public let owner: String           // Derived from repository
    public let repo: String            // Derived from repository
    public let pullRequest: Int?       // PR number (if applicable)
    public let commitSHA: String       // GITHUB_SHA
    public let headRef: String?        // GITHUB_HEAD_REF (source branch for PRs/forks)
    public let baseRef: String?        // GITHUB_BASE_REF (target branch for PRs)
    public let runID: Int?             // GITHUB_RUN_ID
    public let runAttempt: Int         // GITHUB_RUN_ATTEMPT (for idempotency)
    public let eventName: String       // GITHUB_EVENT_NAME (push, pull_request, etc.)
    public let isFork: Bool            // Detected from event payload or HEAD_REF presence

    /// API base URL (github.com only for v1.0; Enterprise support planned for future)
    public static let apiBaseURL = URL(string: "https://api.github.com")!

    /// Initialize from GitHub Actions environment variables
    /// - Throws: `ContextError.missingVariable` for required vars
    /// - Throws: `ContextError.invalidEventPayload` if GITHUB_EVENT_PATH unreadable
    public static func fromEnvironment() throws -> GitHubContext

    /// Initialize with explicit values (for testing or non-Actions environments)
    public init(
        token: String,
        repository: String,
        pullRequest: Int?,
        commitSHA: String,
        headRef: String? = nil,
        baseRef: String? = nil,
        runID: Int? = nil,
        runAttempt: Int = 1,
        eventName: String = "workflow_dispatch",
        isFork: Bool = false
    )
}

public enum ContextError: Error, CustomStringConvertible {
    case missingVariable(String)
    case invalidEventPayload(String)
    case missingPullRequestNumber
    case unsupportedEvent(String)

    public var description: String { ... }
}

// Result of a report operation
public struct ReportResult: Sendable {
    public let annotationsPosted: Int
    public let annotationsUpdated: Int
    public let annotationsDeleted: Int
    public let checkRunURL: URL?
    public let commentURL: URL?
}

// Comment behavior mode (inspired by Danger's CLI flags)
public enum CommentMode: Sendable {
    /// Update existing comment in place (default)
    case update

    /// Create new comment, keep old ones (Danger's --new-comment)
    case append

    /// Delete old comments, create fresh at end (Danger's --remove-previous-comments)
    case replace
}
```

### Reporter Protocol

```swift
public protocol Reporter: Sendable {
    /// Post annotations to GitHub
    func report(_ annotations: [Annotation]) async throws -> ReportResult

    /// Post a markdown summary (for PR comment or check run summary)
    func postSummary(_ markdown: String) async throws

    /// Remove stale comments/annotations from previous runs
    func cleanup() async throws
}
```

---

## Comment Tracking Strategy

Use **HTML comment markers** (invisible in rendered markdown) to identify bot comments:

```markdown
<!-- pr-reporter:xcode-build:abc123 -->
⚠️ **2 Warnings, 1 Error**

| Type | Count |
|------|-------|
| Errors | 1 |
| Warnings | 2 |
```

### Marker Format

```
<!-- pr-reporter:{identifier}:{content-hash} -->
```

- `identifier`: User-provided string (e.g., "xcode-build", "swiftlint")
- `content-hash`: Hash of annotation content for change detection

### Update/Delete Logic

On re-run:
1. List existing comments on PR
2. Find comments with our marker matching the identifier
3. Compare content hash:
   - If same: skip (no update needed)
   - If different: update comment
   - If marker exists but no new content: delete comment
4. Create new comments as needed

---

## Reporters

### 1. CheckRunReporter

Creates/updates a GitHub Check Run with annotations.

```swift
public final class CheckRunReporter: Reporter, Sendable {
    public init(
        context: GitHubContext,
        name: String,                    // Check run name shown in UI
        identifier: String,              // Used as external_id for idempotent updates
        overflowStrategy: OverflowStrategy = .truncate
    )

    public enum OverflowStrategy: Sendable {
        case truncate                    // Show "and X more..." in summary
        case multipleRuns                // Create additional check runs (name + " (2/3)")
        case fallbackToComment           // Post overflow as PR comment
    }
}
```

**Use for**: Build errors, test failures, lint warnings

**Permissions required**: `checks: write`

#### Check Run Lifecycle & API Details

**Important**: The 50-annotation limit is **per API request**, not per check run. Multiple PATCH calls can add more annotations to the same run.

**Required fields**:
- `name`: Display name in GitHub UI
- `head_sha`: Commit SHA to attach the check to
- `status`: `queued`, `in_progress`, or `completed`
- `conclusion`: Required when `status=completed` (`success`, `failure`, `neutral`, `cancelled`, `skipped`, `timed_out`, `action_required`)

**Idempotency via `external_id`**:
- Set `external_id` to `{identifier}-{run_id}-{run_attempt}` for idempotent updates
- On re-run, find existing check run by `external_id` and PATCH instead of POST
- Prevents duplicate check runs on job retries

**Annotation chunking workflow**:
```
1. POST /repos/{owner}/{repo}/check-runs
   - name, head_sha, external_id, status="in_progress"
   - output.title, output.summary
   - output.annotations (first 50)
   → Returns check_run_id

2. For remaining annotations, chunk into batches of 50:
   PATCH /repos/{owner}/{repo}/check-runs/{check_run_id}
   - output.annotations (next 50)
   - Repeat until all annotations posted

3. PATCH /repos/{owner}/{repo}/check-runs/{check_run_id}
   - status="completed"
   - conclusion="failure" if any errors, "success" otherwise
   - output.summary (final summary with counts)
```

**Cleanup behavior**:
- Check run annotations **cannot be individually deleted**
- `cleanup()` is a **no-op** for CheckRunReporter
- To "clear" annotations: complete the run with empty annotations list
- Alternative: close/cancel the entire check run (not recommended)

**Sticky annotations**: Not applicable - check run annotations don't support strikethrough. The `sticky` flag is ignored for this reporter.

### 2. PRReviewReporter

Posts PR review comments on specific lines in the diff.

```swift
public final class PRReviewReporter: Reporter, Sendable {
    public init(
        context: GitHubContext,
        identifier: String,
        outOfRangeStrategy: OutOfRangeStrategy = .fallbackToComment
    )

    public enum OutOfRangeStrategy: Sendable {
        case dismiss                     // Silently ignore annotations outside diff
        case fallbackToComment           // Include in PR summary comment
        case fallbackToCheckRun          // Post via CheckRunReporter instead
    }
}
```

**Use for**: Code suggestions, style feedback on changed lines

**Permissions required**: `pull-requests: write`

**Limitation**: Can only comment on lines that are part of the PR diff

#### Diff Position Mapping (Critical)

GitHub's PR Review Comments API requires a **position in the unified diff**, not the absolute line number. This requires:

**Required API fields**:
- `commit_id`: The SHA of the commit to comment on (use head commit)
- `path`: File path relative to repo root
- `position`: Line index in the unified diff (1-based, counting from first `@@` line)
- `body`: Comment text (with our marker)

**Diff fetching workflow**:
```
1. GET /repos/{owner}/{repo}/pulls/{pr}/files
   → Returns list of changed files with patch (unified diff)

2. For each annotation, find matching file in response

3. Parse the unified diff to map line number → position:
   - Parse @@ -old_start,old_count +new_start,new_count @@ headers
   - Track position counter starting from 1 after each @@ line
   - Match annotation.line to the +new_line in diff
   - Return position, or nil if line not in diff
```

**Diff position calculation**:
```swift
struct DiffMapper {
    /// Maps absolute line number to diff position
    /// Returns nil if line is not part of the diff
    func position(forLine line: Int, inPatch patch: String) -> Int?

    /// Handles file renames (old path → new path)
    func resolvedPath(for annotation: Annotation, files: [PullRequestFile]) -> String?
}
```

**Edge cases to handle**:
- **Renamed files**: Match by new path, fallback to old path
- **Binary files**: No patch available, must use fallback strategy
- **Off-by-one**: Diff position is 1-based, line numbers may be 0 or 1-based
- **Deleted lines**: Can only comment on added (+) or context lines
- **Large diffs**: GitHub truncates patches > 300 lines; may need raw diff endpoint

**Out-of-range handling**:
When annotation line is not in the diff:
1. `.dismiss`: Skip silently (log at debug level)
2. `.fallbackToComment`: Collect and include in summary PR comment
3. `.fallbackToCheckRun`: Route to CheckRunReporter (can annotate any line)

**Cleanup behavior**:
- PR review comments CAN be deleted via API
- `cleanup()` lists comments, finds those with our marker, deletes stale ones
- Respects `sticky` flag: sticky comments get strikethrough update, not deletion

**Sticky annotations**: Supported - resolved annotations are updated with ~~strikethrough~~ text instead of being deleted.

### 3. PRCommentReporter

Posts/updates a single summary comment on the PR.

```swift
public final class PRCommentReporter: Reporter, Sendable {
    public init(
        context: GitHubContext,
        identifier: String,
        commentMode: CommentMode = .update
    )
}
```

**Use for**: Build summary tables, test results overview

**Permissions required**: `pull-requests: write`

**Comment modes**:
- `.update` (default): Find and update existing comment with same identifier
- `.append`: Always create new comment, keep history
- `.replace`: Delete all previous comments with same identifier, post fresh

#### Cleanup and CommentMode Interaction

| CommentMode | `cleanup()` behavior |
|-------------|---------------------|
| `.update` | Delete comment if no annotations; update with strikethrough for sticky |
| `.append` | No-op (historical comments preserved) |
| `.replace` | Delete all previous comments with identifier |

**Cleanup workflow**:
```
1. GET /repos/{owner}/{repo}/issues/{pr}/comments
   - Paginate through all comments (100 per page max)

2. Filter comments containing our marker: <!-- pr-reporter:{identifier} -->

3. For each matched comment:
   - If commentMode == .append: skip
   - If no new annotations and not sticky: DELETE
   - If sticky and resolved: PATCH with strikethrough content
   - If content changed: PATCH with new content
```

**Sticky annotations**: Fully supported - resolved sticky annotations render with ~~strikethrough~~ in the comment body, preserving history.

### Summary: Sticky & Cleanup Behavior by Reporter

| Reporter | `sticky` support | `cleanup()` behavior |
|----------|-----------------|---------------------|
| CheckRunReporter | ❌ Ignored | No-op (annotations can't be deleted) |
| PRReviewReporter | ✅ Strikethrough | Deletes non-sticky; updates sticky with ~~text~~ |
| PRCommentReporter | ✅ Strikethrough | Depends on `CommentMode` (see table above) |

**Key insight**: Check Run annotations are immutable once posted - they can only be replaced by completing the run with new annotations. The `sticky` flag only has meaning for PR comments where we control deletion.

---

## GitHub Actions Integration

### Required Permissions

```yaml
permissions:
  checks: write        # For CheckRunReporter
  pull-requests: write # For PRReviewReporter, PRCommentReporter
```

### Environment Variables (Auto-detected)

| Variable | Description |
|----------|-------------|
| `GITHUB_TOKEN` | Authentication token |
| `GITHUB_REPOSITORY` | `owner/repo` format |
| `GITHUB_SHA` | Commit SHA |
| `GITHUB_REF` | Branch/tag ref |
| `GITHUB_EVENT_NAME` | Trigger event (push, pull_request) |
| `GITHUB_RUN_ID` | Workflow run ID |
| `GITHUB_EVENT_PATH` | Path to event JSON (contains PR number) |

---

## Public API Examples

### Basic Usage

```swift
import PRReporterKit

// Auto-detect context from GitHub Actions environment
let github = try GitHubContext.fromEnvironment()

// Create a check run reporter
let reporter = CheckRunReporter(
    context: github,
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
    ),
    Annotation(
        path: "Sources/MyApp/Model.swift",
        line: 10,
        level: .failure,
        message: "Cannot convert 'String' to 'Int'"
    )
])

// Post summary
try await reporter.postSummary("""
## Build Results
- ❌ 1 error
- ⚠️ 1 warning

Build completed in 45 seconds.
""")

print("Posted \(result.annotationsPosted) annotations")
```

### Multiple Reporters

```swift
// Use different reporters for different purposes
let checkReporter = CheckRunReporter(context: github, name: "Build", identifier: "build")
let commentReporter = PRCommentReporter(context: github, identifier: "build-summary")

// Annotations go to Check Run (inline in diff)
try await checkReporter.report(buildAnnotations)

// Summary goes to PR comment (easy to find)
try await commentReporter.postSummary(buildSummaryMarkdown)
```

### Handling Overflow

```swift
// When you have more than 50 annotations
let reporter = CheckRunReporter(
    context: github,
    name: "SwiftLint",
    identifier: "swiftlint",
    overflowStrategy: .fallbackToComment  // Post extras as PR comment
)

// Report all 200 warnings
try await reporter.report(allWarnings)
// First 50 go to Check Run annotations
// Remaining 150 summarized in PR comment
```

---

## Package Structure

```
Sources/
├── PRReporterKit/
│   ├── Models/
│   │   ├── Annotation.swift
│   │   ├── GitHubContext.swift
│   │   ├── ContextError.swift
│   │   ├── ReportResult.swift
│   │   ├── CommentMode.swift
│   │   └── RetryPolicy.swift
│   ├── API/
│   │   ├── GitHubAPI.swift          # Low-level REST client with retry/pagination
│   │   ├── ChecksAPI.swift          # Check runs/annotations
│   │   ├── PullRequestsAPI.swift    # PR review comments + files/diff
│   │   └── IssuesAPI.swift          # Issue comments (PR comments)
│   ├── Reporters/
│   │   ├── Reporter.swift           # Protocol
│   │   ├── CheckRunReporter.swift
│   │   ├── PRReviewReporter.swift
│   │   └── PRCommentReporter.swift
│   └── Utilities/
│       ├── CommentMarker.swift      # Hidden marker generation/parsing
│       ├── DiffMapper.swift         # Unified diff parsing, position calculation
│       ├── EnvironmentParser.swift  # Parse GitHub Actions env vars
│       └── SafeLogger.swift         # Token-redacting logger
Tests/
└── PRReporterKitTests/
    ├── Fixtures/
    │   ├── events/                  # GitHub event payloads
    │   ├── responses/               # API response fixtures
    │   └── diffs/                   # Unified diff samples
    ├── Models/
    │   ├── AnnotationTests.swift
    │   └── GitHubContextTests.swift
    ├── API/
    │   ├── GitHubAPITests.swift
    │   └── MockURLProtocol.swift
    ├── Reporters/
    │   ├── CheckRunReporterTests.swift
    │   ├── PRReviewReporterTests.swift
    │   └── PRCommentReporterTests.swift
    ├── Utilities/
    │   ├── CommentMarkerTests.swift
    │   └── DiffMapperTests.swift
    └── Concurrency/
        ├── SendableConformanceTests.swift
        └── ConcurrencyTests.swift
```

---

## Edge Cases & Error Handling

### Forked PRs

Pull requests from forks have read-only `GITHUB_TOKEN` (no write access to checks or PR comments).

**Options**:
1. Silently skip reporting (log warning)
2. Output annotations to stdout as fallback
3. Throw error with clear message

**Recommendation**: Option 3

### 50 Annotation Limit

Check Run API limits to 50 annotations per API call.

**Strategies**:
- `truncate`: Show first 50, add "and X more..." to summary
- `multipleRuns`: Create additional check runs (e.g., "Build (1/3)")
- `fallbackToComment`: Post overflow to PR comment

### Rate Limiting

GitHub API has rate limits. Handle with:
- Exponential backoff on 429 responses
- Batch operations where possible
- Clear error messages when limits hit

### No PR Context

When running on push (not PR), some reporters won't work:
- `CheckRunReporter`: Works (annotations on commit)
- `PRReviewReporter`: Fails (no PR to comment on)
- `PRCommentReporter`: Fails (no PR to comment on)

**Handling**: Check `context.pullRequest` and throw descriptive error or skip gracefully.

---

## API Client Resilience

### GitHubAPI Client Design

```swift
public actor GitHubAPI {
    public init(
        token: String,
        baseURL: URL = URL(string: "https://api.github.com")!,
        urlSession: URLSession = .shared,
        logger: Logger? = nil
    )
}
```

### Rate Limiting & Retry Strategy

GitHub has two types of rate limits:

1. **Primary rate limit**: X requests per hour (5000 for authenticated)
   - Response: `403` with `X-RateLimit-Remaining: 0`
   - Header: `X-RateLimit-Reset` (Unix timestamp)
   - Strategy: Wait until reset time, then retry

2. **Secondary rate limit**: Too many requests in short window
   - Response: `403` with message containing "secondary rate limit"
   - Header: `Retry-After` (seconds to wait)
   - Strategy: Exponential backoff starting from `Retry-After`

**Retry configuration**:
```swift
public struct RetryPolicy: Sendable {
    public let maxAttempts: Int           // Default: 3
    public let initialBackoff: Duration   // Default: 1 second
    public let maxBackoff: Duration       // Default: 60 seconds
    public let backoffMultiplier: Double  // Default: 2.0
    public let retryableStatusCodes: Set<Int> // Default: [429, 500, 502, 503, 504]
    public let jitter: Double             // Default: 0.2 (20% randomization)

    public static let `default` = RetryPolicy()
    public static let aggressive = RetryPolicy(maxAttempts: 5, initialBackoff: .seconds(2))
}
```

**Retry logic**:
```
For each request:
1. Execute request
2. If 429 or 403 (rate limit):
   - Check Retry-After header
   - Wait min(Retry-After, backoff * multiplier^attempt, maxBackoff)
   - Retry up to maxAttempts
3. If 5xx (server error):
   - Exponential backoff retry
4. If 4xx (client error, not rate limit):
   - Do not retry, throw immediately
5. Apply jitter to backoff to avoid thundering herd
6. Honor a per-request timeout (default: 30s) and total-attempts cap (default: 90s)
```

### Pagination

Comment listing endpoints return max 100 items per page. Must paginate:

```swift
func listAllComments(pr: Int) async throws -> [Comment] {
    var comments: [Comment] = []
    var page = 1

    while true {
        let response = try await get("/repos/\(owner)/\(repo)/issues/\(pr)/comments",
                                      query: ["per_page": "100", "page": "\(page)"])
        let pageComments = try decode([Comment].self, from: response)

        comments.append(contentsOf: pageComments)

        if response.isLastPage { break }        // Parse Link header rel="next"
        if pageComments.count < 100 { break }   // Fallback when Link missing
        page += 1
    }

    return comments
}
```

**Pagination required for**:
- `GET /issues/{pr}/comments` (PR comments)
- `GET /pulls/{pr}/comments` (review comments)
- `GET /repos/{owner}/{repo}/check-runs` (finding existing runs)

### Idempotency for Repeated Jobs

GitHub Actions jobs may be re-run. Ensure idempotent behavior:

1. **CheckRunReporter**: Use `external_id = "{identifier}-{run_id}-{run_attempt}"`
   - Same run_id + different run_attempt = update existing run
   - Prevents duplicate check runs

2. **PRCommentReporter**: Use marker to find existing comment
   - Update instead of create if marker found
   - Content hash prevents unnecessary updates

3. **PRReviewReporter**: Use marker in comment body
   - Find existing comments by marker before creating new
    - When using fallback modes, ensure each annotation is routed once (no duplicates across channels)

4. **HTTP idempotency keys (future-friendly)**: For POSTs that may retry, include a stable hash in an `Idempotency-Key` header (safe even if GitHub ignores it today).

5. **ETag/If-None-Match**: Use when listing comments/files to avoid unnecessary API calls; respect 304 to reduce noise.

### Fork Detection

Detect forked PRs **before** attempting writes to fail fast:

```swift
extension GitHubContext {
    /// Returns true if this is a PR from a fork (likely read-only token)
    var isForkPR: Bool {
        // Method 1: Check if GITHUB_HEAD_REF contains fork info
        // Method 2: Parse event payload for head.repo.fork
        // Method 3: Compare head.repo.full_name vs base.repo.full_name
        isFork
    }

    /// Validates token can write before attempting operations
    func validateWriteAccess() async throws {
        if isForkPR {
            throw ContextError.readOnlyToken(
                "Cannot write to PR from fork. Token has read-only access."
            )
        }
    }
}
```

**Fork handling flow**:
```
1. Check context.isForkPR before any write operations
2. If fork detected:
   - Log warning with explanation
   - Output annotations to stdout in structured format
   - Return success (don't fail the build)
3. If write fails unexpectedly:
   - Catch 403/404 errors
   - Provide helpful error message about permissions
```

### Error model and observability

- Define `GitHubAPIError` with fields: `statusCode`, `message` (decoded from GitHub error JSON when present), `endpoint`, `requestID` (`X-GitHub-Request-Id`), and `retryable` (derived from status + headers).
- Surface raw response body (redacted) for debugging when safe.
- Provide a hook for per-request metrics (latency, attempt count, rate-limit wait) that callers can forward to their telemetry.

### Logging & Token Redaction

**Safe logging rules**:
- Never log raw token value
- Redact `Authorization` header in request logs
- Redact token from URLs (shouldn't be there, but safety first)
- Log request method, path, response status
- Log rate limit headers for debugging
- Default log level: info for high-level operations, debug for request/response details (headers sans Authorization), error for failures
- Provide dependency-injected `SafeLogger` so callers can silence logs or bridge to their logger

```swift
struct SafeLogger {
    func logRequest(_ request: URLRequest) {
        // Log: "POST /repos/owner/repo/check-runs"
        // Never log: Authorization header value
    }

    func logResponse(_ response: HTTPURLResponse, duration: Duration) {
        // Log: "200 OK (245ms) RateLimit: 4998/5000"
    }

    func redact(_ string: String) -> String {
        // Replace tokens with "[REDACTED]"
    }
}
```

### Timeouts & configuration

- Default request timeout: 30s; total retry budget: 90s (policy configurable).
- URLSession injected; allow ephemeral session for tests.
- Configure page size defaults (`per_page=100`) and max pagination depth safeguards.

---

## Platform & Swift Requirements

### Swift Version
- **Swift 6.2** with strict concurrency checking enabled
- Full `Sendable` compliance for all public types
- `async`/`await` for all network operations

### Supported Platforms
- **macOS 13+** (Ventura)
- **Linux** (Ubuntu 22.04+, Amazon Linux 2023+)

### Platform Considerations

**Linux compatibility requires**:
```swift
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession on Linux
#endif
```

**Cross-platform differences**:
| Feature | macOS | Linux |
|---------|-------|-------|
| URLSession | Foundation | FoundationNetworking |
| Keychain | Available | N/A (not needed for this library) |
| SecureEnclave | Available | N/A |
| FileManager | Full | Full |

**Package.swift configuration**:
```swift
// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-pr-reporter",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PRReporterKit", targets: ["PRReporterKit"])
    ],
    dependencies: [
        // No external dependencies - pure Swift
    ],
    targets: [
        .target(
            name: "PRReporterKit",
            dependencies: []
        ),
        .testTarget(
            name: "PRReporterKitTests",
            dependencies: ["PRReporterKit"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
```

**Note**: `platforms` only affects macOS minimum version. Linux builds ignore this and work with any Swift 6.2+ toolchain.

---

## Installing Swift for Development

This project requires **Swift 6.2** or later.

### macOS

```bash
# Install Xcode Command Line Tools (includes Swift 6.2+)
xcode-select --install

# Or download the latest Swift toolchain from:
# https://www.swift.org/install/macos/
```

### Linux - Option 1: Direct Download (Recommended)

This is the most reliable method for getting Swift 6.2.

**For Ubuntu 22.04/24.04 (x86_64):**

```bash
# Download Swift 6.2.1
cd /tmp
wget https://download.swift.org/swift-6.2.1-release/ubuntu2204/swift-6.2.1-RELEASE/swift-6.2.1-RELEASE-ubuntu22.04.tar.gz

# Extract
tar xzf swift-6.2.1-RELEASE-ubuntu22.04.tar.gz

# Option A: Install system-wide (requires sudo)
sudo mv swift-6.2.1-RELEASE-ubuntu22.04 /opt/swift
echo 'export PATH=/opt/swift/usr/bin:$PATH' >> ~/.bashrc

# Option B: Install to user directory (no sudo required)
mkdir -p ~/.local/swift
mv swift-6.2.1-RELEASE-ubuntu22.04 ~/.local/swift/6.2.1
echo 'export PATH=$HOME/.local/swift/6.2.1/usr/bin:$PATH' >> ~/.bashrc

# Reload shell configuration
source ~/.bashrc

# Verify installation
swift --version
# Should output: Swift version 6.2.1 (swift-6.2.1-RELEASE)
```

### Linux - Option 2: Using Swiftly

Swiftly is the official Swift toolchain manager for Linux.

```bash
# Download and install Swiftly
curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
tar zxf swiftly-$(uname -m).tar.gz
echo "Y" | ./swiftly init --skip-install --quiet-shell-followup

# Load Swiftly environment
source "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
hash -r

# Install Swift 6.2 (requires network access)
swiftly install latest

# Verify installation
swift --version
```

### Linux - Option 3: Using swiftenv

```bash
# Install swiftenv
git clone https://github.com/kylef/swiftenv.git ~/.swiftenv

# Add to PATH
echo 'export SWIFTENV_ROOT="$HOME/.swiftenv"' >> ~/.bashrc
echo 'export PATH="$SWIFTENV_ROOT/bin:$PATH"' >> ~/.bashrc
echo 'eval "$(swiftenv init -)"' >> ~/.bashrc
source ~/.bashrc

# Install Swift 6.2
swiftenv install 6.2
swiftenv global 6.2
```

### Linux System Dependencies

Swift requires several system libraries on Linux:

**Ubuntu/Debian:**
```bash
sudo apt-get update
sudo apt-get install -y \
  binutils \
  git \
  gnupg2 \
  libc6-dev \
  libcurl4-openssl-dev \
  libedit2 \
  libpython3.8 \
  libsqlite3-0 \
  libxml2-dev \
  libz3-dev \
  pkg-config \
  tzdata \
  unzip \
  zlib1g-dev
```

---

## Building and Testing

### Build the library
```bash
swift build
```

### Run the test suite
```bash
swift test
```

### Build in release mode
```bash
swift build -c release
```

### Run specific tests
```bash
# Run only specific tests
swift test --filter GitHubContextTests

# Run with verbose output
swift test -v
```

---

## Dependencies

### Required
- **Foundation** (macOS) / **FoundationNetworking** (Linux) for URLSession

### Optional
- None - pure Swift with no external dependencies

### No External Dependencies Policy
This library intentionally has zero external dependencies to:
- Simplify integration into any project
- Avoid version conflicts
- Ensure predictable builds on CI runners
- Support both macOS and Linux without dependency complications

---

## Implementation Phases

### Phase 1: Core Infrastructure
- [ ] `GitHubContext` with full environment parsing
  - [ ] All GitHub Actions env vars (TOKEN, SHA, REF, HEAD_REF, BASE_REF, RUN_ID, RUN_ATTEMPT)
  - [ ] Event payload parsing for PR number and fork detection
  - [ ] `ContextError` enum with descriptive messages
- [ ] `Annotation` model with `sticky` flag
- [ ] `CommentMode` and `RetryPolicy` enums
- [ ] `GitHubAPI` REST client
  - [ ] `URLSession` injection for testability
  - [ ] Retry logic with exponential backoff
  - [ ] Rate limit handling (primary + secondary)
  - [ ] Pagination helper
  - [ ] `SafeLogger` with token redaction
- [ ] `CommentMarker` utility (generation + parsing)
- [ ] `MockURLProtocol` for testing
- [ ] Fixture loading infrastructure

### Phase 2: CheckRunReporter
- [ ] `ChecksAPI` implementation
  - [ ] POST /check-runs (create with external_id)
  - [ ] PATCH /check-runs/{id} (update annotations, status, conclusion)
  - [ ] GET /check-runs (find by external_id for idempotency)
- [ ] `CheckRunReporter` implementation
  - [ ] Annotation chunking (batches of 50)
  - [ ] `external_id` generation for idempotent updates
  - [ ] Correct status/conclusion handling
  - [ ] `cleanup()` as no-op (documented)
- [ ] Overflow strategies (truncate, multipleRuns, fallbackToComment)
- [ ] Tests: chunking, idempotency, overflow, empty annotations

### Phase 3: PRCommentReporter
- [ ] `IssuesAPI` implementation
  - [ ] GET /issues/{pr}/comments (with pagination)
  - [ ] POST /issues/{pr}/comments
  - [ ] PATCH /issues/comments/{id}
  - [ ] DELETE /issues/comments/{id}
- [ ] `PRCommentReporter` implementation
  - [ ] Marker-based comment finding
  - [ ] Content hash for change detection
  - [ ] CommentMode handling (.update, .append, .replace)
  - [ ] Sticky annotation strikethrough rendering
  - [ ] `cleanup()` with CommentMode interaction
- [ ] Tests: all comment modes, pagination, sticky, cleanup

### Phase 4: PRReviewReporter
- [ ] `PullRequestsAPI` implementation
  - [ ] GET /pulls/{pr}/files (for diff patches)
  - [ ] GET /pulls/{pr}/comments (review comments, with pagination)
  - [ ] POST /pulls/{pr}/comments (create review comment)
  - [ ] PATCH /pulls/comments/{id}
  - [ ] DELETE /pulls/comments/{id}
- [ ] `DiffMapper` utility
  - [ ] Unified diff parsing (@@ header extraction)
  - [ ] Line number → position mapping
  - [ ] File rename handling
  - [ ] Edge cases: multiple hunks, truncated patches, binary files
- [ ] `PRReviewReporter` implementation
  - [ ] Fetch diff, map positions
  - [ ] OutOfRangeStrategy handling
  - [ ] Cleanup with sticky support
- [ ] Tests: diff mapping edge cases, out-of-range, rename handling

### Phase 5: Polish & Documentation
- [ ] Comprehensive error messages with actionable guidance
- [ ] Fork detection with stdout fallback
- [ ] README with examples
- [ ] GitHub Actions workflow examples
- [ ] Concurrency/Sendable conformance verification
- [ ] Integration tests (optional, requires real GitHub API or recorded fixtures)

---

## Testing Strategy

Use **Swift Testing** with `#expect` (not `XCTestCase`/`XCTAssert`). The outlines below are conceptual; implement them with Swift Testing test modules and expectations.

### URLProtocol-Based HTTP Stubbing

Use `URLProtocol` subclass for network-free unit tests:

```swift
final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
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

// Usage in tests:
let config = URLSessionConfiguration.ephemeral
config.protocolClasses = [MockURLProtocol.self]
let session = URLSession(configuration: config)
let api = GitHubAPI(token: "test-token", urlSession: session)
```

### Fixture Event Payloads

Store GitHub Actions event payloads as JSON fixtures:

```
Tests/GitHubReporterTests/Fixtures/
├── events/
│   ├── pull_request_opened.json
│   ├── pull_request_synchronize.json
│   ├── pull_request_from_fork.json
│   ├── push_to_main.json
│   └── workflow_dispatch.json
├── responses/
│   ├── check_run_created.json
│   ├── check_run_updated.json
│   ├── pr_comments_page1.json
│   ├── pr_comments_page2.json
│   ├── pr_files_with_patch.json
│   ├── rate_limit_exceeded.json
│   └── secondary_rate_limit.json
└── diffs/
    ├── simple_addition.patch
    ├── file_rename.patch
    ├── multiple_hunks.patch
    └── binary_file.patch
```

### Test Categories

#### 1. GitHubContext Tests
```swift
final class GitHubContextTests: XCTestCase {
    func test_fromEnvironment_parsesAllVariables()
    func test_fromEnvironment_throwsOnMissingToken()
    func test_fromEnvironment_parsesEventPayloadForPRNumber()
    func test_fromEnvironment_detectsForkFromPayload()
    func test_fromEnvironment_parsesRunAttempt()
    func test_init_derivesOwnerAndRepoFromRepository()
}
```

#### 2. CheckRunReporter Tests
```swift
final class CheckRunReporterTests: XCTestCase {
    // Basic functionality
    func test_report_createsCheckRunWithAnnotations()
    func test_report_updatesExistingRunByExternalId()
    func test_report_setsCorrectConclusion_failure()
    func test_report_setsCorrectConclusion_success()

    // Annotation chunking
    func test_report_chunksAnnotationsInBatchesOf50()
    func test_report_withExactly50Annotations_singleRequest()
    func test_report_with51Annotations_twoRequests()
    func test_report_with150Annotations_threeRequests()

    // Overflow strategies
    func test_overflowTruncate_showsCountInSummary()
    func test_overflowMultipleRuns_createsAdditionalRuns()
    func test_overflowFallbackToComment_postsExcessAsComment()

    // Cleanup
    func test_cleanup_isNoOp()

    // Edge cases
    func test_report_withEmptyAnnotations_completesSuccessfully()
    func test_report_ignoresStickyFlag()
}
```

#### 3. PRReviewReporter Tests
```swift
final class PRReviewReporterTests: XCTestCase {
    // Diff position mapping
    func test_diffMapper_findsPositionInSimpleDiff()
    func test_diffMapper_handlesMultipleHunks()
    func test_diffMapper_returnsNilForLineOutsideDiff()
    func test_diffMapper_handlesFileRename()
    func test_diffMapper_offByOneCorrectness()
    func test_diffMapper_handlesDeletedLines()
    func test_diffMapper_handlesTruncatedPatch()

    // Out-of-range handling
    func test_outOfRange_dismiss_skipsAnnotation()
    func test_outOfRange_fallbackToComment_includesInSummary()
    func test_outOfRange_fallbackToCheckRun_routesToCheckRun()

    // Cleanup
    func test_cleanup_deletesStaleComments()
    func test_cleanup_preservesStickyWithStrikethrough()

    // Edge cases
    func test_report_failsGracefullyOnBinaryFile()
    func test_report_requiresPRContext()
}
```

#### 4. PRCommentReporter Tests
```swift
final class PRCommentReporterTests: XCTestCase {
    // Comment modes
    func test_update_findsAndUpdatesExistingComment()
    func test_update_createsIfNoExisting()
    func test_append_alwaysCreatesNew()
    func test_replace_deletesOldThenCreates()

    // Marker handling
    func test_marker_embeddedInComment()
    func test_marker_foundWhenSearching()
    func test_marker_contentHashPreventsUnnecessaryUpdate()

    // Cleanup interaction
    func test_cleanup_update_deletesWhenNoAnnotations()
    func test_cleanup_append_isNoOp()
    func test_cleanup_replace_deletesAll()

    // Sticky
    func test_sticky_rendersStrikethroughWhenResolved()

    // Pagination
    func test_findComment_paginatesThroughAllPages()
}
```

#### 5. API Client Tests
```swift
final class GitHubAPITests: XCTestCase {
    // Basic requests
    func test_get_sendsAuthorizationHeader()
    func test_post_encodesJSONBody()
    func test_patch_sendsCorrectMethod()

    // Rate limiting
    func test_primaryRateLimit_waitsAndRetries()
    func test_secondaryRateLimit_respectsRetryAfter()
    func test_rateLimitExceeded_failsAfterMaxAttempts()

    // Retry
    func test_serverError_retriesWithBackoff()
    func test_clientError_doesNotRetry()
    func test_retryPolicy_respectsMaxBackoff()

    // Pagination
    func test_listAllComments_fetchesAllPages()
    func test_listAllComments_stopsOnPartialPage()

    // Security
    func test_logging_redactsToken()
    func test_logging_redactsAuthorizationHeader()
}
```

#### 6. DiffMapper Tests
```swift
final class DiffMapperTests: XCTestCase {
    func test_parseHunkHeader_extractsLineNumbers()
    func test_position_forAddedLine_returnsCorrectPosition()
    func test_position_forContextLine_returnsCorrectPosition()
    func test_position_forDeletedLine_returnsNil()
    func test_position_afterMultipleHunks_countsCorrectly()
    func test_position_forLineBeforeFirstHunk_returnsNil()
    func test_position_forLineBetweenHunks_returnsNil()
    func test_resolvedPath_matchesRenamedFile()
    func test_resolvedPath_fallsBackToOldPath()
}
```

### Concurrency & Sendable Tests

```swift
final class SendableConformanceTests: XCTestCase {
    func test_annotation_isSendable() {
        let annotation = Annotation(path: "test", line: 1, level: .warning, message: "test")
        Task { @Sendable in
            _ = annotation  // Compiler error if not Sendable
        }
    }

    func test_gitHubContext_isSendable()
    func test_reportResult_isSendable()
    func test_checkRunReporter_isSendable()
    func test_prCommentReporter_isSendable()
}

final class ConcurrencyTests: XCTestCase {
    func test_multipleReportsInParallel_noDataRace()
    func test_actorIsolation_preventsConcurrentStateAccess()
}
```

### Test Utilities

```swift
// Test helpers
extension XCTestCase {
    func loadFixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    func mockGitHubContext(pullRequest: Int? = 123, isFork: Bool = false) -> GitHubContext {
        GitHubContext(
            token: "test-token",
            repository: "owner/repo",
            pullRequest: pullRequest,
            commitSHA: "abc123",
            isFork: isFork
        )
    }
}
```

### Cross-Platform Testing

**GitHub Actions CI Workflow** (`.github/workflows/ci.yml`):
```yaml
name: CI

on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main

jobs:
  test-macos:
    name: Test on macOS
    runs-on: macos-26
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Check Swift version
        run: swift --version

      - name: Build
        run: swift build

      - name: Run tests
        run: swift test

      - name: Build release
        run: swift build -c release

  test-linux:
    name: Test on Linux
    runs-on: ubuntu-latest
    container:
      image: swift:6.2
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Check Swift version
        run: swift --version

      - name: Build
        run: swift build

      - name: Run tests
        run: swift test

      - name: Build release
        run: swift build -c release
```

**Key points**:
- macOS: Uses `macos-26` runner which includes Swift 6.2+
- Linux: Uses official `swift:6.2` Docker container (no manual Swift installation needed)
- No external dependencies, so no `apt-get install` step required

**Linux-specific test considerations**:
- URLSession behavior may differ slightly (FoundationNetworking)
- No Keychain tests (not applicable)
- File paths use forward slashes (already standard)
- Bundle.module works the same for resource loading

**Platform-conditional tests**:
```swift
#if os(macOS)
func test_macOSSpecificBehavior() {
    // macOS-only tests if any
}
#endif

#if os(Linux)
func test_linuxSpecificBehavior() {
    // Linux-only tests if any
}
#endif
```

---

## Open Questions

1. ~~**Naming**~~: ✅ Resolved → Repository: `swift-pr-reporter`, Module: `PRReporterKit`

2. **Scope**: Separate repo/package (not integrated into Xproject)

3. **50 annotation limit**: Default overflow strategy?
   - Truncate with "and X more..." ← **Recommended** (simple, clear)
   - Create multiple check runs
   - Fall back to PR comment

4. **Forked PRs**: Default behavior when token is read-only?
   - Silently skip
   - Output to stdout ← **Recommended** (matches Danger behavior)
   - Error

5. **Priority**: Which reporter to implement first?
   - `CheckRunReporter` ← **Recommended** (most useful, our main differentiator)
   - `PRCommentReporter` (simplest to implement)

### Resolved Questions (from Danger analysis)

6. **Comment tracking**: Use HTML comments (`<!-- identifier -->`) - simpler than Danger's data attributes
7. **Multi-instance support**: Use `identifier` parameter (like Danger's `danger_id`)
8. **Comment update behavior**: Support three modes via `CommentMode` enum
9. **Sticky violations**: Add `sticky` flag to `Annotation` model
10. **Out-of-range annotations**: Use Checks API (can annotate any line, unlike PR Review API)

---

## Learnings from Danger Ruby

After analyzing Danger Ruby's source code, here are key implementation details to adopt:

### APIs Used by Danger

Danger Ruby uses **three GitHub APIs**:

1. **Issue Comments API** (`client.add_comment()`, `client.update_comment()`)
   - For the main summary comment on the PR
   - Can be created, updated, and deleted

2. **Pull Request Review Comments API** (`client.create_pull_request_comment()`)
   - For inline comments on specific lines in the diff
   - Requires calculating line position in the unified diff
   - Only works on lines that are part of the diff

3. **Commit Status API** (`client.create_status()`)
   - For setting pass/fail status on the PR
   - Not used for annotations (predates Checks API)

**Note**: Danger Ruby does NOT use the Checks API for annotations. This is an opportunity for improvement in our implementation.

### Comment Identification Strategy

Danger uses **HTML data attributes** embedded in the comment:

```html
<p align="right" data-meta="generated_by_danger">
```

Additional metadata in tables:
- `data-danger-table="true"` - marks violation tables
- `data-kind="warning"` - identifies violation type
- `data-sticky` - marks persistent violations

**Our approach**: Use simpler HTML comments (`<!-- marker -->`) which are invisible when rendered.

### The `danger_id` Pattern

Danger supports a `--danger_id` flag allowing multiple Danger instances to coexist:

```bash
bundle exec danger --danger_id="swiftlint"
bundle exec danger --danger_id="build-warnings"
```

Each instance only manages comments with its own ID. This is essential for:
- Running multiple analysis tools
- Avoiding comment conflicts
- Independent update/delete cycles

**Adopt this**: Our `identifier` parameter serves the same purpose.

### Comment Update/Delete Logic

Danger's approach:

1. **List all PR comments** via GitHub API
2. **Filter by marker** - find comments with matching `danger_id`
3. **Compare violations**:
   - Same content → skip (no API call)
   - Different content → update existing comment
   - No new violations → delete comment (or strike through if sticky)
4. **Create new** if no existing comment found

**Message equivalence check**: Danger compares messages after stripping blob hashes to handle file renames.

### Sticky vs Non-Sticky Violations

Danger has a `sticky` flag (default: `false`):

```ruby
warn("Missing tests", sticky: true)   # Persists with strikethrough
warn("PR too large", sticky: false)   # Deleted when resolved
```

Sticky violations are **struck through** (~~message~~) rather than deleted when no longer reported. This preserves history.

**Consider**: Add `sticky` option to our `Annotation` model.

### Inline Comments: Position Calculation

For PR review comments, Danger calculates the **position in the unified diff**:

```ruby
def find_position_in_diff(file, line)
  # Parse @@ -start,count +start,count @@ headers
  # Calculate position relative to diff hunk
end
```

GitHub requires `position` (line number within the diff), not absolute line numbers.

### Out-of-Range Messages

Danger's `dismiss_out_of_range_messages` option handles annotations on lines **not in the diff**:

```ruby
github.dismiss_out_of_range_messages  # Ignore entirely
github.dismiss_out_of_range_messages({ warning: true, error: false })  # Per-level
```

Options:
1. **Dismiss**: Don't post at all
2. **Fallback**: Move to main comment (default Danger behavior)
3. **Use Checks API**: Can annotate any line (our advantage!)

**Our advantage**: The Checks API can annotate ANY line, not just diff lines.

### CLI Options for Comment Behavior

Danger provides flexibility via CLI flags:

| Flag | Behavior |
|------|----------|
| (default) | Update existing comment in place |
| `--new-comment` | Create new comment, keep old ones |
| `--remove-previous-comments` | Delete old comments, create fresh at end |

**Adopt this**: Add `commentMode` option: `.update`, `.append`, `.replace`

### Forked PR Handling

Danger catches write failures on forked PRs:

```ruby
def submit_pull_request_status!
  client.create_status(...)
rescue StandardError => e
  # For public repos: expected (read-only token)
  # For private repos: unexpected (should have write access)
end
```

**Our approach**: Detect fork context early, fallback to stdout output.

### Summary: What to Adopt

| Danger Feature | Our Implementation |
|----------------|-------------------|
| `danger_id` for multi-instance | ✅ `identifier` parameter |
| HTML marker in comments | ✅ HTML comment (`<!-- -->`) |
| Sticky violations | 🆕 Add `sticky` option |
| `dismiss_out_of_range` | 🆕 Use Checks API instead (better!) |
| Comment modes (new/update/remove) | 🆕 Add `commentMode` option |
| Position calculation for inline | ⚠️ Only needed for PRReviewReporter |
| Message equivalence check | ✅ Content hash comparison |

### What We Do Better

1. **Checks API**: Danger doesn't use it; we make it primary
2. **Any-line annotations**: Checks API can annotate lines outside diff
3. **No Node.js**: Pure Swift, no runtime dependencies
4. **Modern Swift**: async/await, Sendable, structured concurrency

---

## Related Work

### Danger Ecosystem
- **Danger Ruby** (https://github.com/danger/danger) - Original Ruby implementation, full-featured
- **Danger JS** (https://github.com/danger/danger-js) - JavaScript implementation, used as runtime by Danger Swift
- **Danger Swift** (https://github.com/danger/swift) - Swift implementation, requires Danger JS as dependency
- **danger-swift-xcodesummary** (https://github.com/f-meloni/danger-swift-xcodesummary) - Danger plugin for Xcode build results

### Other Tools
- **reviewdog** (https://github.com/reviewdog/reviewdog) - Go tool, supports Check Run annotations
- **xcresulttool** (https://github.com/kishikawakatsumi/xcresulttool) - GitHub Action for xcresult → Check Run
- **XCResultKit** (https://github.com/davidahouse/XCResultKit) - Swift library for parsing xcresult (potential companion library)
- **xcparse** (https://github.com/ChargePoint/xcparse) - CLI + Swift framework for parsing xcresult

## Reference Projects

- **swift-ejson** (https://github.com/diogot/swift-ejson) - Reference for Swift 6.2 cross-platform project structure, CI configuration, and build scripts

---

## Future Considerations

- **GitLab support**: Could add GitLab reporters later (separate module)
- **Bitbucket support**: Similar pattern
- **Local reporter**: Output to terminal for local development
- **JSON reporter**: Machine-readable output for other tools
- **GitHub Enterprise support**: Add API base URL overrides and validation when expanding beyond github.com
