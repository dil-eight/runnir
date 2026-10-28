import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Models

/// Cancel and re-run for one run, through the Core's two-step confirmation:
/// prepare checks the run's current state, the user confirms what they saw,
/// and only then is the request sent, once.
@MainActor
@Observable
final class RunActionModel {
    enum Phase: Equatable {
        case idle
        case preparing(CoreRunAction)
        /// Waiting for the user to confirm the prepared action.
        case confirming(CoreRunAction, CorePreparedRunAction)
        case sending(CoreRunAction)
        /// GitHub accepted; waiting for the run to show the change.
        case requested(CoreRunAction)
        case notice(String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// What stops the action, with the step that fixes it, shown as an alert.
    var accessHelp: GitHubAccessHelp?
    @ObservationIgnored private let hub: CoreHub
    @ObservationIgnored private let workspaceID: UUID
    @ObservationIgnored private var follow: Task<Void, Never>?

    init(hub: CoreHub, workspaceID: UUID) {
        self.hub = hub
        self.workspaceID = workspaceID
    }

    var isBusy: Bool {
        switch phase {
        case .preparing, .confirming, .sending, .requested: true
        case .idle, .notice, .failed: false
        }
    }

    var pending: (action: CoreRunAction, prepared: CorePreparedRunAction)? {
        if case .confirming(let action, let prepared) = phase { return (action, prepared) }
        return nil
    }

    func prepare(_ action: CoreRunAction, for run: CoreWorkflowRun) async {
        guard !isBusy else { return }
        // Known before asking: no write access, or Actions write waiting
        // for an owner of the account.
        let session = hub.session(for: workspaceID)
        if let repository = session?.githubRepository,
           let blocker = GitHubAccessHelp.blocker(for: .change, repository: repository, details: session?.githubDetails) {
            accessHelp = blocker
            return
        }
        phase = .preparing(action)
        let prepared = await hub.prepareRunAction(workspaceID: workspaceID, runID: run.id, action: action)
        if prepared.access == .ok, prepared.actionID != nil {
            phase = .confirming(action, prepared)
        } else if let problem = prepared.problems.first {
            phase = .failed(problem)
        } else {
            phase = .failed(Self.describe(prepared.access))
            await explain(prepared.access)
        }
    }

    /// Turns a refusal the user can fix into `accessHelp`.
    private func explain(_ access: CoreGitHubAccess) async {
        guard GitHubAccessHelp.needsExplaining(access) else { return }
        let details = access == .permissionMissing ? await hub.githubRepository(workspaceID: workspaceID) : nil
        accessHelp = hub.accessHelp(access, workspaceID: workspaceID, purpose: .change, details: details)
    }

    func dismiss() {
        switch phase {
        case .confirming, .notice, .failed: phase = .idle
        default: break
        }
    }

    /// The user's confirmation, taken synchronously so that the dialog
    /// closing right after the button press cannot discard it.
    struct Confirmed: Equatable {
        let action: CoreRunAction
        let prepared: CorePreparedRunAction
    }

    /// Takes the pending confirmation and moves to sending; nil when there is
    /// none (dismissed, expired or already taken).
    func takeConfirmation() -> Confirmed? {
        guard case .confirming(let action, let prepared) = phase, prepared.actionID != nil else { return nil }
        phase = .sending(action)
        return Confirmed(action: action, prepared: prepared)
    }

    func confirm(current run: CoreWorkflowRun) async {
        guard let confirmed = takeConfirmation() else { return }
        await send(confirmed, current: run)
    }

    /// Sends a taken confirmation once and follows the run until it shows
    /// the action.
    func send(_ confirmed: Confirmed, current run: CoreWorkflowRun) async {
        let action = confirmed.action, prepared = confirmed.prepared
        guard let actionID = prepared.actionID else { return }
        phase = .sending(action)
        guard let result = await hub.confirmRunAction(workspaceID: workspaceID, actionID: actionID) else {
            phase = .failed("The confirmation expired or the Core was not reachable. Nothing was sent; try again.")
            return
        }
        if let rejection = result.rejection {
            phase = .failed("GitHub refused: \(rejection)")
            return
        }
        guard result.acceptedAt != nil else {
            phase = .failed(Self.describe(result.access))
            await explain(result.access)
            return
        }
        phase = .requested(action)
        let before = prepared.run ?? run
        follow?.cancel()
        follow = Task { [weak self, hub, workspaceID] in
            let changed = await hub.followRunChange(workspaceID: workspaceID, from: before, action: action)
            guard let self, !Task.isCancelled, case .requested = self.phase else { return }
            self.phase = changed == nil
                ? .notice("GitHub accepted the request, but the run has not changed yet. Reload runs in a moment.")
                : .idle
        }
    }

    /// Stops following an accepted action, for example when the run's screen
    /// closes, so GitHub is not polled for a view nobody sees.
    func stopFollowing() {
        follow?.cancel()
        follow = nil
        if case .requested = phase { phase = .idle }
    }

    var statusText: String? {
        switch phase {
        case .preparing(let action): "Checking the \(Self.isJob(action) ? "job" : "run") before \(action == .cancel ? "cancelling" : "re-running")..."
        case .sending(let action): action == .cancel ? "Asking GitHub to cancel..." : (Self.isJob(action) ? "Asking GitHub to re-run the job..." : "Asking GitHub to re-run...")
        case .requested(let action): action == .cancel ? "Cancel requested. GitHub is stopping the run." : "Re-run requested. GitHub is starting a new attempt."
        case .notice(let text), .failed(let text): text
        case .idle, .confirming: nil
        }
    }

    private static func isJob(_ action: CoreRunAction) -> Bool {
        if case .rerunJob = action { return true }
        return false
    }

    /// Why a change could not be made.
    static func describe(_ access: CoreGitHubAccess) -> String {
        switch access {
        case .signedOut: "Connect GitHub to change runs."
        case .tokenRejected: "GitHub no longer accepts the saved sign-in. Sign in again to change runs."
        case .notVisible: "Runnir can't see this repository on GitHub. Give Runnir Desktop access to it."
        case .permissionMissing: "GitHub did not allow this: Runnir Desktop or your account lacks a permission. Nothing was changed."
        case .rateLimited: "GitHub is limiting requests. Nothing was changed; try again later."
        case .noRemote: "This working tree has no origin on github.com."
        case .ok, .unavailable: "GitHub could not be reached. Nothing was changed."
        }
    }

    /// Why jobs or a log could not be read.
    static func describeRead(_ access: CoreGitHubAccess) -> String {
        switch access {
        case .signedOut: "Connect GitHub to see jobs and logs."
        case .tokenRejected: "GitHub no longer accepts the saved sign-in. Sign in again to see jobs and logs."
        case .notVisible: "Runnir can't read this repository on GitHub. Give Runnir Desktop access to it, then try again."
        case .permissionMissing: "Runnir Desktop can't read Actions here yet: an owner has not accepted its permissions, or your account lacks access."
        case .rateLimited: "GitHub is limiting requests. Try again later."
        case .noRemote: "This working tree has no origin on github.com."
        case .ok, .unavailable: "GitHub could not be reached."
        }
    }

    /// Title and explanation for the confirmation, from the run as prepared.
    static func confirmation(for action: CoreRunAction, run: CoreWorkflowRun, job: CoreRunJob? = nil) -> (title: String, message: String, button: String) {
        let target = "\(run.name) on \(run.branch) · \(run.headSHA.prefix(7))"
        switch action {
        case .cancel:
            return ("Cancel run #\(run.runNumber)?",
                    "\(target). GitHub stops the jobs that are still running and marks the run cancelled.", "Cancel Run")
        case .rerun:
            return ("Re-run all jobs of run #\(run.runNumber)?",
                    "\(target). Starts attempt \(run.runAttempt + 1) of every job on the same commit.", "Re-run")
        case .rerunFailed:
            return ("Re-run failed jobs of run #\(run.runNumber)?",
                    "\(target). Starts attempt \(run.runAttempt + 1) of the failed and cancelled jobs and the jobs that need them, on the same commit.",
                    "Re-run")
        case .rerunJob:
            let name = job.map { "job \"\($0.name)\"" }
            return ("Re-run \(name ?? "the job") of run #\(run.runNumber)?",
                    "\(target). Starts attempt \(run.runAttempt + 1) of \(name ?? "the job") and the jobs that need it, on the same commit.",
                    "Re-run")
        case .approveDeployments:
            return ("Approve the deployment of run #\(run.runNumber)?",
                    "\(target). The jobs waiting for it go on.", "Approve")
        }
    }
}

/// What the log viewer shows: the end of one step or of the whole job, and
/// search matches among those lines.
enum LogFilter {
    /// The viewer shows this many lines from the end; the whole log opens in
    /// an editor.
    static let shownLines = 100

