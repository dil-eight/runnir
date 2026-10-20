import SwiftUI

/// Asks for one Run Workflow sheet; `workflowID` preselects a workflow.
struct RunWorkflowRequest: Identifiable, Equatable {
    let id = UUID()
    let workflowID: Int64?
}

/// State of the Run Workflow sheet: choose workflow, ref and inputs, review
/// what the Core validated, send it once, then find the run it started.
@MainActor
@Observable
final class DispatchFormModel {
    enum Step: Equatable {
        case editing
        case preparing
        case review(CorePreparedDispatch)
        case sending
        case waitingForRun
        case found(CoreWorkflowRun)
        case notFoundYet
        case failed(String)
    }

    let workspaceID: UUID
    let workflows: [CoreGitHubWorkflow]
    private(set) var selectedWorkflowID: Int64?
    private(set) var refs: CoreGitHubRefs?
    private(set) var ref = ""
    private(set) var definition: CoreDispatchDefinition?
    private(set) var isLoadingDefinition = false
    var values: [String: String] = [:]
    private(set) var problems: [String] = []
    private(set) var step: Step = .editing

    @ObservationIgnored private let hub: CoreHub
    @ObservationIgnored private let currentBranch: String
    @ObservationIgnored private var definitionGeneration = 0
    /// The defaults of the loaded definition, to tell typed values apart.
    @ObservationIgnored private var loadedDefaults: [String: String] = [:]

    init(workspaceID: UUID, hub: CoreHub, workflows: [CoreGitHubWorkflow], workflowID: Int64?, currentBranch: String) {
        self.workspaceID = workspaceID
        self.hub = hub
        self.workflows = workflows.filter { $0.state == "active" }
        self.currentBranch = currentBranch
        selectedWorkflowID = workflowID ?? self.workflows.first?.id
    }

    var selectedWorkflow: CoreGitHubWorkflow? { workflows.first { $0.id == selectedWorkflowID } }

    /// Loads refs, picks the current branch when GitHub has it (else the
    /// default branch), then the workflow's definition at that ref.
    func load() async {
        let refs = await hub.refs(workspaceID: workspaceID)
        self.refs = refs
        if refs.access == .ok {
            ref = refs.branches.contains(currentBranch) ? currentBranch : refs.defaultBranch
        }
        await loadDefinition()
    }

    func select(workflowID: Int64) {
        selectedWorkflowID = workflowID
        Task { await loadDefinition() }
    }

    func select(ref: String) {
        self.ref = ref
        Task { await loadDefinition() }
    }

    private func loadDefinition() async {
        definitionGeneration += 1
        let generation = definitionGeneration
        problems = []
        guard let workflow = selectedWorkflow, !ref.isEmpty else { definition = nil; return }
        isLoadingDefinition = true
        let loaded = await hub.describeDispatch(workspaceID: workspaceID, workflowPath: workflow.path, ref: ref)
        guard generation == definitionGeneration else { return }
        isLoadingDefinition = false
        definition = loaded
        let defaults = Self.initialValues(for: loaded.inputs)
        values = Self.carryOver(values, previousDefaults: loadedDefaults, into: defaults, inputs: loaded.inputs)
        loadedDefaults = defaults
    }

    /// Keeps what the user changed for inputs that still exist after a branch
    /// or workflow change; untouched inputs take the new defaults. A choice
    /// keeps its value only when it is still one of the options.
    static func carryOver(_ current: [String: String], previousDefaults: [String: String],
                          into defaults: [String: String], inputs: [CoreDispatchInput]) -> [String: String] {
        var values = defaults
        for input in inputs {
            guard let previous = current[input.name], previous != previousDefaults[input.name] else { continue }
            switch input.kind {
            case .choice where !input.options.contains(previous): continue
            case .boolean where previous != "true" && previous != "false": continue
            default: values[input.name] = previous
            }
        }
        return values
    }

    /// GitHub's own defaults: the declared default, false for a boolean, the
    /// first option for a choice.
    static func initialValues(for inputs: [CoreDispatchInput]) -> [String: String] {
        var values: [String: String] = [:]
        for input in inputs {
            switch input.kind {
            case .boolean: values[input.name] = input.defaultValue == "true" ? "true" : "false"
            case .choice: values[input.name] = input.defaultValue.isEmpty ? (input.options.first ?? "") : input.defaultValue
            default: values[input.name] = input.defaultValue
            }
        }
        return values
    }

    /// Required inputs still empty; the Core re-checks everything.
    var missingRequired: [String] {
        (definition?.inputs ?? []).filter { $0.required && (values[$0.name] ?? "").isEmpty }.map(\.name)
    }

