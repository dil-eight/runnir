import SwiftUI

/// Status icon for a run, job or step.
struct RunOutcomeIcon: View {
    let outcome: CoreRunOutcome
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: outcome.symbol)
            .font(.system(size: size))
            .foregroundStyle(color)
            .accessibilityLabel(outcome.label)
    }

    private var color: Color {
        switch outcome {
        case .succeeded: RunnirTheme.success
        case .failed: RunnirTheme.destructive
        case .running, .queued: RunnirTheme.info
        case .cancelled, .skipped, .neutral: RunnirTheme.secondaryForeground
        }
    }
}

/// Why GitHub data is missing, with the step that fixes it.
struct GitHubAccessNotice: View {
    let access: CoreGitHubAccess
    let repository: String?
    let github: GitHubSession?
    let retry: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var showingConnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { actions }.buttonStyle(DesignButtonStyle())
        }
        .sheet(isPresented: $showingConnect) { if let github { GitHubConnectView(session: github) } }
    }

    private var message: String {
        let name = repository ?? "this repository"
        switch access {
        case .ok: return ""
        case .noRemote: return "This working tree has no origin on github.com, so there are no GitHub runs to show."
        case .signedOut: return "Connect GitHub to see runs for \(name)."
        case .tokenRejected: return "GitHub no longer accepts the saved sign-in. Connect again."
        case .notVisible: return "Runnir can't see \(name). Install Runnir Desktop on it, then try again."
        case .rateLimited(let until):
            if let until { return "GitHub is limiting requests until \(until.formatted(date: .omitted, time: .shortened)). Showing the last data." }
            return "GitHub is limiting requests. Showing the last data."
        case .unavailable: return "GitHub could not be reached. Showing the last data."
        }
    }

    @ViewBuilder private var actions: some View {
        switch access {
        case .signedOut, .tokenRejected:
            if github != nil { Button("Connect GitHub...") { showingConnect = true } }
        case .notVisible:
            Button("Give Runnir Access...") { openURL(GitHubAppConfiguration.runnirDesktop.installationURL) }
            Button("Try Again", action: retry)
        case .rateLimited, .unavailable:
            Button("Try Again", action: retry)
        case .ok, .noRemote:
            EmptyView()
        }
    }
}

/// One line per run: status, title, number, branch, event and age.
struct RunRow: View {
    let run: CoreWorkflowRun
    var selected = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RunOutcomeIcon(outcome: run.outcome).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let created = run.createdAt {
                Text(created, format: .relative(presentation: .named))
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(selected ? RunnirTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        "\(run.name) #\(run.runNumber) · \(run.branch) · \(run.event)"
    }
}

/// The newest runs for the Overview.
struct RecentRunsList: View {
    let session: RepositorySession
    let github: GitHubSession?
    let hub: CoreHub?
    var limit = 5
    let open: (CoreWorkflowRun) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let access = session.githubAccess, access != .ok {
                GitHubAccessNotice(access: access, repository: session.githubRepository, github: github) {
                    Task { await hub?.loadGitHubActivity(workspaceID: session.workspaceID) }
                }
            }
            if session.runs.isEmpty {
                if session.isLoadingGitHub {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading runs...").font(.system(size: 12)) }
                } else if session.githubAccess == .ok {
                    UnavailableFeature(title: "No runs yet", detail: "No workflow has run on GitHub for this repository.", symbol: "play.circle")
                }
            }
            ForEach(session.runs.prefix(limit)) { run in
                Button { open(run) } label: { RunRow(run: run) }.buttonStyle(.plain)
            }
        }
    }
}

/// Runs section: the run list and the selected run's jobs and steps.
struct WorkspaceRunsView: View {
    let session: RepositorySession
    let hub: CoreHub
    let github: GitHubSession?
    @Binding var selectedRunID: Int64?
    @State private var onlyCurrentBranch = false

    private var runs: [CoreWorkflowRun] {
        onlyCurrentBranch && !session.branch.isEmpty ? session.runs.filter { $0.branch == session.branch } : session.runs
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Toggle(isOn: $onlyCurrentBranch) {
                        Text(session.branch.isEmpty ? "Current branch" : session.branch).lineLimit(1)
                    }.toggleStyle(.checkbox).disabled(session.branch.isEmpty)
                    Spacer()
                    Button {
                        Task { await hub.loadGitHubActivity(workspaceID: session.workspaceID) }
                    } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(session.isLoadingGitHub).help("Reload runs from GitHub")
                }
                .font(.system(size: 12)).padding(12)
                DesignDivider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if let access = session.githubAccess, access != .ok {
                            GitHubAccessNotice(access: access, repository: session.githubRepository, github: github) {
                                Task { await hub.loadGitHubActivity(workspaceID: session.workspaceID) }
                            }.padding(8)
                        }
                        ForEach(runs) { run in
                            RunRow(run: run, selected: run.id == selectedRunID)
                                .onTapGesture { selectedRunID = run.id }
                        }
                        if runs.isEmpty && session.githubAccess == .ok {
                            Text(onlyCurrentBranch ? "No runs on this branch." : "No runs yet.")
                                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).padding(12)
                        }
                    }.padding(6)
                }
            }
            .frame(width: 340)
            DesignDivider(vertical: true)
            Group {
                if let run = session.runs.first(where: { $0.id == selectedRunID }) {
                    RunDetailView(run: run, workspaceID: session.workspaceID, hub: hub)
                } else {
                    UnavailableFeature(title: "Select a run", detail: "Choose a run to see its jobs and steps.", symbol: "play.circle")
                        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selectedRunID == nil { selectedRunID = session.runs.first?.id } }
    }
}