    static func tail(_ lines: [CoreLogLine]) -> [CoreLogLine] {
        Array(lines.suffix(shownLines))
    }

    /// "Last 100 of 21,777 lines", "Last 100 lines · Archive"; nil when every
    /// line of the selection is shown and the log is complete.
    static func scope(shown: Int, selected: Int, lastNumber: Int64, truncated: Bool, step: String?) -> String? {
        let hidden = selected > shown || truncated
        guard hidden else { return nil }
        if let step {
            return truncated ? "Last \(shown) lines · \(step)" : "Last \(shown) of \(selected.formatted()) lines · \(step)"
        }
        return "Last \(shown) of \(Int(lastNumber).formatted()) lines"
    }

    /// End-of-group markers carry no text and are hidden.
    static func lines(_ log: [CoreLogLine], step: Int64?) -> [CoreLogLine] {
        log.filter { $0.kind != .endGroup && (step == nil || $0.stepNumber == step) }
    }

    /// Line numbers containing the query, ignoring case; empty for a blank query.
    static func matches(_ lines: [CoreLogLine], query: String) -> [Int64] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        return lines.compactMap { $0.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) == nil ? nil : $0.number }
    }

    /// The job to open first: the first failed one, else the first.
    static func defaultJob(_ jobs: [CoreRunJob]) -> CoreRunJob? {
        jobs.first { $0.outcome == .failed } ?? jobs.first
    }