    var canReview: Bool {
        definition?.dispatchable == true && definition?.access == .ok && missingRequired.isEmpty && !isLoadingDefinition && step == .editing
    }

    /// The inputs to send: every known input with a value. Empty values are
    /// left out so GitHub applies the workflow's defaults.
    var inputsToSend: [String: String] {
        let known = Set((definition?.inputs ?? []).map(\.name))
        return values.filter { known.contains($0.key) && !$0.value.isEmpty }
    }

    func review() async {
        guard canReview, let workflow = selectedWorkflow else { return }
        step = .preparing
        let prepared = await hub.prepareDispatch(workspaceID: workspaceID, workflowID: workflow.id, ref: ref, inputs: inputsToSend)
        if prepared.access != .ok {
            step = .failed(Self.describe(prepared.access))
        } else if !prepared.problems.isEmpty || prepared.dispatchID == nil {
            problems = prepared.problems
            step = .editing
        } else {
            step = .review(prepared)
        }
    }

    func backToEditing() {
        step = .editing
    }

    /// Sends the reviewed dispatch once, then looks for the run it started.
    func confirm() async {
        guard case .review(let prepared) = step, let dispatchID = prepared.dispatchID, let workflow = selectedWorkflow else { return }
        let known = Set(hub.session(for: workspaceID)?.runs.map(\.id) ?? [])
        step = .sending
        guard let result = await hub.confirmDispatch(workspaceID: workspaceID, dispatchID: dispatchID) else {
            step = .failed("This confirmation expired or was already used, so nothing was sent. Review the run again.")
            return
        }
        if let rejection = result.rejection {
            step = .failed("GitHub refused to start the workflow: \(rejection)")
            return
        }
        guard result.access == .ok, let dispatchedAt = result.dispatchedAt else {
            step = .failed(Self.describe(result.access) + " The workflow may not have started; check Runs before trying again.")
            return
        }
        step = .waitingForRun
        if let run = await hub.locateDispatchedRun(workspaceID: workspaceID, workflowID: workflow.id, ref: ref,
                                                   dispatchedAt: dispatchedAt, knownRunIDs: known, reportedRunID: result.runID) {
            step = .found(run)
        } else {
            step = .notFoundYet
        }
    }

    static func describe(_ access: CoreGitHubAccess) -> String {
        switch access {
        case .ok: ""
        case .noRemote: "This working tree has no GitHub remote."
        case .signedOut, .tokenRejected: "Connect GitHub to run workflows."
        case .notVisible: "Runnir can't see this repository or the workflow on that ref."
        case .rateLimited: "GitHub is limiting requests. Try again in a moment."
        case .unavailable: "GitHub could not be reached."
        }
    }
}

