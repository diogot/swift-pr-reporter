#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

/// Parses GitHub Actions environment variables to create GitHubContext.
enum EnvironmentParser {
    /// Parse context from GitHub Actions environment variables.
    /// - Returns: A configured GitHubContext.
    /// - Throws: ContextError if required variables are missing.
    static func parseFromEnvironment() throws -> GitHubContext {
        let environment = ProcessInfo.processInfo.environment

        // Required variables
        guard let token = environment["GITHUB_TOKEN"] else {
            throw ContextError.missingVariable("GITHUB_TOKEN")
        }

        guard let repository = environment["GITHUB_REPOSITORY"] else {
            throw ContextError.missingVariable("GITHUB_REPOSITORY")
        }

        guard let commitSHA = environment["GITHUB_SHA"] else {
            throw ContextError.missingVariable("GITHUB_SHA")
        }

        guard let eventName = environment["GITHUB_EVENT_NAME"] else {
            throw ContextError.missingVariable("GITHUB_EVENT_NAME")
        }

        // Optional variables
        let headRef = environment["GITHUB_HEAD_REF"]
        let baseRef = environment["GITHUB_BASE_REF"]
        let runID = environment["GITHUB_RUN_ID"].flatMap { Int($0) }
        let runAttempt = environment["GITHUB_RUN_ATTEMPT"].flatMap { Int($0) } ?? 1

        // Parse event payload for PR number and fork detection
        var pullRequest: Int?
        var isFork = false

        if let eventPath = environment["GITHUB_EVENT_PATH"] {
            let eventPayload = try parseEventPayload(at: eventPath)
            pullRequest = eventPayload.pullRequestNumber
            isFork = eventPayload.isFork
        }

        // HEAD_REF presence can also indicate a fork PR
        if headRef != nil && !isFork {
            // If HEAD_REF is set but we couldn't determine fork status from payload,
            // we might be in a PR context. Check if head repo differs from base repo.
            // For now, keep isFork as determined from payload.
        }

        return GitHubContext(
            token: token,
            repository: repository,
            pullRequest: pullRequest,
            commitSHA: commitSHA,
            headRef: headRef,
            baseRef: baseRef,
            runID: runID,
            runAttempt: runAttempt,
            eventName: eventName,
            isFork: isFork
        )
    }

    /// Event payload parsing result.
    private struct EventPayload {
        let pullRequestNumber: Int?
        let isFork: Bool
    }

    /// Parse the event payload JSON file.
    private static func parseEventPayload(at path: String) throws -> EventPayload {
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: path) else {
            throw ContextError.invalidEventPayload("Event file not found at \(path)")
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ContextError.invalidEventPayload("Could not read event file: \(error.localizedDescription)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ContextError.invalidEventPayload("Event file is not valid JSON")
        }

        // Try to extract PR number from various event types
        var pullRequestNumber: Int?

        // pull_request event
        if let pullRequest = json["pull_request"] as? [String: Any],
           let number = pullRequest["number"] as? Int {
            pullRequestNumber = number
        }
        // issue_comment event on a PR
        else if let issue = json["issue"] as? [String: Any],
                let number = issue["number"] as? Int,
                issue["pull_request"] != nil {
            pullRequestNumber = number
        }
        // pull_request_review or pull_request_review_comment
        else if let number = json["number"] as? Int {
            pullRequestNumber = number
        }

        // Detect if this is a fork
        var isFork = false
        if let pullRequest = json["pull_request"] as? [String: Any],
           let head = pullRequest["head"] as? [String: Any],
           let base = pullRequest["base"] as? [String: Any] {

            // Check if head repo is different from base repo
            if let headRepo = head["repo"] as? [String: Any],
               let baseRepo = base["repo"] as? [String: Any],
               let headFullName = headRepo["full_name"] as? String,
               let baseFullName = baseRepo["full_name"] as? String {
                isFork = headFullName != baseFullName
            }

            // Also check the fork flag directly
            if let headRepo = head["repo"] as? [String: Any],
               let fork = headRepo["fork"] as? Bool {
                isFork = isFork || fork
            }
        }

        return EventPayload(pullRequestNumber: pullRequestNumber, isFork: isFork)
    }
}
