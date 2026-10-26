import LocalAuthentication
import SwiftUI

/// Settings › Runs: confirm starting a workflow by hand with Touch
/// ID, or the Mac's password where Touch ID is not set up. Off by default.
enum ManualRunSettings {
    static let confirmWithTouchIDKey = "manualRuns.confirmWithTouchID"

    static func confirmWithTouchID(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: confirmWithTouchIDKey)
    }
}

/// The Mac's owner confirming an action with Touch ID or the login password.
enum OwnerConfirmation: Equatable {
    case confirmed
    /// Cancelled, or not recognized.
    case declined
    /// The Mac cannot ask; the reason is the system's.
    case unavailable(String)

    /// Asks only when Settings turns it on.
    @MainActor static func ifEnabled(reason: String, defaults: UserDefaults = .standard,
                                     ask: @MainActor (String) async -> OwnerConfirmation = { await OwnerConfirmation.ask(reason: $0) }) async -> OwnerConfirmation {
        guard ManualRunSettings.confirmWithTouchID(in: defaults) else { return .confirmed }
        return await ask(reason)
    }

    /// `reason` completes the system's "Runnir is trying to ...".
    @MainActor static func ask(reason: String) async -> OwnerConfirmation {
        let context = LAContext()
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            return .unavailable(problem?.localizedDescription ?? "Touch ID and the password are not available.")
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .confirmed : .declined
        } catch {
            return .declined
        }
    }

    /// Whether this Mac has Touch ID set up, for the Settings caption.
    @MainActor static var hasTouchID: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }
}

/// Asks for one Run Workflow sheet; `workflowID` preselects a workflow.
struct RunWorkflowRequest: Identifiable, Equatable {
    let id = UUID()
    let workflowID: Int64?
    /// A preset to apply once the workflow's definition is loaded.
    var presetID: UUID? = nil
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

    /// The workspace or the repository without a local clone to run on.
    let target: CoreHub.GitHubTarget
    let workflows: [CoreGitHubWorkflow]
    private(set) var selectedWorkflowID: Int64?
    private(set) var refs: CoreGitHubRefs?
    private(set) var ref = ""
    private(set) var definition: CoreDispatchDefinition?
    private(set) var isLoadingDefinition = false
    var values: [String: String] = [:]
    private(set) var problems: [String] = []
    private(set) var step: Step = .editing
    /// The preset last applied or saved, when it belongs to this workflow.
    private(set) var appliedPresetID: UUID?
    /// What a preset could not apply: a branch or inputs that no longer exist.
    private(set) var presetNotes: [String] = []
    /// The dispatches already sent from this Mac for the selected workflow,
    /// newest first; none for a repository without a local clone.
    private(set) var history: [CoreDispatchRecord] = []
    /// Where the form's values came from after an earlier dispatch was
    /// applied, and what was left out of it.
    private(set) var historyNote: String?
    /// Why GitHub refused, with the step that fixes it, shown as an alert.
    var accessHelp: GitHubAccessHelp?
    /// Touch ID (or the password) is being asked for; Run Workflow waits.
    private(set) var isAskingOwner = false

    @ObservationIgnored let presets: DispatchPresetLibrary?
    @ObservationIgnored private let hub: CoreHub
    @ObservationIgnored private let currentBranch: String
    /// A preset whose input values wait for the definition at its branch.
    @ObservationIgnored private var pendingPreset: DispatchPreset?
    @ObservationIgnored private var definitionGeneration = 0
    /// The defaults of the loaded definition, to tell typed values apart.
    @ObservationIgnored private var loadedDefaults: [String: String] = [:]

    @ObservationIgnored private let initialPresetID: UUID?
    /// Asks the Mac's owner before the request is sent, when Settings says
    /// so; tests replace it.
    @ObservationIgnored var confirmOwner: @MainActor (String) async -> OwnerConfirmation = { await OwnerConfirmation.ifEnabled(reason: $0) }

