import AppKit
import Foundation

enum WorkspaceTab: Equatable {
    case editor, localRun
}

/// Asks for the Run Locally review: a scenario (nil: the branch's default)
/// with the jobs ticked (nil: what the scenario starts that can run here).
struct LocalRunRequest: Identifiable, Equatable {
    let id = UUID()
    var scenario: CoreScenario?
    var selection: CoreLocalRunSelection?

    /// Review the run again: its scenario, its ticks.
    static func again(_ plan: CoreLocalRunPlan) -> LocalRunRequest {
        LocalRunRequest(scenario: plan.scenario, selection: LocalRunTicks.selection(of: plan.lanes))
    }
}

/// Ticking jobs of a local run: a job brings the jobs it needs, and a job
/// unticked takes the jobs that need it along. Jobs of different workflows
/// never depend on one another here.
enum LocalRunTicks {
    enum State: Equatable { case on, mixed, off }

    /// A job that can be ticked: one a local image can run.
    static func tickable(_ job: CoreLocalRunJob) -> Bool { job.support != .unsupported }

    /// A lane that can be ticked: its file parses and a job can run here.
    static func tickable(_ lane: CoreLocalRunLane) -> Bool {
        lane.parseError.isEmpty && lane.jobs.contains(where: tickable)
    }

    /// `ticks` with the job and every job it needs, all the way down.
    static func tick(_ id: String, in lane: CoreLocalRunLane, _ ticks: Set<String>) -> Set<String> {
        var out = ticks
        var queue = [id]
        while let next = queue.popLast() {
            guard !out.contains(next), let job = lane.jobs.first(where: { $0.id == next }) else { continue }
            out.insert(next)
            queue.append(contentsOf: job.needs)
        }
        return out
    }

    /// `ticks` without the job and every job that needs it, all the way up.
    static func untick(_ id: String, in lane: CoreLocalRunLane, _ ticks: Set<String>) -> Set<String> {
        var out = ticks
        var queue = [id]
        while let next = queue.popLast() {
            guard out.remove(next) != nil else { continue }
            queue.append(contentsOf: lane.jobs.filter { $0.needs.contains(next) }.map(\.id))
        }
        return out
    }

    static func state(of lane: CoreLocalRunLane, _ ticks: Set<String>) -> State {
        let tickable = lane.jobs.filter(tickable).map(\.id)
        let on = tickable.filter(ticks.contains).count
        if on == 0 { return ticks.isEmpty ? .off : .mixed }
        return on == tickable.count ? .on : .mixed
    }

    /// The lane's checkbox: every job that can run here, or none.
    static func toggle(_ lane: CoreLocalRunLane, _ ticks: Set<String>) -> Set<String> {
        guard state(of: lane, ticks) == .off else { return [] }
        return lane.jobs.filter(tickable).reduce(into: Set<String>()) { out, job in out = tick(job.id, in: lane, out) }
    }