/// One run: header and its jobs with steps, read on demand and re-read while
/// the run is still going.
struct RunDetailView: View {
    let run: CoreWorkflowRun
    let workspaceID: UUID
    let hub: CoreHub
    @Environment(\.openURL) private var openURL
    @State private var jobs: CoreGitHubResult<CoreRunJob>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    RunOutcomeIcon(outcome: run.outcome, size: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(run.title).font(.system(size: 16, weight: .semibold))
                        Text("\(run.name) #\(run.runNumber) · \(run.outcome.label)")
                            .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                        Text(metadata).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                    }
                    Spacer()
                    if let url = run.htmlURL { Button("Open on GitHub") { openURL(url) }.buttonStyle(DesignButtonStyle()) }
                }
                DesignDivider()
                switch jobs {
                case nil:
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading jobs...").font(.system(size: 12)) }
                case .some(let result) where result.access != .ok:
                    Text("Jobs could not be loaded from GitHub.").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                case .some(let result):
                    ForEach(result.items) { job in JobSection(job: job) }
                    if result.items.isEmpty {
                        Text("This run has no jobs yet.").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                    }
                }
            }
            .padding(24)
        }
        .task(id: "\(run.id)-\(run.status)-\(run.updatedAt?.timeIntervalSince1970 ?? 0)") {
            jobs = await hub.jobs(workspaceID: workspaceID, runID: run.id)
        }
    }

    private var metadata: String {
        var parts = [run.branch, String(run.headSHA.prefix(7)), run.event]
        if let actor = run.actor { parts.append(actor) }
        return parts.joined(separator: " · ")
    }
}

private struct JobSection: View {
    let job: CoreRunJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RunOutcomeIcon(outcome: job.outcome)
                Text(job.name).font(.system(size: 13, weight: .medium))
                Spacer()
                if let started = job.startedAt, let completed = job.completedAt {
                    Text(Duration.seconds(completed.timeIntervalSince(started)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)))
                        .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
            }
            ForEach(job.steps) { step in
                HStack(spacing: 8) {
                    RunOutcomeIcon(outcome: step.outcome, size: 11)
                    Text(step.name).font(.system(size: 12)).lineLimit(1)
                }.padding(.leading, 22)
            }
        }
    }
}

/// Workflows section: the repository's workflows on GitHub with each one's
/// newest run.
struct WorkspaceWorkflowsView: View {
    let session: RepositorySession
    let hub: CoreHub
    let github: GitHubSession?
    let showRun: (CoreWorkflowRun) -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let access = session.githubAccess, access != .ok {
                    GitHubAccessNotice(access: access, repository: session.githubRepository, github: github) {
                        Task { await hub.loadGitHubActivity(workspaceID: session.workspaceID) }
                    }.padding(.bottom, 12)
                }
                ForEach(session.remoteWorkflows) { workflow in
                    let latest = session.runs.first { $0.workflowID == workflow.id }
                    HStack(spacing: 10) {
                        if let latest { RunOutcomeIcon(outcome: latest.outcome) } else {
                            Image(systemName: "circle.dashed").foregroundStyle(RunnirTheme.secondaryForeground)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workflow.name).font(.system(size: 13, weight: .medium))
                            Text(workflow.path).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                        }
                        Spacer()
                        if workflow.state != "active" {
                            Text(workflow.state.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.system(size: 11)).foregroundStyle(RunnirTheme.warning)
                        }
                        if let latest {
                            Button("Last run") { showRun(latest) }.buttonStyle(.link).font(.system(size: 12))
                        }
                        if let url = workflow.htmlURL {
                            Button { openURL(url) } label: { Image(systemName: "arrow.up.right.square") }
                                .buttonStyle(.borderless).help("Open on GitHub")
                        }
                    }
                    .padding(.horizontal, 12).frame(height: 52)
                    DesignDivider()
                }
                if session.remoteWorkflows.isEmpty && session.githubAccess == .ok {
                    UnavailableFeature(title: "No workflows on GitHub",
                                       detail: "Workflows appear here after they are pushed to GitHub. Local files are in the Workspace section.",
                                       symbol: "point.3.connected.trianglepath.dotted")
                }
            }.padding(24)
        }
    }
}
