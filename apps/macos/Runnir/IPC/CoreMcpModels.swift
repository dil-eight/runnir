import Foundation

/// A tool an MCP client called; the app answers it
/// (docs/superpowers/specs/2026-11-08-mcp-value-sets-design.md).
enum CoreMcpTool: Equatable, Sendable {
    case listValueSets
    case setValues
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
    /// Why not, said to the MCP client as it is.
    case refusal(String)
}
