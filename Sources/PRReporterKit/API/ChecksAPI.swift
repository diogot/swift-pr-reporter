#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation

/// API client for GitHub Check Runs.
public actor ChecksAPI {
    private let api: GitHubAPI
    private let owner: String
    private let repo: String

    /// Creates a new Checks API client.
    /// - Parameters:
    ///   - api: The underlying GitHub API client.
    ///   - owner: Repository owner.
    ///   - repo: Repository name.
    public init(api: GitHubAPI, owner: String, repo: String) {
        self.api = api
        self.owner = owner
        self.repo = repo
    }

    /// Create a new check run.
    /// - Parameter request: The check run creation request.
    /// - Returns: The created check run.
    public func createCheckRun(_ request: CreateCheckRunRequest) async throws -> CheckRun {
        try await api.post("/repos/\(owner)/\(repo)/check-runs", body: request)
    }

    /// Update an existing check run.
    /// - Parameters:
    ///   - checkRunID: The ID of the check run to update.
    ///   - request: The update request.
    /// - Returns: The updated check run.
    public func updateCheckRun(_ checkRunID: Int, _ request: UpdateCheckRunRequest) async throws -> CheckRun {
        try await api.patch("/repos/\(owner)/\(repo)/check-runs/\(checkRunID)", body: request)
    }

    /// List check runs for a specific ref.
    /// - Parameters:
    ///   - ref: Git reference (SHA, branch name, or tag name).
    ///   - checkName: Optional filter by check name.
    /// - Returns: List of check runs.
    public func listCheckRuns(ref: String, checkName: String? = nil) async throws -> [CheckRun] {
        var query: [String: String] = [:]
        if let name = checkName {
            query["check_name"] = name
        }

        let response: CheckRunsResponse = try await api.get(
            "/repos/\(owner)/\(repo)/commits/\(ref)/check-runs",
            query: query.isEmpty ? nil : query
        )
        return response.checkRuns
    }

    /// Find a check run by external ID.
    /// - Parameters:
    ///   - ref: Git reference.
    ///   - externalID: The external ID to search for.
    /// - Returns: The matching check run, if found.
    public func findCheckRun(ref: String, externalID: String) async throws -> CheckRun? {
        let checkRuns = try await listCheckRuns(ref: ref)
        return checkRuns.first { $0.externalId == externalID }
    }
}

// MARK: - Request/Response Models

/// Request to create a check run.
public struct CreateCheckRunRequest: Encodable, Sendable {
    public let name: String
    public let headSha: String
    public let externalId: String?
    public let status: CheckRunStatus?
    public let conclusion: CheckRunConclusion?
    public let startedAt: String?
    public let completedAt: String?
    public let output: CheckRunOutput?

    public init(
        name: String,
        headSha: String,
        externalId: String? = nil,
        status: CheckRunStatus? = nil,
        conclusion: CheckRunConclusion? = nil,
        startedAt: String? = nil,
        completedAt: String? = nil,
        output: CheckRunOutput? = nil
    ) {
        self.name = name
        self.headSha = headSha
        self.externalId = externalId
        self.status = status
        self.conclusion = conclusion
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.output = output
    }
}

/// Request to update a check run.
public struct UpdateCheckRunRequest: Encodable, Sendable {
    public let name: String?
    public let status: CheckRunStatus?
    public let conclusion: CheckRunConclusion?
    public let completedAt: String?
    public let output: CheckRunOutput?

    public init(
        name: String? = nil,
        status: CheckRunStatus? = nil,
        conclusion: CheckRunConclusion? = nil,
        completedAt: String? = nil,
        output: CheckRunOutput? = nil
    ) {
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.completedAt = completedAt
        self.output = output
    }
}

/// Check run status.
public enum CheckRunStatus: String, Codable, Sendable {
    case queued
    case inProgress = "in_progress"
    case completed
}

/// Check run conclusion.
public enum CheckRunConclusion: String, Codable, Sendable {
    case success
    case failure
    case neutral
    case cancelled
    case skipped
    case timedOut = "timed_out"
    case actionRequired = "action_required"
}

/// Output for a check run.
public struct CheckRunOutput: Encodable, Sendable {
    public let title: String
    public let summary: String
    public let text: String?
    public let annotations: [CheckRunAnnotation]?

    public init(
        title: String,
        summary: String,
        text: String? = nil,
        annotations: [CheckRunAnnotation]? = nil
    ) {
        self.title = title
        self.summary = summary
        self.text = text
        self.annotations = annotations
    }
}

/// Annotation for a check run.
public struct CheckRunAnnotation: Encodable, Sendable {
    public let path: String
    public let startLine: Int
    public let endLine: Int
    public let startColumn: Int?
    public let endColumn: Int?
    public let annotationLevel: String
    public let message: String
    public let title: String?

    public init(
        path: String,
        startLine: Int,
        endLine: Int,
        startColumn: Int? = nil,
        endColumn: Int? = nil,
        annotationLevel: String,
        message: String,
        title: String? = nil
    ) {
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.startColumn = startColumn
        self.endColumn = endColumn
        self.annotationLevel = annotationLevel
        self.message = message
        self.title = title
    }

    /// Create from an Annotation model.
    public static func from(_ annotation: Annotation) -> CheckRunAnnotation {
        CheckRunAnnotation(
            path: annotation.path,
            startLine: annotation.line,
            endLine: annotation.endLine ?? annotation.line,
            startColumn: annotation.column,
            endColumn: annotation.column,
            annotationLevel: annotation.level.rawValue,
            message: annotation.message,
            title: annotation.title
        )
    }
}

/// A check run response.
public struct CheckRun: Decodable, Sendable {
    public let id: Int
    public let name: String
    public let headSha: String
    public let externalId: String?
    public let status: CheckRunStatus
    public let conclusion: CheckRunConclusion?
    public let htmlUrl: String?
    public let output: CheckRunOutputResponse?

    public var url: URL? {
        htmlUrl.flatMap { URL(string: $0) }
    }
}

/// Output response from a check run.
public struct CheckRunOutputResponse: Decodable, Sendable {
    public let title: String?
    public let summary: String?
    public let annotationsCount: Int?
}

/// Response wrapper for listing check runs.
struct CheckRunsResponse: Decodable, Sendable {
    let totalCount: Int
    let checkRuns: [CheckRun]
}
