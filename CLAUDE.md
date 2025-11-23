# CLAUDE.md - Project Context

## Project Overview

**swift-pr-reporter** is a pure Swift library for posting automated feedback to GitHub PRs - errors, warnings, and informational messages with support for updating/deleting on re-runs. The library module is named **PRReporterKit** following Apple-style framework naming conventions.

**Goal:** Replace Danger (Ruby/Node.js) with a native Swift solution for surfacing build/test results to GitHub.

**Scope:** This library handles **only GitHub posting**. A separate library will handle Xcode result parsing.

## Core Architecture

### Module Name: PRReporterKit

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

// Post summary
try await reporter.postSummary("""
## Build Results
- 1 warning

Build completed in 45 seconds.
""")
```

### Core Components

1. **Models**
   - `Annotation`: Feedback item with path, line, level, message, sticky flag
   - `GitHubContext`: Environment parsing for GitHub Actions
   - `ReportResult`: Counts of posted/updated/deleted annotations
   - `CommentMode`: Update/append/replace behavior
   - `RetryPolicy`: Exponential backoff configuration

2. **API Layer**
   - `GitHubAPI`: Actor-based REST client with retry and rate limiting
   - `ChecksAPI`: Check run creation/updates with annotation batching
   - `IssuesAPI`: PR comment CRUD operations
   - `PullRequestsAPI`: PR files, review comments, diff handling

3. **Reporters**
   - `CheckRunReporter`: Posts to Checks API (annotations in Checks tab + diff)
   - `PRCommentReporter`: Posts summary comments on PRs
   - `PRReviewReporter`: Posts inline review comments on specific diff lines

4. **Utilities**
   - `CommentMarker`: HTML comment markers for tracking bot comments
   - `DiffMapper`: Unified diff parsing and line-to-position mapping
   - `EnvironmentParser`: GitHub Actions env var parsing
   - `SafeLogger`: Token-redacting logger

## GitHub API Support

| API | Reporter | Use Case | Limitations |
|-----|----------|----------|-------------|
| Check Run Annotations | `CheckRunReporter` | Inline annotations in Checks tab + diff | Max 50 per request (batched automatically) |
| PR Review Comments | `PRReviewReporter` | Line comments in diff (review style) | Only on changed lines in diff |
| Issue Comments | `PRCommentReporter` | Summary comment on PR | Not line-specific |

## Comment Tracking Strategy

Uses **HTML comment markers** (invisible in rendered markdown) to identify bot comments:

```markdown
<!-- pr-reporter:xcode-build:abc123 -->
## Build Results
| Type | Count |
|------|-------|
| Errors | 1 |
| Warnings | 2 |
```

- `identifier`: User-provided string (e.g., "xcode-build", "swiftlint")
- `content-hash`: Hash of content for change detection

## Requirements

- **Swift 6.2** with strict concurrency
- **Platforms:** macOS 13+, Linux (Ubuntu 22.04+)
- **Zero external dependencies** - pure Swift with Foundation only
- **GitHub.com only** for v1; GitHub Enterprise support planned for future

## Dependencies

None. This library intentionally has zero external dependencies to:
- Simplify integration into any project
- Avoid version conflicts
- Ensure predictable builds on CI runners
- Support both macOS and Linux without dependency complications

## Development Guidelines

### Permissions Required

```yaml
permissions:
  checks: write        # For CheckRunReporter
  pull-requests: write # For PRReviewReporter, PRCommentReporter
```

### Testing Strategy

- Use Swift Testing framework with `#expect`
- `MockURLProtocol` for network-free unit tests
- Fixtures for GitHub event payloads, API responses, and diffs

### Error Handling

- Fork PRs have read-only tokens - detect and fail fast
- Rate limiting with exponential backoff
- Pagination for comment listing

## Installing Swift for Development

This project requires **Swift 6.2** or later.

### Option 1: Direct Download from swift.org (Recommended)

This is the most reliable method for getting Swift 6.2.1.

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

**For macOS:**

```bash
# Install Xcode Command Line Tools (includes Swift 6.2+)
xcode-select --install

# Or download the latest Swift toolchain from:
# https://www.swift.org/install/macos/
# and follow the installer instructions
```

### Option 2: Using Swiftly

Swiftly is the official Swift toolchain manager for Linux. Note that it requires network access and may have connectivity issues in some environments.

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

### Option 3: Using swiftenv

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

### Additional System Dependencies

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

## Building and Testing

### Build the library
```bash
swift build
```

### Run the test suite
```bash
swift test
```

### Run specific tests
```bash
# Run only annotation tests
swift test --filter AnnotationTests

# Run with verbose output
swift test -v
```

### Build in release mode
```bash
swift build -c release
```

## Project Structure

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
│   │   ├── GitHubAPI.swift
│   │   ├── GitHubAPIError.swift
│   │   ├── ChecksAPI.swift
│   │   ├── PullRequestsAPI.swift
│   │   └── IssuesAPI.swift
│   ├── Reporters/
│   │   ├── Reporter.swift
│   │   ├── CheckRunReporter.swift
│   │   ├── PRReviewReporter.swift
│   │   └── PRCommentReporter.swift
│   └── Utilities/
│       ├── CommentMarker.swift
│       ├── DiffMapper.swift
│       ├── EnvironmentParser.swift
│       └── SafeLogger.swift
Tests/
└── PRReporterKitTests/
    ├── Fixtures/
    │   ├── events/
    │   ├── responses/
    │   └── diffs/
    ├── Models/
    ├── API/
    ├── Utilities/
    └── Concurrency/
```

## Usage Examples

### Basic Check Run Reporter

```swift
import PRReporterKit

let context = try GitHubContext.fromEnvironment()

let reporter = CheckRunReporter(
    context: context,
    name: "SwiftLint",
    identifier: "swiftlint"
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

### PR Comment Reporter

```swift
let commentReporter = PRCommentReporter(
    context: context,
    identifier: "build-summary",
    commentMode: .update  // Updates existing comment instead of creating new
)

try await commentReporter.postSummary("""
## Build Results

| Metric | Value |
|--------|-------|
| Errors | 0 |
| Warnings | 5 |
| Duration | 2m 30s |
""")
```

### PR Review Reporter (Inline Comments)

```swift
let reviewReporter = PRReviewReporter(
    context: context,
    identifier: "code-review",
    outOfRangeStrategy: .fallbackToComment  // Comments outside diff go to PR comment
)

try await reviewReporter.report(annotations)
```

## Troubleshooting

### Build Errors

**Error: `swift: command not found`**
- Solution: Install Swift 6.2 using one of the methods above

**Error: `no such module 'PRReporterKit'`**
- Solution: Run `swift build` first to compile the module

### Test Failures

**Error: Network-related test failures**
- Tests use `MockURLProtocol` and should not require network access
- If tests fail, ensure test fixtures are present in `Tests/PRReporterKitTests/Fixtures/`

### GitHub API Errors

**Error: `403 - Resource not accessible by integration`**
- Solution: Ensure workflow has correct permissions:
  ```yaml
  permissions:
    checks: write
    pull-requests: write
  ```

**Error: `Cannot write to PR from fork`**
- Expected behavior: Fork PRs have read-only tokens
- The library detects this and throws `ContextError.readOnlyToken`

## References

- **GitHub Checks API:** https://docs.github.com/en/rest/checks
- **GitHub Pull Requests API:** https://docs.github.com/en/rest/pulls
- **GitHub Issues API:** https://docs.github.com/en/rest/issues
- **Danger Ruby (inspiration):** https://github.com/danger/danger
