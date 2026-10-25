import AppKit
import Foundation

enum WorkspaceTab: Equatable {
    case editor, localRun
}

/// Asks for the Run Locally review of one workflow file.
struct LocalRunRequest: Identifiable, Equatable {
    let id = UUID()
    /// ".github/workflows/<name>", as the Core names workflows.
    let workflowID: String
    let jobID: String?
}

/// What to ask before quitting or closing a window stops local runs. The
/// Core cannot keep a run going without the app, and runs are never resumed.
struct LocalRunStopPrompt: Equatable {
    enum Action: Equatable {
        case quit, closeWindow, switchWorkspace
    }

    let action: Action
    /// One entry per run, such as "ci.yml in mobile-app".
    let runs: [String]

    var title: String {
        switch action {
        case .quit: runs.count == 1 ? "Quit Runnir and stop the local run?" : "Quit Runnir and stop \(runs.count) local runs?"
        case .closeWindow: "Close the window and stop the local run?"
        case .switchWorkspace: "Switch workspaces and stop the local run?"
        }
    }

    var detail: String {
        let list = ListFormatter.localizedString(byJoining: runs)
        let one = runs.count == 1
        switch action {
        case .quit:
            return "\(list) \(one ? "is" : "are") still going. Quitting stops \(one ? "it" : "them") and removes \(one ? "its" : "their") containers. Runnir does not resume runs."
        case .closeWindow:
            return "\(list) is still going. Closing the workspace's last window stops the run and removes its containers."
        case .switchWorkspace:
            return "\(list) is still going. Opening another workspace in this window closes this one, which stops the run and removes its containers."
        }
    }

    var confirmTitle: String {
        switch action {
        case .quit: "Stop and Quit"
        case .closeWindow: "Stop Run and Close"
        case .switchWorkspace: "Stop Run and Switch"
        }
    }

    /// The alert for the prompt. The stop button comes first and is marked
    /// destructive, so macOS gives it no Return key; Cancel takes Escape and
    /// the keyboard focus, so a stray Space keeps the run going.
    @MainActor static func alert(for prompt: LocalRunStopPrompt) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prompt.title
        alert.informativeText = prompt.detail
        let confirm = alert.addButton(withTitle: prompt.confirmTitle)
        confirm.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = cancel
        return alert
    }

    /// Shows the prompt as an alert; true when the user chose to stop.
    @MainActor static func ask(_ prompt: LocalRunStopPrompt) -> Bool {
        alert(for: prompt).runModal() == .alertFirstButtonReturn
    }
}

/// The user's choice in Settings: run with the act installed on this Mac
/// instead of the bundled one. Experimental and off by default.
enum LocalRunSettings {
    static let useInstalledActKey = "localRuns.useInstalledAct"

    static var useInstalledAct: Bool { UserDefaults.standard.bool(forKey: useInstalledActKey) }
}

/// One local run as the app follows it: the reviewed plan, job states and
/// the newest output lines, read from the Core until the run finishes.
@MainActor
@Observable
final class LocalRunModel {
    /// The app keeps as many lines as the Core does.
    static let maxLines = 5000

    let executionID: String
    let workspaceID: UUID
    private(set) var plan: CoreLocalRunPlan
    private(set) var lines: [CoreLocalRunLine] = []
    /// Earlier output was dropped to stay within the bound.
    private(set) var discarded = false
    private(set) var jobs: [CoreLocalRunJobStatus]
    private(set) var state: CoreExecutionState = .queued
    private(set) var phase: CoreLocalRunPhase = .queued
    private(set) var exitCode: Int?
    private(set) var failure: String?
    private(set) var cleanupProblem: String?
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    /// Set when the Core no longer knows the run, for example after it restarted.
    private(set) var lostMessage: String?
    private(set) var stopRequested = false
    private(set) var stopError: String?
    /// The job whose output is shown; nil shows everything.
    var selectedJobID: String?

    @ObservationIgnored private var lastSequence: UInt64 = 0
    @ObservationIgnored private var followTask: Task<Void, Never>?
    /// Called once when the Core reports the run finished.
    @ObservationIgnored var onFinish: (@MainActor (LocalRunModel) -> Void)?
    @ObservationIgnored private var reportedFinish = false
    @ObservationIgnored var pollInterval: Duration = .milliseconds(500)

