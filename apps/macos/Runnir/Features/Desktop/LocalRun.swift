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
    private(set) var prepared: CorePreparedLocalRun?
    private(set) var error: String?
    private(set) var isPreparing = false
    private(set) var isStarting = false
    @ObservationIgnored private let hub: CoreHub
    @ObservationIgnored private let useInstalledAct: () -> Bool
    @ObservationIgnored private var generation = 0

    init(workspaceID: UUID, workflowID: String, jobs: [CoreJob], jobID: String? = nil, hub: CoreHub,
         useInstalledAct: @escaping () -> Bool = { LocalRunSettings.useInstalledAct }) {
        self.workspaceID = workspaceID
        self.workflowID = workflowID
        self.jobs = jobs
        self.jobID = jobID
        self.hub = hub
        self.useInstalledAct = useInstalledAct
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
        switch await hub.startLocalRun(workspaceID: workspaceID, prepared: prepared) {
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