    /// The step to open first: the first failed one, else the whole job.
    static func defaultStep(_ job: CoreRunJob) -> Int64? {
        job.steps.first { $0.outcome == .failed }?.number
    }

    /// A failed reload keeps the jobs already shown, marked stale, instead of
    /// replacing them with an error and closing the log.
    static func reloadedJobs(previous: CoreGitHubResult<CoreRunJob>?, new: CoreGitHubResult<CoreRunJob>)
        -> (jobs: CoreGitHubResult<CoreRunJob>, stale: Bool) {
        if new.access != .ok, let previous, previous.access == .ok, !previous.items.isEmpty {
            return (previous, true)
        }
        return (new, false)
    }
}

enum RunDuration {
    static func text(from start: Date?, to end: Date?) -> String? {
        guard let start, let end, end >= start else { return nil }
        return Duration.seconds(end.timeIntervalSince(start).rounded())
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
    }
}

// MARK: Views

/// One run (screen S08): actions, summary, jobs and steps, and the selected
/// job's log.
struct RunInspectorView: View {
    let run: CoreWorkflowRun
    let workspaceID: UUID
    let hub: CoreHub
    /// For the sign-in sheet an access alert may offer.
    var github: GitHubSession? = nil
    /// Its pull request, the run that superseded it and a suggestion.
    let context: RunInspectorContext
    let select: (Int64) -> Void
    let addConcurrency: (String) -> Void
    let dismissHint: (String) -> Void
    /// The jobs, the workflow file and the open log of this run, shared with
    /// the layer the runs list shows over the graph.
    @Bindable var layer: RunLayerModel
    @Environment(\.openURL) private var openURL