    convenience init(workspaceID: UUID, hub: CoreHub, workflows: [CoreGitHubWorkflow], workflowID: Int64?, currentBranch: String,
                     presets: DispatchPresetLibrary? = nil, presetID: UUID? = nil) {
        self.init(target: .workspace(workspaceID), hub: hub, workflows: workflows, workflowID: workflowID,
                  currentBranch: currentBranch, presets: presets, presetID: presetID)
    }

    /// Presets belong to a workspace, so a repository without a local clone
    /// has none.
    init(target: CoreHub.GitHubTarget, hub: CoreHub, workflows: [CoreGitHubWorkflow], workflowID: Int64?, currentBranch: String,
         presets: DispatchPresetLibrary? = nil, presetID: UUID? = nil) {
        self.initialPresetID = presetID
        self.target = target
        self.hub = hub
        if case .workspace = target { self.presets = presets } else { self.presets = nil }
        self.workflows = workflows.filter(\.canBeStartedByHand)
        self.currentBranch = currentBranch
        selectedWorkflowID = workflowID ?? self.workflows.first?.id
    }

    var selectedWorkflow: CoreGitHubWorkflow? { workflows.first { $0.id == selectedWorkflowID } }

    /// The workspace presets are kept for; nil for a repository without a
    /// local clone.
    var workspaceID: UUID? {
        if case .workspace(let id) = target { return id }
        return nil
    }

    /// Loads refs, picks the current branch when GitHub has it (else the
    /// default branch), then the workflow's definition at that ref.
    func load() async {
        presets?.prepare()
        let refs = await hub.refs(target: target)
        self.refs = refs
        if refs.access == .ok {
            ref = refs.branches.contains(currentBranch) ? currentBranch : refs.defaultBranch
        }
        await loadDefinition()
        if let initialPresetID, let preset = (repositoryPresets + availablePresets).first(where: { $0.id == initialPresetID }) {
            apply(preset)
        }
        await loadHistory()
    }

    /// Reads the earlier dispatches of the selected workflow from the Core.
    func loadHistory() async {
        guard let workspaceID, let workflow = selectedWorkflow else {
            history = []
            return
        }
        let records = await hub.dispatchHistory(workspaceID: workspaceID, workflowPath: workflow.path)
        guard workflow.id == selectedWorkflowID else { return }
        history = records
    }

    /// Fills the form with an earlier dispatch: its branch, then its values
    /// over the workflow's defaults, saying what no longer fits. Nothing is
    /// sent: the form is reviewed and confirmed like any other run.
    func applyHistory(_ record: CoreDispatchRecord) {
        guard let workspaceID else { return }
        apply(DispatchHistory.preset(from: record, workspaceID: workspaceID), noun: "earlier dispatch")
        // An earlier dispatch is not a preset: there is nothing to update or rename.
        appliedPresetID = nil
        var note = "Values from the dispatch sent \(record.sentAt.formatted(date: .abbreviated, time: .shortened))."
        if let leftOut = DispatchHistory.leftOut(record) { note += " \(leftOut)." }
        historyNote = note
    }

    func select(workflowID: Int64) {
        selectedWorkflowID = workflowID
        appliedPresetID = nil
        pendingPreset = nil
        presetNotes = []
        historyNote = nil
        history = []
        Task {
            await loadDefinition()
            await loadHistory()
        }
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
        let loaded = await hub.describeDispatch(target: target, workflowPath: workflow.path, ref: ref)
        guard generation == definitionGeneration else { return }
        isLoadingDefinition = false
        definition = loaded
        let defaults = Self.initialValues(for: loaded.inputs)
        values = Self.carryOver(values, previousDefaults: loadedDefaults, into: defaults, inputs: loaded.inputs)
        loadedDefaults = defaults
        // A preset waits for a definition it can be checked against.
        if let preset = pendingPreset, loaded.access == .ok, loaded.parseError == nil {
            pendingPreset = nil
            overlay(preset, inputs: loaded.inputs)
        }
    }

    // MARK: Presets

