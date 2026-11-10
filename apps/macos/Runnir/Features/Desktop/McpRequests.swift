import Foundation
import Observation

/// Why an MCP request is refused, said to the client as it is.
struct McpRefusal: Error, Equatable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

/// A workspace ready to answer: the window showing it, its workflows and
/// its repository in the Core.
struct McpWorkspaceContext {
    let windowID: UUID
    let workflows: [CoreWorkflow]
    var repositoryID = ""
    var branch = ""
}

/// An MCP client's name as people know it.
enum McpClientName {
    static func display(_ name: String) -> String {
        switch name.lowercased() {
        case "": "An MCP client"
        case "claude-code", "claude code": "Claude Code"
        case "codex", "codex-mcp-client": "Codex"
        default: name
        }
    }
}

/// What the handler needs from the desktop.
@MainActor
protocol McpDesktop: AnyObject {
    var mcpWorkspaces: [WorkspaceRecord] { get }
    var localRunValues: any LocalRunValueStoring { get }
    /// The change waiting for Save in a workspace window, if any.
    var mcpPrompt: McpValuesPrompt? { get set }
    /// The run without the macOS sandbox waiting for Run, if any.
    var mcpRunPrompt: McpUnsandboxedPrompt? { get set }
    /// Settings › MCP › Allow actions.
    var mcpActionsAllowed: Bool { get }
    /// The hub local runs start through; nil before the Core runs.
    var mcpHub: CoreHub? { get }
    /// A window shows the workspace.
    func mcpIsOpen(_ workspaceID: UUID) -> Bool
    /// Shows the workspace's local run in the window, as after Run Locally.
    func mcpShowLocalRun(windowID: UUID)
    /// Opens a window of the workspace when none shows it, brings it to the
    /// front when asked, and waits until the Core has read its workflows.
    func mcpContext(for workspace: WorkspaceRecord, front: Bool) async -> Result<McpWorkspaceContext, McpRefusal>
    /// The environments a local run can take, as Secrets and Variables shows them.
    func mcpEnvironments(for workspaceID: UUID) async -> [String]?
}

/// Finds the workspace an MCP client names: a folder (or a folder inside
/// it, an agent's working directory) or a workspace's name.
enum McpWorkspaceResolver {
    static func resolve(_ repository: String, in workspaces: [WorkspaceRecord]) -> Result<WorkspaceRecord, McpRefusal> {
        let asked = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        if asked.hasPrefix("/") || asked.hasPrefix("~") {
            let path = canonical((asked as NSString).expandingTildeInPath)
            let containing = workspaces.filter { path == canonical($0.path) || path.hasPrefix(canonical($0.path) + "/") }
            if let match = containing.max(by: { $0.path.count < $1.path.count }) { return .success(match) }
        } else {
            let named = workspaces.filter { $0.name.caseInsensitiveCompare(asked) == .orderedSame }
            if named.count == 1 { return .success(named[0]) }
            if named.count > 1 {
                return .failure(McpRefusal("Several workspaces are named \(asked): \(named.map(\.path).sorted().joined(separator: ", ")). Give the folder instead."))
            }
        }
        let known = workspaces.map { "\($0.name) (\($0.path))" }.sorted()
        let list = known.isEmpty ? "none yet" : known.joined(separator: ", ")
        return .failure(McpRefusal("Runnir has no workspace for \(asked). Registered workspaces: \(list). Import the folder in Runnir first."))
    }

    private static func canonical(_ path: String) -> String {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return standard.count > 1 && standard.hasSuffix("/") ? String(standard.dropLast()) : standard
    }
}

/// The value sets of a workspace as runnir_list_value_sets returns them.
enum McpValueSetsBuilder {
    @MainActor
    static func sets(of model: WorkspaceValuesModel, workspace: String) -> CoreMcpValueSets {
        let shownBefore = model.environment
        defer { model.select(shownBefore) }
        var sets: [CoreMcpValueSet] = []
        for environment in [nil] + model.environments.map(Optional.some) {
            model.select(environment)
            let names = (model.secrets + model.variables).map { row -> CoreMcpValueName in
                let state: CoreMcpValueState = row.saved ? .saved : row.inherited ? .fromRepository : row.needed ? .missing : .notNeeded
                let secret = row.key.kind == .secret
                return CoreMcpValueName(name: row.key.name, secret: secret, state: state,
                                        value: secret || !row.saved ? nil : model.shown[row.key])
            }
            sets.append(CoreMcpValueSet(name: environment ?? McpRequestHandler.repositorySet,
                                        stale: environment.map(model.staleEnvironments.contains) ?? false, names: names))
        }
        return CoreMcpValueSets(workspace: workspace, sets: sets)
    }
}