    init(run: CoreWorkflowRun, workspaceID: UUID, hub: CoreHub, layer: RunLayerModel, github: GitHubSession? = nil,
         context: RunInspectorContext = RunInspectorContext(), select: @escaping (Int64) -> Void = { _ in },
         addConcurrency: @escaping (String) -> Void = { _ in }, dismissHint: @escaping (String) -> Void = { _ in }) {
        self.run = run
        self.workspaceID = workspaceID
        self.hub = hub
        self.layer = layer
        self.github = github
        self.context = context
        self.select = select
        self.addConcurrency = addConcurrency
        self.dismissHint = dismissHint
    }

    private var actions: RunActionModel { layer.actions }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            DesignDivider()
            summary
            links
            if let text = actions.statusText { actionStatus(text) }
            DesignDivider()
            RunGraphView(model: layer, run: run).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The workflow file is the file at the run's commit; it is asked for
        // again when the run finishes, for the reasons of its skipped jobs.
        .task(id: "\(run.id)-\(run.outcome.isActive)") {
            layer.show(run: run.id)
            let workflow = await hub.runWorkflow(workspaceID: workspaceID, runID: run.id)
            guard !Task.isCancelled, layer.runID == run.id else { return }
            layer.workflow = workflow
        }
        // The jobs are read again whenever the run changes.
        .task(id: "\(run.id)-\(run.status)-\(run.runAttempt)-\(run.updatedAt?.timeIntervalSince1970 ?? 0)") {
            layer.show(run: run.id)
            let result = await hub.jobs(workspaceID: workspaceID, runID: run.id)
            guard !Task.isCancelled, layer.runID == run.id else { return }
            layer.apply(jobs: LogFilter.reloadedJobs(previous: layer.jobs, new: result))
        }
        .onDisappear { actions.stopFollowing() }
        .githubAccessAlert(Binding(get: { actions.accessHelp }, set: { actions.accessHelp = $0 }), github: github)
        .confirmationDialog(confirmationTitle, isPresented: confirmationShown, titleVisibility: .visible) {
            if let pending = actions.pending {
                let text = RunActionModel.confirmation(for: pending.action, run: pending.prepared.run ?? run, job: pending.prepared.job)
                Button(text.button, role: pending.action == .cancel ? .destructive : nil) {
                    guard let confirmed = actions.takeConfirmation() else { return }
                    Task { await actions.send(confirmed, current: run) }
                }
                Button(pending.action == .cancel ? "Keep Running" : "Not Now", role: .cancel) { actions.dismiss() }
            }
        } message: {
            if let pending = actions.pending {
                Text(RunActionModel.confirmation(for: pending.action, run: pending.prepared.run ?? run, job: pending.prepared.job).message)
            }
        }
    }

    private var confirmationShown: Binding<Bool> {
        Binding(get: { actions.pending != nil }, set: { shown in if !shown, actions.pending != nil { actions.dismiss() } })
    }

    private var confirmationTitle: String {
        guard let pending = actions.pending else { return "" }
        return RunActionModel.confirmation(for: pending.action, run: pending.prepared.run ?? run, job: pending.prepared.job).title
    }

    // MARK: Header

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                Text("Run #\(run.runNumber) · \(run.name)").foregroundStyle(RunnirTheme.foreground)
                if run.title != run.name {
                    Text(" / \(run.title)").foregroundStyle(RunnirTheme.secondaryForeground)
                }
            }
            .font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            if let url = run.htmlURL { Button("Open on GitHub") { openURL(url) }.buttonStyle(DesignButtonStyle()) }
            Button("Cancel Run") { Task { await actions.prepare(.cancel, for: run) } }
                .buttonStyle(DesignButtonStyle())
                .disabled(!run.outcome.isActive || actions.isBusy)
                .help(run.outcome.isActive ? "Ask GitHub to cancel this run" : "Only queued or running runs can be cancelled")
            rerunButton
        }
        .padding(.horizontal, 20).frame(height: 52)
    }

    @ViewBuilder private var rerunButton: some View {
        if run.outcome.isActive {
            Button { } label: { Label("Re-run (finished runs only)", systemImage: "arrow.clockwise") }
                .buttonStyle(DesignButtonStyle(primary: true)).disabled(true)
        } else if run.canRerunFailedJobs {
            Menu {
                Button(CoreRunAction.rerun.title) { Task { await actions.prepare(.rerun, for: run) } }
            } label: {
                Label(CoreRunAction.rerunFailed.title, systemImage: "arrow.clockwise")
            } primaryAction: {
                Task { await actions.prepare(.rerunFailed, for: run) }
            }
            .menuStyle(.borderedButton).fixedSize().handPointer().disabled(actions.isBusy)
            .help("Re-run the failed and cancelled jobs; the menu re-runs every job")
        } else {
            Button { Task { await actions.prepare(.rerun, for: run) } } label: {
                Label(CoreRunAction.rerun.title, systemImage: "arrow.clockwise")
            }
            .buttonStyle(DesignButtonStyle(primary: true)).disabled(actions.isBusy)
        }
    }

    private var summary: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                RunOutcomeIcon(outcome: run.outcome, size: 13)
                Text(run.outcome.label).foregroundStyle(RunnirTheme.foreground)
            }
            Text("\(run.branch) · \(run.headSHA.prefix(7))").font(.system(size: 12, design: .monospaced))
            Text("Attempt \(run.runAttempt)")
            Text(run.actor.map { "\(eventLabel) by \($0)" } ?? eventLabel)
            if !run.outcome.isActive, let duration = RunDuration.text(from: run.createdAt, to: run.updatedAt) {
                Text(duration)
            }
            Spacer(minLength: 8)
            if run.outcome.isActive {
                Text("Live · updating every \(Int(CoreHub.activeSyncInterval.components.seconds)) s").foregroundStyle(RunnirTheme.mutedForeground)
            } else if let updated = run.updatedAt {
                Text("Updated \(updated.formatted(.relative(presentation: .named)))").foregroundStyle(RunnirTheme.mutedForeground)
            }
        }
        .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
        .padding(.horizontal, 20).frame(height: 40)
    }

    // MARK: Pull request and commit

    private var links: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let pullRequest = context.pullRequest {
                Button {
                    if let url = pullRequest.htmlURL { openURL(url) }
                } label: {
                    Label(RunPresentation.pullRequestLine(pullRequest), systemImage: "arrow.triangle.pull").lineLimit(1)
                }
                .buttonStyle(.link).pointerStyle(.link).disabled(pullRequest.htmlURL == nil).help("Open the pull request on GitHub")
            }
            Label(RunPresentation.commitLine(run), systemImage: "smallcircle.filled.circle")
                .foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
            if let newer = context.supersededBy {
                Button("Superseded by \(newer.name) #\(newer.runNumber) on a newer commit") { select(newer.id) }
                    .buttonStyle(.link).pointerStyle(.link).help("Show the run that replaced this one")
            }
            if run.isSuperseded, let hint = context.hint {
                ConcurrencyHintBanner(hint: hint, workflowName: context.workflowName,
                                      add: { addConcurrency(hint.path) }, dismiss: { dismissHint(hint.path) })
                    .padding(.top, 4)
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.bottom, 8)
    }

    private var eventLabel: String {
        run.event.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func actionStatus(_ text: String) -> some View {
        HStack(spacing: 8) {
            if case .failed = actions.phase {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(RunnirTheme.warning)
            } else if actions.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "info.circle").foregroundStyle(RunnirTheme.info)
            }
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if !actions.isBusy { Button("Dismiss") { actions.dismiss() }.buttonStyle(.link).pointerStyle(.link) }
        }
        .font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 8)
        .background(RunnirTheme.surface)
    }
}