    /// Presets saved for the selected workflow in this workspace.
    var availablePresets: [DispatchPreset] {
        guard let path = selectedWorkflow?.path, let presets, let workspaceID else { return [] }
        return presets.presets(workspaceID: workspaceID, workflowPath: path)
    }

    /// Presets the repository shares for the selected workflow, usable ones
    /// only, as the Core last read them.
    var repositoryPresets: [DispatchPreset] {
        guard let path = selectedWorkflow?.path, let workspaceID, let session = hub.session(for: workspaceID) else { return [] }
        return session.launchPresets.filter { $0.isUsable && $0.workflowPath == path }
            .sorted(by: CoreLaunchPreset.menuOrder).map { $0.dispatchPreset(workspaceID: workspaceID) }
    }

    /// The preset menu works when either source has something to offer:
    /// presets on this Mac can be off (their file is unreadable) while the
    /// repository's are fine.
    var canChoosePreset: Bool {
        presets?.isAvailable == true || !repositoryPresets.isEmpty
    }

    var appliedPreset: DispatchPreset? {
        guard let appliedPresetID else { return nil }
        return (repositoryPresets + availablePresets).first { $0.id == appliedPresetID }
    }

    /// The applied preset comes from the repository: it is changed by editing
    /// its file, never here.
    var appliedPresetIsShared: Bool {
        guard let appliedPresetID else { return false }
        return repositoryPresets.contains { $0.id == appliedPresetID }
    }

    /// The file of the applied repository preset, for the menu's hint.
    var appliedPresetFile: String? {
        guard let appliedPresetID, let workspaceID, let session = hub.session(for: workspaceID) else { return nil }
        return session.launchPresets.first { CoreLaunchPreset.presetID(workspaceID: workspaceID, path: $0.path) == appliedPresetID }?.path
    }

    /// The values a preset would keep: every known input that does not look
    /// secret.
    var presetValues: [String: String] {
        let saved = Set((definition?.inputs ?? []).filter { !DispatchPreset.looksSecret($0) }.map(\.name))
        return values.filter { saved.contains($0.key) }
    }

    /// Inputs with a value that a preset leaves out because they look secret.
    var inputsLeftOutOfPresets: [String] {
        (definition?.inputs ?? []).filter { DispatchPreset.looksSecret($0) && !(values[$0.name] ?? "").isEmpty }.map(\.name)
    }

    /// The form no longer matches what applying the preset gives: its branch
    /// when it has one, the workflow's defaults with its values on top. Inputs
    /// that look secret are left out on both sides.
    var presetIsModified: Bool {
        guard let preset = appliedPreset else { return false }
        if !preset.ref.isEmpty && preset.ref != ref { return true }
        let inputs = definition?.inputs ?? []
        let secret = Set(inputs.filter(DispatchPreset.looksSecret).map(\.name))
        let kept = Set(presetValues.keys)
        var expected = Self.initialValues(for: inputs).filter { kept.contains($0.key) }
        for (name, value) in preset.inputs where kept.contains(name) { expected[name] = value }
        return expected != presetValues || preset.inputs.keys.contains { !kept.contains($0) && !secret.contains($0) }
    }

    var canSavePreset: Bool {
        presets?.isAvailable == true && selectedWorkflow != nil && !ref.isEmpty
            && definition?.access == .ok && definition?.dispatchable == true && !isLoadingDefinition
    }

    /// Applies a preset: its branch, then the workflow's defaults with the
    /// preset's values on top. What no longer fits is listed in `presetNotes`.
    func apply(_ preset: DispatchPreset, noun: String = "preset") {
        appliedPresetID = preset.id
        presetNotes = []
        historyNote = nil
        let known = (refs?.branches ?? []) + (refs?.tags ?? [])
        // A preset without a branch keeps the form's.
        if !preset.ref.isEmpty, preset.ref != ref, known.contains(preset.ref) {
            pendingPreset = preset
            select(ref: preset.ref)
            return
        }
        if !preset.ref.isEmpty, preset.ref != ref {
            presetNotes.append("The \(noun)'s branch \(preset.ref) no longer exists on GitHub; \(ref) is kept.")
        }
        if let definition, !isLoadingDefinition, definition.access == .ok, definition.parseError == nil {
            overlay(preset, inputs: definition.inputs)
        } else {
            pendingPreset = preset
        }
    }