/// A change an MCP client asks for, shown in the workspace window until the
/// user saves or cancels it, or it expires.
@MainActor
@Observable
final class McpValuesPrompt: Identifiable {
    struct Row: Identifiable, Equatable {
        let kind: LocalRunValueKind
        let name: String
        let value: String
        /// The set already has a value for it.
        let replaces: Bool
        /// A secret shown in clear; a variable always is.
        var shown: Bool
        var id: String { name }
    }

    let id: String
    let client: String
    let workspace: WorkspaceRecord
    let windowID: UUID
    /// The set's name as Runnir shows it: "Repository" or the environment's.
    let setName: String
    let environment: String?
    private(set) var rows: [Row]
    private(set) var isSaving = false
    @ObservationIgnored private var continuation: CheckedContinuation<CoreMcpAnswer, Never>?
    @ObservationIgnored private var answer: CoreMcpAnswer?

    init(request: CoreMcpRequest, workspace: WorkspaceRecord, windowID: UUID, environment: String?,
         values: [(kind: LocalRunValueKind, name: String, value: String)], saved: Set<LocalRunValueKey>) {
        id = request.id
        client = McpClientName.display(request.client)
        self.workspace = workspace
        self.windowID = windowID
        self.environment = environment
        setName = environment ?? McpRequestHandler.repositorySet
        rows = values.map { value in
            Row(kind: value.kind, name: value.name, value: value.value,
                replaces: saved.contains(LocalRunValueKey(kind: value.kind, name: value.name, environment: environment)),
                shown: value.kind == .variable)
        }.sorted { ($0.name, $0.kind.rawValue) < ($1.name, $1.kind.rawValue) }
    }

    func toggleShown(_ name: String) {
        guard let index = rows.firstIndex(where: { $0.name == name && $0.kind == .secret }) else { return }
        rows[index].shown.toggle()
    }

    /// Writes every value to the set, then answers the names.
    func save(store: any LocalRunValueStoring) async {
        guard answer == nil, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        var saved: [Row] = []
        for row in rows {
            do {
                try await store.save(workspaceID: workspace.id, key: LocalRunValueKey(kind: row.kind, name: row.name, environment: environment),
                                     value: row.value)
                saved.append(row)
            } catch {
                let done = saved.map(\.name).joined(separator: ", ")
                finish(.refusal("Keychain did not save \(row.name)" + (done.isEmpty ? "; nothing was saved." : "; saved before it: \(done).")))
                return
            }
        }
        finish(.saved(CoreMcpSaved(workspace: workspace.name, set: setName,
                                   secrets: saved.filter { $0.kind == .secret }.map(\.name),
                                   variables: saved.filter { $0.kind == .variable }.map(\.name))))
    }

    func cancel() { finish(.refusal("Cancelled in Runnir. Nothing was saved.")) }

    func expire() { finish(.refusal("Nobody answered in Runnir within 5 minutes; nothing was saved.")) }

    /// Waits for Save, Cancel or the end of the prompt's life.
    func decision() async -> CoreMcpAnswer {
        if let answer { return answer }
        return await withCheckedContinuation { continuation = $0 }
    }

    private func finish(_ answer: CoreMcpAnswer) {
        guard self.answer == nil else { return }
        self.answer = answer
        continuation?.resume(returning: answer)
        continuation = nil
    }
}

/// Answers the calls of MCP clients for the desktop
/// (docs/superpowers/specs/2026-11-08-mcp-value-sets-design.md).
@MainActor
final class McpRequestHandler {
    static let repositorySet = "Repository"

    private weak var desktop: (any McpDesktop)?
    /// Shorter than the Core's five minutes, so a change the client was told
    /// expired is never saved later.
    private let promptLifetime: Duration

    init(desktop: any McpDesktop, promptLifetime: Duration = .seconds(290)) {
        self.desktop = desktop
        self.promptLifetime = promptLifetime
    }

    static let actionsOff = "Actions are turned off in Runnir › Settings › MCP › Allow actions, so Runnir only answers reading tools."

