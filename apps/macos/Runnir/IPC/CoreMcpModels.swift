import Foundation

/// What the Core asks the app for an MCP tool
/// (docs/superpowers/specs/2026-11-09-mcp-full-control-design.md).
enum CoreMcpTool: Equatable, Sendable {
    case listValueSets
    case setValues
    /// The registered workspaces.
    case listWorkspaces
    /// A workspace ready to use: its window opened when none shows it.
    case openWorkspace
    /// Start a local run as Run Locally does.
    case startLocalRun
}

/// A name and its value from an MCP client. Its description never shows the
/// value, so a secret cannot end up in a log by printing the request.
struct CoreMcpValue: Equatable, Sendable, CustomStringConvertible {
    let name: String
    let value: String
    var description: String { "\(name)=…" }
}

/// A call of an MCP client, waiting in the Core for the app's answer.
struct CoreMcpRequest: Equatable, Identifiable, Sendable {
    let id: String
    /// The client's name from its initialize request ("claude-code").
    let client: String
    let tool: CoreMcpTool
    /// A registered workspace's folder or its name.
    let repository: String
    /// "Repository" or an environment's name; empty for a list.
    let set: String
    let secrets: [CoreMcpValue]
    let variables: [CoreMcpValue]
    /// The tool changes something: refused while actions are turned off.
    var action = false
    /// For `.startLocalRun`.
    var start: CoreMcpLocalRunStart?
    /// When the Core stops waiting and tells the client nothing happened,
    /// unless the app claimed the request first.
    var expiresAt: Date?
    /// Only says that the request with this id no longer waits: what asks
    /// about it comes down.
    var withdrawn = false
}

/// A local run an MCP client asks for.
struct CoreMcpLocalRunStart: Equatable, Sendable {
    /// nil: the branch's default scenario.
    var scenario: CoreScenario?
    /// The workflows by path, file name or name, each with its job ids;
    /// empty: what the scenario starts that can run here.
    var workflows: [(workflow: String, jobs: [String])] = []
    /// Whose values the run takes when the plan leaves it open.
    var environment: String?
    var allowMissingValues = false
    var macosWithoutSandbox = false

    static func == (a: Self, b: Self) -> Bool {
        a.scenario == b.scenario && a.environment == b.environment && a.allowMissingValues == b.allowMissingValues
            && a.macosWithoutSandbox == b.macosWithoutSandbox
            && a.workflows.map(\.workflow) == b.workflows.map(\.workflow) && a.workflows.map(\.jobs) == b.workflows.map(\.jobs)
    }
}

struct CoreMcpWorkspace: Equatable, Sendable {
    let name: String
    let path: String
    let workspaceID: UUID
    /// A window shows it.
    let open: Bool
}

struct CoreMcpOpenedWorkspace: Equatable, Sendable {
    let workspace: CoreMcpWorkspace
    /// The Core's id of its repository.
    let repositoryID: String
    let branch: String
}

struct CoreMcpLocalRunStarted: Equatable, Sendable {
    let workspace: String
    let executionID: String
    /// "secrets.API_KEY", "vars.REGION": given a value, and left empty.
    let passed: [String]
    let empty: [String]
    /// The environment whose values the run takes before the Repository's.
    let environment: String?
}

enum CoreMcpValueState: Equatable, Sendable {
    case saved
    /// An environment without its own value: its jobs get the Repository's.
    case fromRepository
    /// Some job would get an empty value.
    case missing
    /// No job needs a value here.
    case notNeeded
}

struct CoreMcpValueName: Equatable, Sendable {
    let name: String
    let secret: Bool
    let state: CoreMcpValueState
    /// A saved variable's value; never a secret's.
    var value: String? = nil
}

struct CoreMcpValueSet: Equatable, Sendable {
    /// "Repository" or an environment's name.
    let name: String
    var stale = false
    let names: [CoreMcpValueName]
}

struct CoreMcpValueSets: Equatable, Sendable {
    let workspace: String
    let sets: [CoreMcpValueSet]
}

struct CoreMcpSaved: Equatable, Sendable {
    let workspace: String
    let set: String
    let secrets: [String]
    let variables: [String]
}

/// The app's answer to an MCP request.
enum CoreMcpAnswer: Equatable, Sendable {
    case sets(CoreMcpValueSets)
    case saved(CoreMcpSaved)
    case workspaces([CoreMcpWorkspace])
    case workspace(CoreMcpOpenedWorkspace)
    case started(CoreMcpLocalRunStarted)
    /// Why not, said to the MCP client as it is.
    case refusal(String)
}