/// The selected job's log, filtered to one step, with search and wrapping.
struct JobLogView: View {
    let job: CoreRunJob
    let step: Int64?
    let workspaceID: UUID
    let hub: CoreHub
    let showWholeJob: () -> Void
    /// Set when the log is shown in the layer over the runs: its expand and close buttons.
    var layer: LogLayerControls? = nil
    @State private var log: CoreJobLog?
    /// The shown lines (the end of the selection), kept so that a render or
    /// keystroke does not filter up to 50,000 lines again.
    @State private var visible: [CoreLogLine] = []
    /// Lines of the selection (job or step) in what the Core sent.
    @State private var selectedCount = 0
    @State private var totalLines = 0
    @State private var saving = false
    @State private var saveProblem: String?
    @State private var query = ""
    @State private var matches: [Int64] = []
    @State private var matchIndex = 0
    /// Changes after the shown lines are recomputed, so scrolling uses them.
    @State private var linesVersion = 0
    @State private var wrap = true
    @Environment(\.openURL) private var openURL

    private var stepName: String? {
        guard let step else { return nil }
        return job.steps.first { $0.number == step }?.name
    }

    /// How often and how long to ask again for the log of a job that has just
    /// finished, while GitHub is still storing it.
    static let settleRetryInterval: Duration = .seconds(5)
    static let settleRetries = 24