    /// The plan's ticks as a selection for the Core.
    static func selection(of lanes: [CoreLocalRunLane]) -> CoreLocalRunSelection {
        CoreLocalRunSelection(jobs: Dictionary(uniqueKeysWithValues: lanes.map { lane in
            (lane.workflowID, Set(lane.jobs.filter(\.selected).map(\.id)))
        }))
    }
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
        jobs = plan.selectedLanes.flatMap { lane in
            lane.jobs.filter(\.selected).map { job in
                CoreLocalRunJobStatus(workflowID: lane.workflowID, id: job.id, name: job.name,
                                      state: job.support == .unsupported ? .unsupported : .waiting, reason: job.reason)
            }
        }
        selectedJobID = jobs.first { $0.state != .unsupported }?.id
    }

    var isFinished: Bool { phase == .finished || lostMessage != nil }

    var visibleLines: [CoreLocalRunLine] {
        guard let selectedJobID, let job = job(selectedJobID) else { return lines }
        return lines.filter { $0.jobID == job.jobID && $0.workflowID == job.workflowID }
    }

    /// The run's jobs under their workflows, in run order.
    var lanes: [(lane: CoreLocalRunLane, jobs: [CoreLocalRunJobStatus])] {
        plan.selectedLanes.map { lane in (lane, jobs.filter { $0.workflowID == lane.workflowID }) }
    }

    /// One line for the run: its workflow, or how many it has.
    var title: String {
        let lanes = plan.selectedLanes
        if lanes.count == 1, let lane = lanes.first { return lane.title }
        return "\(lanes.count) workflows"
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
        plan = output.plan.lanes.isEmpty ? plan : output.plan
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

/// The review before a local run (S10): the scenario, the workflows and
/// jobs ticked, the plan from the Core and the trust confirmation.
@MainActor
@Observable
final class LocalRunReviewModel {
    let workspaceID: UUID
    /// The scenario asked for; nil until the Core says the branch's default.
    private(set) var scenario: CoreScenario?
    /// The ticks the next plan is asked for; nil takes the scenario's.
    private(set) var selection: CoreLocalRunSelection?
    var trusted = false
    /// Values typed for this run, by name.
    var entered: [LocalRunValueKey: String] = [:]
    /// Save the typed values to the workspace when the run starts.
    var saveEntered = false
    /// Whose values the run takes when the plan leaves it to the user; nil
    /// is the Repository's. Not kept after the review.
    private(set) var chosenEnvironment: String?
    /// The plan's names with a saved value.
    private(set) var saved: Set<LocalRunValueKey> = []
    /// The plan's names whose saved value is the plan environment's, not
    /// the Repository's.
    private(set) var fromEnvironment: Set<LocalRunValueKey> = []
    /// Saved names whose value Keychain would not give.
    private(set) var refused: Set<LocalRunValueKey> = []
    /// Every name the workspace has a saved value for, in any set.
    private(set) var stored: Set<LocalRunValueKey> = []
    private(set) var prepared: CorePreparedLocalRun?
    /// Limits asked for in this review; nil keeps the workspace's (or the defaults).
    private(set) var askedLimits: CoreLocalRunLimits?
    /// Reset to defaults was chosen: the run is planned with the defaults.
    private(set) var resettingLimits = false
    private(set) var error: String?
    private(set) var isPreparing = false
    private(set) var isStarting = false
    @ObservationIgnored private let hub: CoreHub
    @ObservationIgnored private let useInstalledAct: () -> Bool
    @ObservationIgnored private let values: any LocalRunValueStoring
    /// Saved values read for this review, each once, by where they are
    /// kept; dropped with the sheet.
    @ObservationIgnored private var savedValues: [LocalRunValueKey: String] = [:]
    /// Where each plan name's saved value is kept: the environment's, else
    /// the Repository's.
    @ObservationIgnored private var sources: [LocalRunValueKey: LocalRunValueKey] = [:]
    @ObservationIgnored private var generation = 0

    init(workspaceID: UUID, scenario: CoreScenario? = nil, selection: CoreLocalRunSelection? = nil, hub: CoreHub,
         values: any LocalRunValueStoring = InMemoryLocalRunValueStore(),
         useInstalledAct: @escaping () -> Bool = { LocalRunSettings.useInstalledAct }) {
        self.workspaceID = workspaceID
        self.scenario = scenario
        self.selection = selection
        self.hub = hub
        self.values = values
        self.useInstalledAct = useInstalledAct
    }

    /// The environment whose values the run takes before the Repository's:
    /// the plan's, or the one chosen when the plan leaves it to the user.
    var environment: String? {
        guard let plan = prepared?.plan else { return nil }
        if !plan.environment.isEmpty { return plan.environment }
        return chosenEnvironment.flatMap { plan.environments.contains($0) ? $0 : nil }
    }

    /// The plan leaves to the user whose values the run takes.
    var choosesEnvironment: Bool { !(prepared?.plan.environments.isEmpty ?? true) }

    /// Takes another environment's values, or the Repository's for nil.
    func choose(_ environment: String?) async {
        chosenEnvironment = environment
        await loadSaved(for: runKeys, generation: generation)
    }

    /// How many of the run's names would get no value with these values:
    /// nothing typed and nothing saved there or in the Repository.
    func emptyCount(with environment: String?) -> Int {
        runKeys.filter { key in
            typed(key) == nil && !stored.contains(key) && !(environment.map { stored.contains(key.in($0)) } ?? false)
        }.count
    }

    var saveEnteredTitle: String {
        environment.map { "Save entered values to \($0)" } ?? "Save entered values to this workspace"
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
        if keys.isEmpty { return "None read by the ticked jobs. GitHub token and host environment are not passed" }
        let empty = missing.count
        return "\(keys.count - empty) passed, \(empty) empty. Workflow steps can read these values and send them over the network"
    }

    private func typed(_ key: LocalRunValueKey) -> String? {
        entered[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Which of the plan's names have a saved value, the run environment's
    /// before the Repository's. Each value is read once per review and kept
    /// for the run, so a refused read shows before it; a refused one is
    /// tried again when the plan is prepared again. An answer for an older
    /// plan or another environment is dropped.
    private func loadSaved(for keys: [LocalRunValueKey], generation current: Int) async {
        let stored = (try? await values.keys(workspaceID: workspaceID)) ?? []
        let environment = self.environment
        var found: [LocalRunValueKey: LocalRunValueKey] = [:]
        var refusedNow: Set<LocalRunValueKey> = []
        for key in keys {
            let own = environment.map { key.in($0) }
            guard let source = own.flatMap({ stored.contains($0) ? $0 : nil }) ?? (stored.contains(key) ? key : nil) else { continue }
            found[key] = source
            guard savedValues[source] == nil else { continue }
            if let value = try? await values.value(workspaceID: workspaceID, key: source) {
                savedValues[source] = value
            } else {
                refusedNow.insert(key)
            }
        }
        guard current == generation, environment == self.environment else { return }
        self.stored = stored
        sources = found
        saved = Set(found.keys)
        fromEnvironment = Set(found.filter { $0.value.environment != nil }.keys)
        refused = refusedNow
    }

    var canRun: Bool { prepared?.confirmationID != nil && trusted && !isPreparing && !isStarting }

    /// The lanes as the review shows them: the plan's, with the ticks asked for.
    var lanes: [CoreLocalRunLane] { prepared?.plan.lanes ?? [] }

    /// The ticked jobs of a lane: those asked for while their plan is on its
    /// way, else the plan's.
    func ticks(_ lane: CoreLocalRunLane) -> Set<String> {
        selection?.jobs[lane.workflowID] ?? Set(lane.jobs.filter(\.selected).map(\.id))
    }

    /// How many workflows and jobs are ticked.
    var tickedSummary: (workflows: Int, jobs: Int) {
        lanes.reduce(into: (0, 0)) { total, lane in
            let count = ticks(lane).count
            if count > 0 { total.0 += 1; total.1 += count }
        }
    }

    /// Another scenario: its default ticks, planned again.
    func choose(scenario: CoreScenario) async {
        guard scenario != self.scenario else { return }
        self.scenario = scenario
        selection = nil
        await prepare()
    }

    /// Ticks or unticks a job, with the jobs it needs or that need it.
    func toggle(job: CoreLocalRunJob, in lane: CoreLocalRunLane) async {
        let current = ticks(lane)
        let next = current.contains(job.id) ? LocalRunTicks.untick(job.id, in: lane, current) : LocalRunTicks.tick(job.id, in: lane, current)
        await select(next, in: lane)
    }

    /// The lane's checkbox: all its jobs that can run here, or none.
    func toggle(lane: CoreLocalRunLane) async {
        await select(LocalRunTicks.toggle(lane, ticks(lane)), in: lane)
    }

    private func select(_ ticks: Set<String>, in lane: CoreLocalRunLane) async {
        var next = selection ?? LocalRunTicks.selection(of: lanes)
        next.jobs[lane.workflowID] = ticks
        selection = next
        await prepare()
    }

    /// Asks the Core for a fresh plan; an answer for an older choice is dropped.
    func prepare() async {
        generation += 1
        let current = generation
        isPreparing = true
        let result = await hub.prepareLocalRun(workspaceID: workspaceID, scenario: scenario, selection: selection,
                                               useInstalledAct: useInstalledAct(),
                                               limits: askedLimits, resetLimits: resettingLimits)
        guard current == generation else { return }
        switch result {
        case .prepared(let prepared):
            self.prepared = prepared
            error = nil
            if scenario == nil { scenario = prepared.plan.scenario }
            // The Core's ticks win: it adds the jobs ticked jobs need.
            if selection != nil { selection = LocalRunTicks.selection(of: prepared.plan.lanes) }
            // Run waits for the saved values, so none is passed empty
            // because it was still being read.
            await loadSaved(for: runKeys, generation: current)
            guard current == generation else { return }
        case .failed(let message):
            prepared = nil
            error = message
        }
        isPreparing = false
    }

    /// New limits from the panel: the run is planned again and has to be
    /// confirmed again.
    func change(limits: CoreLocalRunLimits) async {
        guard limits != prepared?.plan.limits || resettingLimits else { return }
        askedLimits = limits
        resettingLimits = false
        trusted = false
        await prepare()
    }

    /// Reset to defaults: the run is planned with the defaults; confirming it
    /// forgets the workspace's limits.
    func resetLimits() async {
        askedLimits = nil
        resettingLimits = true
        trusted = false
        await prepare()
    }

    /// Starts the reviewed run; nil and `error` when it did not start.
    func run() async -> LocalRunModel? {
        guard canRun, let prepared else { return nil }
        isStarting = true
        defer { isStarting = false }
        var secrets: [String: String] = [:], variables: [String: String] = [:]
        for key in runKeys {
            guard let value = typed(key) ?? sources[key].flatMap({ savedValues[$0] }) else { continue }
            if key.kind == .secret { secrets[key.name] = value } else { variables[key.name] = value }
        }
        if saveEntered {
            do {
                for key in runKeys {
                    if let text = typed(key) { try await values.save(workspaceID: workspaceID, key: key.in(environment), value: text) }
                }
            } catch {
                self.error = "Keychain did not save the entered values, so the run did not start. \(error.localizedDescription) "
                    + "Turn off \u{201C}\(saveEnteredTitle)\u{201D} to run without saving them."
                return nil
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

/// The steps the limits panel moves by; the Core rounds to the same ones.
enum LimitSteps {
    static let memoryStep: UInt64 = 512 << 20
    static let minMemory: UInt64 = 1 << 30
    static let timeoutStep = 300
    static let minTimeout = 300
    static let maxTimeout = 6 * 3600

    /// One CPU more or less, from 1 to `max` (0: the engine did not say).
    static func cpus(_ value: Int, by delta: Int, max upper: Int) -> Int {
        let next = Swift.max(1, value + delta)
        return upper > 0 ? Swift.min(next, upper) : next
    }

    /// 512 MiB more or less, from 1 GB to `max` (0: the engine did not say);
    /// a value between steps moves to the next one.
    static func memory(_ value: UInt64, by delta: Int, max upper: UInt64) -> UInt64 {
        let steps = Int(value / memoryStep) + (delta < 0 && value % memoryStep != 0 ? 1 : 0)
        let next = UInt64(Swift.max(0, steps + delta)) * memoryStep
        let floored = Swift.max(next, minMemory)
        return upper > 0 ? Swift.min(floored, upper) : floored
    }

    /// Five minutes more or less, from 5 minutes to 6 hours.
    static func timeout(_ seconds: Int, by delta: Int) -> Int {
        Swift.min(Swift.max(seconds / timeoutStep * timeoutStep + delta * timeoutStep, minTimeout), maxTimeout)
    }
}