    private func overlay(_ preset: DispatchPreset, inputs: [CoreDispatchInput]) {
        var next = Self.initialValues(for: inputs)
        let byName = Dictionary(uniqueKeysWithValues: inputs.map { ($0.name, $0) })
        for (name, value) in preset.inputs.sorted(by: { $0.key < $1.key }) {
            guard let input = byName[name] else {
                presetNotes.append("\"\(name)\" is no longer an input of this workflow on \(ref).")
                continue
            }
            if DispatchPreset.looksSecret(input) {
                // GitHub logs dispatch inputs; presets on this Mac never hold
                // such values, a file in the repository might.
                presetNotes.append("Not applied because it looks secret: \(name).")
                continue
            }
            switch input.kind {
            case .choice where !input.options.contains(value):
                presetNotes.append("\"\(name)\" no longer offers \(value); the default is used.")
            case .boolean where value != "true" && value != "false":
                presetNotes.append("\"\(name)\" is now a boolean; the default is used.")
            default:
                next[name] = value
            }
        }
        values = next
    }

    /// Saves the current branch and values as a new preset and applies it.
    @discardableResult
    func saveAsPreset(named name: String) -> Bool {
        guard canSavePreset, let workflow = selectedWorkflow, let workspaceID,
              let preset = presets?.add(name: name, workspaceID: workspaceID, workflowPath: workflow.path, ref: ref, inputs: presetValues) else {
            return false
        }
        appliedPresetID = preset.id
        presetNotes = []
        return true
    }

    /// Writes the current branch and values into the applied preset.
    @discardableResult
    func updateAppliedPreset() -> Bool {
        guard canSavePreset, !appliedPresetIsShared, let id = appliedPresetID,
              presets?.update(id, ref: ref, inputs: presetValues) == true else { return false }
        presetNotes = []
        return true
    }

    @discardableResult
    func renameAppliedPreset(to name: String) -> Bool {
        guard let id = appliedPresetID, !appliedPresetIsShared else { return false }
        return presets?.rename(id, to: name) == true
    }