    var body: some View {
        VStack(spacing: 0) {
            header
            DesignDivider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            DesignDivider()
            footer
        }
        .task(id: "\(job.id)-\(job.status)") {
            log = nil
            refreshLines()
            var retries = 0
            while !Task.isCancelled {
                let result = await hub.jobLog(workspaceID: workspaceID, jobID: job.id)
                guard !Task.isCancelled else { return }
                log = result
                refreshLines()
                guard result.access == .ok, result.availability == .notReady, !job.outcome.isActive,
                      retries < Self.settleRetries else { break }
                retries += 1
                try? await Task.sleep(for: Self.settleRetryInterval)
            }
        }
        .onChange(of: query) { updateMatches() }
        .onChange(of: step) { refreshLines() }
    }

    private func refreshLines() {
        let all = LogFilter.lines(log?.lines ?? [], step: nil)
        totalLines = all.count
        let selection = step == nil ? all : all.filter { $0.stepNumber == step }
        selectedCount = selection.count
        visible = LogFilter.tail(selection)
        linesVersion += 1
        updateMatches()
    }

    private func updateMatches() {
        matches = LogFilter.matches(visible, query: query)
        matchIndex = 0
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(stepName.map { "\(job.name) › \($0)" } ?? job.name)
                .font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(RunnirTheme.mutedForeground)
                TextField(hiddenLines ? "Search shown lines" : "Search log", text: $query).textFieldStyle(.plain).frame(width: 150)
                    .onSubmit { moveMatch(by: 1) }
                if !query.isEmpty {
                    Text(matches.isEmpty ? "0 of 0" : "\(matchIndex + 1) of \(matches.count)")
                        .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).monospacedDigit()
                    Button { moveMatch(by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).pointerStyle(.link).disabled(matches.isEmpty)
                        .help("Previous match").accessibilityLabel("Previous match")
                    Button { moveMatch(by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).pointerStyle(.link).disabled(matches.isEmpty)
                        .help("Next match").accessibilityLabel("Next match")
                }
            }
            .font(.system(size: 12)).padding(.horizontal, 8).frame(height: 26)
            .background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(RunnirTheme.border))
            Toggle("Wrap", isOn: $wrap).toggleStyle(.checkbox).pointerStyle(.link).font(.system(size: 12))
            if let layer {
                Button { layer.toggleExpanded() } label: {
                    Image(systemName: layer.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12)).frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.hit).help(layer.expanded ? "Back to the floating layer" : "Fill the whole section")
                .accessibilityLabel(layer.expanded ? "Restore the log" : "Expand the log")
                Button { layer.close() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.hit).help("Close the log").accessibilityLabel("Close the log")
            }
        }
        .padding(.horizontal, 14).frame(height: 44)
    }

    private func moveMatch(by offset: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + offset + matches.count) % matches.count
    }

    @ViewBuilder private var content: some View {
        switch log {
        case nil:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading log...").font(.system(size: 12)) }
        case .some(let log) where log.access != .ok:
            placeholder("exclamationmark.triangle", "The log could not be loaded", RunActionModel.describeRead(log.access))
        case .some(let log) where log.availability == .notReady && job.outcome.isActive:
            placeholder("hourglass", "The log appears when this job finishes",
                        "GitHub serves a job's log once the job has completed. The step list on the left updates while it runs; Open on GitHub shows the live output.")
        case .some(let log) where log.availability == .notReady:
            placeholder("hourglass", "The log is not ready yet",
                        "The job has just finished and GitHub is still storing its log. Runnir checks again every few seconds.")
        case .some(let log) where log.availability == .expired:
            placeholder("clock.arrow.circlepath", "Logs for this job have expired",
                        "GitHub keeps logs for a limited time. The job result and step list are still available.")
        case .some:
            if visible.isEmpty {
                placeholder("text.alignleft", step == nil ? "This job wrote no output" : "No output from this step",
                            step == nil ? "" : "Lines are matched to steps by time, so a step's output can appear under a neighbouring step.",
                            showAll: step != nil)
            } else {
                lines
            }
        }
    }

    private var lines: some View {
        let current = matches.isEmpty ? nil : matches[min(matchIndex, matches.count - 1)]
        let matched = Set(matches)
        let width = CGFloat(String(visible.last?.number ?? 0).count) * 7.5 + 4
        return ScrollViewReader { proxy in
            ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if hiddenLines {
                        Text(earlierText).font(.system(size: 11)).foregroundStyle(RunnirTheme.mutedForeground)
                            .padding(.horizontal, 12).padding(.vertical, 4)
                    }
                    ForEach(visible) { line in
                        LogLineRow(line: line, numberWidth: width, wrap: wrap,
                                   highlight: line.number == current ? .current : matched.contains(line.number) ? .match : nil)
                            .id(line.number)
                    }
                }
                .padding(.vertical, 6)
                .textSelection(.enabled)
            }
            .onAppear { scrollToInterest(proxy) }
            .onChange(of: linesVersion) { scrollToInterest(proxy) }
            .onChange(of: current) { if let current { proxy.scrollTo(current, anchor: .center) } }
        }
    }

    /// Opens on the first error, the way a failing step is usually read,
    /// else on the last line.
    private func scrollToInterest(_ proxy: ScrollViewProxy) {
        if let error = visible.first(where: { $0.kind == .error }) {
            proxy.scrollTo(error.number, anchor: .center)
        } else if let last = visible.last {
            proxy.scrollTo(last.number, anchor: .bottom)
        }
    }

    /// Lines of the job or step that the viewer leaves to the editor.
    private var hiddenLines: Bool {
        guard let log, log.access == .ok, log.availability == .available else { return false }
        return selectedCount > visible.count || log.truncated
    }

    private var earlierText: String {
        let shownFrom = visible.first?.number ?? 1
        let earlier = step == nil ? Int(shownFrom - 1) : selectedCount - visible.count
        let lines = earlier == 1 ? "1 earlier line" : "\(earlier.formatted()) earlier lines"
        return step == nil || log?.truncated != true
            ? "\(lines) · the whole log opens in \(LogEditor.name)"
            : "Earlier lines · the whole log opens in \(LogEditor.name)"
    }

    /// Asks the Core for the whole log as a file and opens it in the editor.
    private func openInEditor() {
        guard !saving else { return }
        saving = true
        saveProblem = nil
        Task {
            let saved = await hub.saveJobLog(workspaceID: workspaceID, jobID: job.id)
            saving = false
            switch saved {
            case let saved where saved.access != .ok:
                saveProblem = RunActionModel.describeRead(saved.access)
            case let saved where saved.availability == .expired:
                saveProblem = "GitHub no longer has this log."
            case let saved:
                if let file = saved.file { LogEditor.open(file) } else { saveProblem = "The log could not be saved." }
            }
        }
    }

    private func placeholder(_ symbol: String, _ title: String, _ detail: String, showAll: Bool = false) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(RunnirTheme.mutedForeground)
            Text(title).font(.system(size: 14, weight: .medium))
            if !detail.isEmpty {
                Text(detail).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            HStack(spacing: 8) {
                if showAll { Button("Show Whole Job", action: showWholeJob).buttonStyle(DesignButtonStyle()) }
                if let url = job.htmlURL { Button("Open on GitHub") { openURL(url) }.buttonStyle(DesignButtonStyle()) }
            }
        }
        .padding(24)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            footerText
            Spacer()
            if let saveProblem {
                Label(saveProblem, systemImage: "exclamationmark.triangle").lineLimit(1).help(saveProblem)
            }
            if hiddenLines {
                if let url = job.htmlURL {
                    Button("On GitHub") { openURL(url) }.buttonStyle(.link).pointerStyle(.link)
                        .help("Open this job's log on GitHub")
                }
                Button(saving ? "Saving Log…" : "Open in \(LogEditor.name)", action: openInEditor)
                    .buttonStyle(DesignButtonStyle(compact: true)).disabled(saving)
                    .help("Saves the whole log to a temporary file and opens it")
            }
        }
        .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
        .padding(.horizontal, 14).frame(height: 30)
    }

    @ViewBuilder private var footerText: some View {
        switch log {
        case nil:
            Text("Loading...")
        case .some(let log) where log.access != .ok:
            Label("Log not loaded", systemImage: "exclamationmark.triangle")
        case .some(let log) where log.availability == .notReady:
            Label(job.outcome.isActive ? "Waiting for the job to finish" : "Waiting for GitHub to store the log", systemImage: "hourglass")
        case .some(let log) where log.availability == .expired:
            Label("No log available · expired", systemImage: "clock.arrow.circlepath")
        case .some(let log):
            if let scope = LogFilter.scope(shown: visible.count, selected: selectedCount, lastNumber: log.lines.last?.number ?? 0,
                                           truncated: log.truncated, step: stepName) {
                Label(log.stoppedEarly ? "Very large log · \(scope)" : scope, systemImage: "scissors")
            } else {
                let scope = stepName.map { "\(visible.count) of \(totalLines) lines · \($0)" } ?? "\(totalLines) lines"
                Label("Log complete · \(scope)", systemImage: "checkmark.circle")
            }
        }
    }
}