/// The Run Workflow sheet.
struct RunWorkflowSheet: View {
    @State var model: DispatchFormModel
    let showRun: (CoreWorkflowRun) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "play.circle").foregroundStyle(RunnirTheme.primary)
                Text("Run Workflow").font(.system(size: 16, weight: .semibold))
            }.padding(20)
            DesignDivider()
            ScrollView { content.padding(20) }.frame(minHeight: 260, maxHeight: 460)
            DesignDivider()
            HStack(spacing: 8) {
                Spacer()
                footer
            }.buttonStyle(DesignButtonStyle()).padding(16)
        }
        .frame(width: 540)
        .background(RunnirTheme.background)
        .foregroundStyle(RunnirTheme.foreground)
        .task { await model.load() }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .editing, .preparing:
            form
        case .review(let prepared):
            review(prepared)
        case .sending:
            progress("Sending the request to GitHub...")
        case .waitingForRun:
            progress("GitHub accepted the request. Waiting for the run to start...")
        case .found(let run):
            VStack(alignment: .leading, spacing: 12) {
                Label("Run #\(run.runNumber) started", systemImage: "checkmark.circle").foregroundStyle(RunnirTheme.success)
                RunRow(run: run)
            }
        case .notFoundYet:
            Label("GitHub accepted the request, but the run has not appeared yet. It will show in Runs when it starts.",
                  systemImage: "clock").font(.system(size: 13))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(RunnirTheme.warning).font(.system(size: 13))
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.workflows.isEmpty {
                Text("No active workflows on GitHub for this repository.").foregroundStyle(RunnirTheme.secondaryForeground)
            }
            Picker("Workflow", selection: Binding(get: { model.selectedWorkflowID ?? -1 }, set: { model.select(workflowID: $0) })) {
                ForEach(model.workflows) { workflow in Text(workflow.name).tag(workflow.id) }
            }.disabled(model.workflows.isEmpty)
            if let refs = model.refs {
                if refs.access == .ok {
                    Picker("Branch or tag", selection: Binding(get: { model.ref }, set: { model.select(ref: $0) })) {
                        Section("Branches") { ForEach(refs.branches, id: \.self) { Text($0).tag($0) } }
                        if !refs.tags.isEmpty { Section("Tags") { ForEach(refs.tags, id: \.self) { Text($0).tag($0) } } }
                    }
                } else {
                    Text(DispatchFormModel.describe(refs.access)).foregroundStyle(RunnirTheme.warning)
                }
            } else {
                progress("Loading branches...")
            }
            DesignDivider()
            definitionSection
            if !model.problems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(RunnirTheme.warning)
                    }
                }.font(.system(size: 12))
            }
        }.font(.system(size: 13))
    }

    @ViewBuilder private var definitionSection: some View {
        if model.isLoadingDefinition {
            progress("Reading the workflow on \(model.ref)...")
        } else if let definition = model.definition {
            if definition.access != .ok {
                Text(DispatchFormModel.describe(definition.access)).foregroundStyle(RunnirTheme.warning)
            } else if let parseError = definition.parseError {
                Text(parseError).foregroundStyle(RunnirTheme.warning)
            } else if !definition.dispatchable {
                Text("This workflow has no workflow_dispatch trigger on \(model.ref), so it cannot be started by hand there.")
                    .foregroundStyle(RunnirTheme.secondaryForeground)
            } else if definition.inputs.isEmpty {
                Text("This workflow takes no inputs.").foregroundStyle(RunnirTheme.secondaryForeground)
            } else {
                ForEach(definition.inputs) { input in field(for: input) }
            }
        }
    }

    @ViewBuilder private func field(for input: CoreDispatchInput) -> some View {
        let binding = Binding(get: { model.values[input.name] ?? "" }, set: { model.values[input.name] = $0 })
        VStack(alignment: .leading, spacing: 4) {
            switch input.kind {
            case .boolean:
                Toggle(isOn: Binding(get: { binding.wrappedValue == "true" }, set: { binding.wrappedValue = $0 ? "true" : "false" })) {
                    Text(input.name)
                }.toggleStyle(.checkbox)
            case .choice:
                Picker(input.name + (input.required ? " *" : ""), selection: binding) {
                    ForEach(input.options, id: \.self) { Text($0).tag($0) }
                }
            default:
                LabeledContent(input.name + (input.required ? " *" : "")) {
                    TextField(input.defaultValue.isEmpty ? (input.kind == .number ? "Number" : "Value") : input.defaultValue, text: binding)
                        .textFieldStyle(.roundedBorder)
                }
            }
            if !input.description.isEmpty {
                Text(input.description).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
        }
    }

    private func review(_ prepared: CorePreparedDispatch) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check before running").font(.system(size: 14, weight: .semibold))
            LabeledContent("Workflow", value: model.selectedWorkflow?.name ?? "")
            LabeledContent("File", value: prepared.workflowPath)
            LabeledContent("Branch or tag", value: model.ref)
            let inputs = model.inputsToSend.sorted { $0.key < $1.key }
            if inputs.isEmpty {
                LabeledContent("Inputs", value: "Workflow defaults")
            } else {
                ForEach(inputs, id: \.key) { name, value in LabeledContent(name, value: value) }
            }
            Text("GitHub runs the version of this workflow on \(model.ref), not your local copy. Running starts it on GitHub's runners; it is not undone by closing Runnir.")
                .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
            if let expires = prepared.expiresAt {
                Text("This review is valid until \(expires.formatted(date: .omitted, time: .shortened)).")
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
        }.font(.system(size: 13))
    }

    @ViewBuilder private var footer: some View {
        switch model.step {
        case .editing, .preparing:
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Review...") { Task { await model.review() } }
                .buttonStyle(DesignButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                .disabled(!model.canReview)
        case .review:
            Button("Back") { model.backToEditing() }
            Button("Run Workflow") { Task { await model.confirm() } }
                .buttonStyle(DesignButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
        case .sending, .waitingForRun:
            Button("Close") { dismiss() }
        case .found(let run):
            Button("Close") { dismiss() }
            Button("Show Run") { showRun(run); dismiss() }.buttonStyle(DesignButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
        case .notFoundYet:
            Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
        case .failed:
            Button("Close") { dismiss() }
            Button("Back") { model.backToEditing() }
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(text).font(.system(size: 12)) }
    }
}