    func deleteAppliedPreset() {
        guard let id = appliedPresetID, !appliedPresetIsShared, presets?.delete(id) == true else { return }
        appliedPresetID = nil
        presetNotes = []
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
        let prepared = await hub.prepareDispatch(target: target, workflowID: workflow.id, ref: ref, inputs: inputsToSend)
        if prepared.access != .ok {
            step = .failed(Self.describe(prepared.access))
            await explain(prepared.access)
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
        guard case .review(let prepared) = step, let dispatchID = prepared.dispatchID, let workflow = selectedWorkflow,
              !isAskingOwner else { return }
        isAskingOwner = true
        let owner = await confirmOwner("start \u{201C}\(workflow.name)\u{201D} on \(ref)")
        isAskingOwner = false
        switch owner {
        case .confirmed:
            break
        case .declined:
            // Back to the review; nothing was sent.
            return
        case .unavailable(let reason):
            step = .failed("Manual runs are set to be confirmed with Touch ID, but this Mac can't ask: \(reason) Nothing was sent. Turn the setting off in Settings › Runs, or set up Touch ID.")
            return
        }
        guard case .review = step else { return }
        step = .sending
        let known = await hub.knownRunIDs(target)
        guard let result = await hub.confirmDispatch(target: target, dispatchID: dispatchID) else {
            step = .failed("This confirmation expired or was already used, so nothing was sent. Review the run again.")
            return
        }
        if let rejection = result.rejection {
            step = .failed("GitHub refused to start the workflow: \(rejection)")
            return
        }
        guard result.access == .ok, let dispatchedAt = result.dispatchedAt else {
            step = .failed(Self.describe(result.access) + " The workflow may not have started; check Runs before trying again.")
            await explain(result.access)
            return
        }
        step = .waitingForRun
        if let run = await hub.locateDispatchedRun(target: target, workflowID: workflow.id, ref: ref,
                                                   dispatchedAt: dispatchedAt, knownRunIDs: known, reportedRunID: result.runID) {
            step = .found(run)
            // The Core recorded the run itself when GitHub named it; otherwise it learns which run this was.
            if let workspaceID, let historyID = result.historyID, result.runID == nil {
                await hub.linkDispatchRun(workspaceID: workspaceID, historyID: historyID, runID: run.id)
            }
        } else {
            step = .notFoundYet
        }
        await loadHistory()
    }

    /// The repository's GitHub name, for messages.
    var repositoryName: String? {
        switch target {
        case .workspace(let id): hub.session(for: id)?.githubRepository
        case .repository(let ref): ref.fullName
        }
    }

    /// Turns a refusal the user can fix into `accessHelp`; a missing
    /// permission is checked against the repository first, to tell an
    /// owner's pending approval from the user's missing write access.
    private func explain(_ access: CoreGitHubAccess) async {
        guard GitHubAccessHelp.needsExplaining(access) else { return }
        let details = access == .permissionMissing ? await hub.githubRepository(target: target) : nil
        switch target {
        case .workspace(let id):
            accessHelp = hub.accessHelp(access, workspaceID: id, purpose: .run, details: details)
        case .repository(let ref):
            accessHelp = GitHubAccessHelp.forAccess(access, repository: repositoryName, purpose: .run, details: details,
                                                    credential: hub.credentialKind(for: ref.serverID), server: hub.serverRef(for: ref.serverID))
        }
    }

    static func describe(_ access: CoreGitHubAccess) -> String {
        switch access {
        case .ok: ""
        case .noRemote: "This working tree has no GitHub remote."
        case .signedOut: "Connect GitHub to run workflows."
        case .tokenRejected: "GitHub no longer accepts the saved sign-in. Sign in again to run workflows."
        case .notVisible: "Runnir can't see this repository or the workflow on that ref."
        case .permissionMissing: "GitHub did not allow starting this workflow: Runnir Desktop or your account lacks a permission."
        case .rateLimited: "GitHub is limiting requests. Try again in a moment."
        case .unavailable: "GitHub could not be reached."
        }
    }
}

/// The Run Workflow sheet.
struct RunWorkflowSheet: View {
    @State var model: DispatchFormModel
    /// For the sign-in sheet an access alert may offer.
    var github: GitHubSession? = nil
    let showRun: (CoreWorkflowRun) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var presetPrompt: PresetPrompt?
    @State private var presetName = ""
    @State private var comparing = false
    @State private var confirmingDelete = false