    init(executionID: String, workspaceID: UUID, plan: CoreLocalRunPlan) {
        self.executionID = executionID
        self.workspaceID = workspaceID
        self.plan = plan
        jobs = plan.jobs.map { job in
            CoreLocalRunJobStatus(id: job.id, name: job.name, state: job.support == .unsupported ? .unsupported : .waiting, reason: job.reason)
        }
        selectedJobID = plan.jobs.first { $0.support != .unsupported }?.id
    }

    var isFinished: Bool { phase == .finished || lostMessage != nil }

    var visibleLines: [CoreLocalRunLine] {
        guard let selectedJobID else { return lines }
        return lines.filter { $0.jobID == selectedJobID }
    }

    func job(_ id: String) -> CoreLocalRunJobStatus? { jobs.first { $0.id == id } }

    /// Merges what the Core reported after `lastSequence`.
    func apply(_ output: CoreLocalRunOutput) {
        if output.discarded { discarded = true }
        let fresh = output.lines.filter { $0.sequence > lastSequence }
        lines.append(contentsOf: fresh)
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines)
            discarded = true
        }
        lastSequence = max(lastSequence, output.lastSequence, fresh.last?.sequence ?? 0)
        if !output.jobs.isEmpty { jobs = output.jobs }
        plan = output.plan.workflowID.isEmpty ? plan : output.plan
        state = output.state
        phase = output.phase
        exitCode = output.exitCode
        failure = output.message
        cleanupProblem = output.cleanupProblem
        startedAt = output.startedAt ?? startedAt
        finishedAt = output.finishedAt
        if phase == .finished, !reportedFinish {
            reportedFinish = true
            onFinish?(self)
        }
        if selectedJobID == nil || job(selectedJobID ?? "") == nil {
            selectedJobID = jobs.first { $0.state == .running }?.id ?? jobs.first { $0.state != .unsupported }?.id
        }
    }

    /// Reads the run from the Core until it finishes or the Core forgets it.
    func follow(hub: CoreHub) {
        followTask?.cancel()
        followTask = Task { [weak self, weak hub] in
            while let self, let hub, !Task.isCancelled, !self.isFinished {
                do {
                    self.apply(try await hub.localRunOutput(executionID: self.executionID, after: self.lastSequence))
                } catch CoreServiceError.notFound {
                    self.lostMessage = "Runnir Core stopped during this run, so its result is unknown. Runnir does not resume runs."
                } catch {
                    // The Core is restarting or busy; try again.
                }
                if self.isFinished { break }
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    func stopFollowing() {
        followTask?.cancel()
        followTask = nil
    }

    /// Asks the Core to stop the run. Act gets a moment to stop, then the
    /// run's containers are removed.
    func stop(hub: CoreHub) async {
        guard !isFinished, !stopRequested else { return }
        stopRequested = true
        stopError = nil
        if !(await hub.cancelExecution(executionID: executionID)) {
            stopRequested = false
            stopError = "The stop request did not reach Runnir Core. Try again."
        }
    }
}

/// The review before a local run (S10): the plan from the Core, the user's
/// job and event choice, and the trust confirmation.
@MainActor
@Observable
final class LocalRunReviewModel {
    let workspaceID: UUID
    let workflowID: String
    let jobs: [CoreJob]
    var jobID: String?
    var event: String?
    var trusted = false
    /// Values typed for this run, by name.
    var entered: [LocalRunValueKey: String] = [:]
    /// Save the typed values to the workspace when the run starts.
    var saveEntered = false
    /// The plan's names with a saved value.
    private(set) var saved: Set<LocalRunValueKey> = []
    /// Saved names whose value Keychain would not give.
    private(set) var refused: Set<LocalRunValueKey> = []
    private(set) var prepared: CorePreparedLocalRun?
    private(set) var error: String?
    private(set) var isPreparing = false
    private(set) var isStarting = false
    @ObservationIgnored private let hub: CoreHub
    @ObservationIgnored private let useInstalledAct: () -> Bool
    @ObservationIgnored private let values: any LocalRunValueStoring
    /// Saved values read for this review, each once; dropped with the sheet.
    @ObservationIgnored private var savedValues: [LocalRunValueKey: String] = [:]
    @ObservationIgnored private var generation = 0

    init(workspaceID: UUID, workflowID: String, jobs: [CoreJob], jobID: String? = nil, hub: CoreHub,
         values: any LocalRunValueStoring = InMemoryLocalRunValueStore(),
         useInstalledAct: @escaping () -> Bool = { LocalRunSettings.useInstalledAct }) {
        self.workspaceID = workspaceID
        self.workflowID = workflowID
        self.jobs = jobs
        self.jobID = jobID
        self.hub = hub
        self.values = values
        self.useInstalledAct = useInstalledAct
    }

    /// The plan's names: secrets, then variables.
    var runKeys: [LocalRunValueKey] {
        guard let plan = prepared?.plan else { return [] }
        return plan.secrets.map { LocalRunValueKey(kind: .secret, name: $0) } + plan.variables.map { LocalRunValueKey(kind: .variable, name: $0) }
    }

    /// Names the run gets no value for: nothing typed and nothing saved
    /// that Keychain gives.
    var missing: [LocalRunValueKey] {
        runKeys.filter { typed($0) == nil && (!saved.contains($0) || refused.contains($0)) }
    }

    var accessSummary: String {
        let keys = runKeys
        if keys.isEmpty { return "None read by this workflow. GitHub token and host environment are not passed" }
        let empty = missing.count
        return "\(keys.count - empty) passed, \(empty) empty. Workflow steps can read these values and send them over the network"
    }

    private func typed(_ key: LocalRunValueKey) -> String? {
        entered[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Which of the plan's names have a saved value. Each value is read once
    /// per review and kept for the run, so a refused read shows before it;
    /// a refused one is tried again when the plan is prepared again.
    private func loadSaved() async {
        let stored = (try? await values.keys(workspaceID: workspaceID)) ?? []
        var refusedNow: Set<LocalRunValueKey> = []
        for key in runKeys where stored.contains(key) && savedValues[key] == nil {
            if let value = try? await values.value(workspaceID: workspaceID, key: key) {
                savedValues[key] = value
            } else {
                refusedNow.insert(key)
            }
        }
        saved = Set(runKeys.filter { stored.contains($0) })
        refused = refusedNow
    }

    var canRun: Bool { prepared?.confirmationID != nil && trusted && !isPreparing && !isStarting }

    /// Asks the Core for a fresh plan; an answer for an older choice is dropped.
    func prepare() async {
        generation += 1
        let current = generation
        isPreparing = true
        let result = await hub.prepareLocalRun(workspaceID: workspaceID, workflowID: workflowID, jobID: jobID,
                                               event: event, useInstalledAct: useInstalledAct())
        guard current == generation else { return }
        isPreparing = false
        switch result {
        case .prepared(let prepared):
            self.prepared = prepared
            error = nil
            if event == nil { event = prepared.plan.event.isEmpty ? nil : prepared.plan.event }
            await loadSaved()
        case .failed(let message):
            prepared = nil
            error = message
        }
    }

    /// Starts the reviewed run; nil and `error` when it did not start.
    func run() async -> LocalRunModel? {
        guard canRun, let prepared else { return nil }
        isStarting = true
        defer { isStarting = false }
        var secrets: [String: String] = [:], variables: [String: String] = [:]
        for key in runKeys {
            guard let value = typed(key) ?? savedValues[key] else { continue }
            if key.kind == .secret { secrets[key.name] = value } else { variables[key.name] = value }
        }
        if saveEntered {
            for key in runKeys {
                if let text = typed(key) { try? await values.save(workspaceID: workspaceID, key: key, value: text) }
            }
        }
        switch await hub.startLocalRun(workspaceID: workspaceID, prepared: prepared, secrets: secrets, variables: variables) {
        case .started(let model):
            return model
        case .failed(let message):
            // A used or expired confirmation cannot be retried; review again.
            self.prepared = nil
            await prepare()
            error = message
            return nil
        }
    }
}