/// Where a whole log opens: Visual Studio Code when it is installed, else the
/// app for plain text (TextEdit unless changed).
enum LogEditor {
    static let vsCodeBundleID = "com.microsoft.VSCode"

    static var app: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: vsCodeBundleID)
            ?? NSWorkspace.shared.urlForApplication(toOpen: .plainText)
    }

    static var name: String {
        guard let app else { return "Editor" }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    static func open(_ file: URL) {
        if let app {
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(file)
        }
    }
}

private struct LogLineRow: View {
    enum Highlight { case match, current }
    let line: CoreLogLine
    let numberWidth: CGFloat
    let wrap: Bool
    let highlight: Highlight?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(String(line.number)).foregroundStyle(RunnirTheme.mutedForeground)
                .frame(width: numberWidth, alignment: .trailing)
            Text(line.kind == .group ? "▸ \(line.text)" : line.text)
                .fontWeight(line.kind == .group ? .semibold : .regular)
                .foregroundStyle(color)
                .lineLimit(wrap ? nil : 1)
                .fixedSize(horizontal: !wrap, vertical: true)
                .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 12).padding(.vertical, 1)
        .background(background)
    }

    private var color: Color {
        switch line.kind {
        case .error: RunnirTheme.destructive
        case .warning: RunnirTheme.warning
        case .notice, .command: RunnirTheme.info
        case .debug: RunnirTheme.mutedForeground
        case .plain, .group, .endGroup: RunnirTheme.foreground
        }
    }

    private var background: Color {
        switch highlight {
        case .current: RunnirTheme.warning.opacity(0.35)
        case .match: RunnirTheme.warning.opacity(0.15)
        case nil: line.kind == .error ? RunnirTheme.destructive.opacity(0.12) : .clear
        }
    }
}