    private enum PresetPrompt: Identifiable {
        case save, rename
        var id: Self { self }
    }

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
                if case .editing = model.step, model.presets != nil {
                    Text(presetFootnote).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                footer
            }.buttonStyle(DesignButtonStyle()).padding(16)
        }
        .frame(width: 540)
        .background(RunnirTheme.background)
        .foregroundStyle(RunnirTheme.foreground)
        .task { await model.load() }
        .githubAccessAlert(Binding(get: { model.accessHelp }, set: { model.accessHelp = $0 }), github: github)
        .alert(presetPrompt == .rename ? "Rename Preset" : "Save Preset", isPresented: Binding(
            get: { presetPrompt != nil }, set: { if !$0 { presetPrompt = nil } })) {
            TextField("Name", text: $presetName)
            Button(presetPrompt == .rename ? "Rename" : "Save") {
                if presetPrompt == .rename { model.renameAppliedPreset(to: presetName) } else { model.saveAsPreset(named: presetName) }
                presetPrompt = nil
            }
            .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { presetPrompt = nil }
        } message: {
            Text(presetPrompt == .rename ? "A new name for this preset." : "The branch and input values are saved on this Mac.")
        }
        .confirmationDialog("Delete the preset \(model.appliedPreset?.name ?? "")?", isPresented: $confirmingDelete) {
            Button("Delete Preset", role: .destructive) { model.deleteAppliedPreset() }
        } message: {
            Text("Only the saved values are removed. Runs started with it are not affected.")
        }
    }

    private var presetFootnote: String {
        let leftOut = model.inputsLeftOutOfPresets
        guard !leftOut.isEmpty else {
            return "Presets stay on this Mac. Inputs that look like secrets are never saved; do not put secrets in other inputs."
        }
        return "Presets stay on this Mac. Not saved because they look secret: \(leftOut.joined(separator: ", "))."
    }

    @ViewBuilder private var presetControl: some View {
        if let presets = model.presets {
            LabeledContent("Preset") {
                Menu {
                    if model.repositoryPresets.isEmpty {
                        ForEach(model.availablePresets) { presetButton($0) }
                    } else {
                        Section("In This Repository") {
                            ForEach(model.repositoryPresets) { presetButton($0) }
                        }
                        if !model.availablePresets.isEmpty {
                            Section("On This Mac") {
                                ForEach(model.availablePresets) { presetButton($0) }
                            }
                        }
                    }
                    if !model.availablePresets.isEmpty || !model.repositoryPresets.isEmpty { Divider() }
                    Button("Save as New Preset...") { presetName = ""; presetPrompt = .save }.disabled(!model.canSavePreset)
                    if let applied = model.appliedPreset {
                        if model.appliedPresetIsShared {
                            Text("Edit \(model.appliedPresetFile ?? ".runnir/launches") to change this preset")
                        } else {
                            Button("Update \"\(applied.name)\"") { model.updateAppliedPreset() }
                                .disabled(!model.canSavePreset || !model.presetIsModified)
                            Button("Rename \"\(applied.name)\"...") { presetName = applied.name; presetPrompt = .rename }
                            Button("Delete \"\(applied.name)\"...", role: .destructive) { confirmingDelete = true }
                        }
                    }
                } label: {
                    Label(presetTitle, systemImage: "bookmark")
                }
                .fixedSize()
                .handPointer()
                .disabled(!model.canChoosePreset)
            }
            if let problem = presets.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(RunnirTheme.warning)
            }
            ForEach(model.presetNotes, id: \.self) { note in
                Label(note, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(RunnirTheme.warning)
            }
        }
    }

    /// Earlier dispatches of this workflow: apply one to the form, or compare two.
    @ViewBuilder private var historyControl: some View {
        if model.workspaceID != nil {
            LabeledContent("History") {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(model.history.prefix(15)) { record in
                            Button { model.applyHistory(record) } label: { Text(DispatchHistory.menuTitle(record)) }
                                .help(DispatchHistory.leftOut(record) ?? "Fills the form with these values; nothing is sent")
                        }
                    } label: {
                        Label(model.history.isEmpty ? "Nothing sent from Runnir yet" : "Earlier runs", systemImage: "clock.arrow.circlepath")
                    }
                    .fixedSize().handPointer().disabled(model.history.isEmpty)
                    Button("Compare...") { comparing = true }
                        .buttonStyle(.link).handPointer().disabled(model.history.count < 2)
                        .popover(isPresented: $comparing) { DispatchComparisonView(records: model.history) }
                }
            }
            if let note = model.historyNote {
                Label(note, systemImage: "clock").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
        }
    }

    private func presetButton(_ preset: DispatchPreset) -> some View {
        // No hand pointer: an item of the preset menu.
        Button { model.apply(preset) } label: {
            if preset.id == model.appliedPresetID { Label(preset.name, systemImage: "checkmark") } else { Text(preset.name) }
        }
    }

    private var presetTitle: String {
        guard let applied = model.appliedPreset else {
            return model.availablePresets.isEmpty && model.repositoryPresets.isEmpty ? "No presets" : "Choose a preset"
        }
        return model.presetIsModified ? "\(applied.name) · modified" : applied.name
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
            Label("GitHub accepted the request, but the run has not appeared yet. It will show with the recent runs when it starts.",
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
            }.handPointer().disabled(model.workflows.isEmpty)
            if let refs = model.refs {
                if refs.access == .ok {
                    Picker("Branch or tag", selection: Binding(get: { model.ref }, set: { model.select(ref: $0) })) {
                        Section("Branches") { ForEach(refs.branches, id: \.self) { Text($0).tag($0) } }
                        if !refs.tags.isEmpty { Section("Tags") { ForEach(refs.tags, id: \.self) { Text($0).tag($0) } } }
                    }.handPointer()
                } else {
                    Text(DispatchFormModel.describe(refs.access)).foregroundStyle(RunnirTheme.warning)
                }
            } else {
                progress("Loading branches...")
            }
            presetControl
            historyControl
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
                }.toggleStyle(.checkbox).pointerStyle(.link)
            case .choice:
                Picker(input.name + (input.required ? " *" : ""), selection: binding) {
                    ForEach(input.options, id: \.self) { Text($0).tag($0) }
                }.handPointer()
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
            Button("Run Workflow") { Task { await model.confirm() } }.disabled(model.isAskingOwner)
                .buttonStyle(DesignButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
        case .sending, .waitingForRun:
            Button("Close") { dismiss() }
        case .found(let run):
            Button("Close") { dismiss() }
            Button("Show Run") { showRun(run); dismiss() }.buttonStyle(DesignButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
        case .notFoundYet:
            Button("Close") { dismiss() }.buttonStyle(DesignButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
        case .failed:
            Button("Close") { dismiss() }
            Button("Back") { model.backToEditing() }
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(text).font(.system(size: 12)) }
    }
}