    func answer(_ request: CoreMcpRequest) async -> CoreMcpAnswer {
        guard let desktop else { return .refusal("Runnir is closing.") }
        if request.tool == .listWorkspaces {
            return .workspaces(desktop.mcpWorkspaces.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map {
                CoreMcpWorkspace(name: $0.name, path: $0.path, workspaceID: $0.id, open: desktop.mcpIsOpen($0.id))
            })
        }
        if (request.action || request.tool == .setValues || request.tool == .startLocalRun), !desktop.mcpActionsAllowed {
            return .refusal(Self.actionsOff)
        }
        let workspace: WorkspaceRecord
        switch McpWorkspaceResolver.resolve(request.repository, in: desktop.mcpWorkspaces) {
        case .success(let found): workspace = found
        case .failure(let refusal): return .refusal(refusal.reason)
        }
        // Names are checked before the window comes up for a change.
        var values: [(kind: LocalRunValueKind, name: String, value: String)] = []
        if request.tool == .setValues {
            switch upperCased(request) {
            case .success(let named): values = named
            case .failure(let refusal): return .refusal(refusal.reason)
            }
        }
        let front = request.tool == .setValues || request.start?.macosWithoutSandbox == true
        let context: McpWorkspaceContext
        switch await desktop.mcpContext(for: workspace, front: front) {
        case .success(let found): context = found
        case .failure(let refusal): return .refusal(refusal.reason)
        }
        switch request.tool {
        case .openWorkspace:
            guard !context.repositoryID.isEmpty else { return .refusal("Runnir Core has not opened \(workspace.name) yet. Try again in a moment.") }
            return .workspace(CoreMcpOpenedWorkspace(
                workspace: CoreMcpWorkspace(name: workspace.name, path: workspace.path, workspaceID: workspace.id, open: true),
                repositoryID: context.repositoryID, branch: context.branch))
        case .startLocalRun:
            guard let hub = desktop.mcpHub else { return .refusal("Runnir Core is not running.") }
            let starter = McpLocalRunStarter(hub: hub, values: desktop.localRunValues, promptLifetime: promptLifetime) { [weak desktop] prompt in
                desktop?.mcpRunPrompt = prompt
            }
            let answer = await starter.start(request.start ?? CoreMcpLocalRunStart(), client: request.client, workspace: workspace,
                                             windowID: context.windowID, busy: desktop.mcpRunPrompt != nil)
            if case .started = answer { desktop.mcpShowLocalRun(windowID: context.windowID) }
            return answer
        case .listWorkspaces:
            return .refusal("Runnir could not list its workspaces.")
        case .listValueSets, .setValues:
            break
        }
        let model = WorkspaceValuesModel()
        await model.load(workspaceID: workspace.id, workflows: context.workflows, store: desktop.localRunValues)
        if let error = model.error { return .refusal(error) }
        if let environments = await desktop.mcpEnvironments(for: workspace.id) { model.update(environments: environments) }
        if request.tool == .listValueSets {
            return .sets(McpValueSetsBuilder.sets(of: model, workspace: workspace.name))
        }
        return await set(request, values: values, workspace: workspace, context: context, model: model, desktop: desktop)
    }

    private func set(_ request: CoreMcpRequest, values: [(kind: LocalRunValueKind, name: String, value: String)],
                     workspace: WorkspaceRecord, context: McpWorkspaceContext, model: WorkspaceValuesModel,
                     desktop: any McpDesktop) async -> CoreMcpAnswer {
        let asked = request.set.trimmingCharacters(in: .whitespacesAndNewlines)
        let environment: String?
        if asked.caseInsensitiveCompare(Self.repositorySet) == .orderedSame {
            environment = nil
        } else if let match = model.environments.first(where: { $0.caseInsensitiveCompare(asked) == .orderedSame }) {
            environment = match
        } else {
            let sets = ([Self.repositorySet] + model.environments).joined(separator: ", ")
            return .refusal("\(workspace.name) has no set named \(asked). Its sets: \(sets).")
        }
        guard desktop.mcpPrompt == nil else {
            return .refusal("Runnir is already asking about other values; answer that first, then try again.")
        }
        let saved: Set<LocalRunValueKey>
        do { saved = try await desktop.localRunValues.keys(workspaceID: workspace.id) } catch {
            return .refusal("Keychain did not list the saved values.")
        }
        let prompt = McpValuesPrompt(request: request, workspace: workspace, windowID: context.windowID,
                                     environment: environment, values: values, saved: saved)
        desktop.mcpPrompt = prompt
        let expiry = Task { [promptLifetime] in
            try? await Task.sleep(for: promptLifetime)
            if !Task.isCancelled { prompt.expire() }
        }
        let answer = await prompt.decision()
        expiry.cancel()
        if desktop.mcpPrompt === prompt { desktop.mcpPrompt = nil }
        return answer
    }

    /// GitHub keeps names upper-cased, and so do the sets; two names that
    /// differ only in case are one.
    private func upperCased(_ request: CoreMcpRequest) -> Result<[(kind: LocalRunValueKind, name: String, value: String)], McpRefusal> {
        var out: [(kind: LocalRunValueKind, name: String, value: String)] = []
        var seen: Set<String> = []
        for (kind, values) in [(LocalRunValueKind.secret, request.secrets), (.variable, request.variables)] {
            for value in values {
                let name = value.name.uppercased()
                guard seen.insert(name).inserted else {
                    return .failure(McpRefusal("\(name) is given more than once (names are not case-sensitive)."))
                }
                out.append((kind, name, value.value))
            }
        }
        return .success(out)
    }
}