/// Two earlier dispatches side by side: what changed between them.
private struct DispatchComparisonView: View {
    let records: [CoreDispatchRecord]
    @State private var firstID: Int64
    @State private var secondID: Int64

    init(records: [CoreDispatchRecord]) {
        self.records = records
        _firstID = State(initialValue: records[0].id)
        _secondID = State(initialValue: records[min(1, records.count - 1)].id)
    }

    private var first: CoreDispatchRecord? { records.first { $0.id == firstID } }
    private var second: CoreDispatchRecord? { records.first { $0.id == secondID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("First", selection: $firstID) {
                ForEach(records) { Text(DispatchHistory.menuTitle($0)).tag($0.id) }
            }.handPointer()
            Picker("Second", selection: $secondID) {
                ForEach(records) { Text(DispatchHistory.menuTitle($0)).tag($0.id) }
            }.handPointer()
            if let first, let second {
                let rows = DispatchHistory.compare(first, second)
                Text(DispatchHistory.changedCount(rows) == 0 ? "Everything sent is the same."
                     : "\(DispatchHistory.changedCount(rows)) of \(rows.count) differ.")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text("First").foregroundStyle(RunnirTheme.secondaryForeground)
                        Text("Second").foregroundStyle(RunnirTheme.secondaryForeground)
                    }
                    ForEach(rows) { row in
                        GridRow {
                            Text(row.name).font(.system(size: 12, weight: row.changed ? .semibold : .regular))
                            Text(row.first ?? "not sent").foregroundStyle(row.first == nil ? RunnirTheme.mutedForeground : RunnirTheme.foreground)
                            Text(row.second ?? "not sent").foregroundStyle(row.second == nil ? RunnirTheme.mutedForeground : RunnirTheme.foreground)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.vertical, 2).padding(.horizontal, 6)
                        .background(row.changed ? RunnirTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                if let note = [first, second].compactMap(DispatchHistory.leftOut).first {
                    Text(note).font(.system(size: 11)).foregroundStyle(RunnirTheme.mutedForeground)
                }
            }
        }
        .padding(16).frame(width: 520)
    }
}
