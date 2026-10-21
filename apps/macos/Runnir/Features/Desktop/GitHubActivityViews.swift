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
            if let access = session.githubAccess,
               let help = GitHubAccessHelp.forAccess(access, repository: session.githubRepository, purpose: .read, details: session.githubDetails) {
                GitHubAccessNotice(help: help, style: .note, github: github) {
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
                        if let access = session.githubAccess,
                           let help = GitHubAccessHelp.forAccess(access, repository: session.githubRepository, purpose: .read, details: session.githubDetails) {
                            GitHubAccessNotice(help: help, style: .banner, github: github) {
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
            .frame(width: 300)
            DesignDivider(vertical: true)
            Group {
                if let run = session.runs.first(where: { $0.id == selectedRunID }) {
                    RunInspectorView(run: run, workspaceID: session.workspaceID, hub: hub, github: github)
                        .id(run.id)
                } else {
                    UnavailableFeature(title: "Select a run", detail: "Choose a run to see its jobs, steps and logs.", symbol: "play.circle")
                        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selectedRunID == nil { selectedRunID = session.runs.first?.id } }
    }
}

/// Workflows section: the repository's workflows on GitHub with each one's
/// newest run.
struct WorkspaceWorkflowsView: View {
    let session: RepositorySession
    let hub: CoreHub
    let github: GitHubSession?
    var favorites: WorkflowFavorites?
    let showRun: (CoreWorkflowRun) -> Void
    let runWorkflow: (CoreGitHubWorkflow) -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let access = session.githubAccess,
                   let help = GitHubAccessHelp.forAccess(access, repository: session.githubRepository, purpose: .read, details: session.githubDetails) {
                    GitHubAccessNotice(help: help, style: .banner, github: github) {
                        Task { await hub.loadGitHubActivity(workspaceID: session.workspaceID) }
                    }.padding(.bottom, 12)
                } else if let installation = session.githubDetails?.installation,
                          let help = GitHubAccessHelp.installationBlocker(installation, purpose: .run, refused: false) {
                    // Workflows can be read, but starting them waits for an owner.
                    GitHubAccessNotice(help: help, style: .banner, github: github).padding(.bottom, 12)
                }
                ForEach(favorites?.ordered(session.remoteWorkflows, workspaceID: session.workspaceID, path: \.path) ?? session.remoteWorkflows) { workflow in
                    let latest = session.runs.first { $0.workflowID == workflow.id }
                    let favorite = favorites?.isFavorite(workflow.path, workspaceID: session.workspaceID) ?? false
                    HStack(spacing: 10) {
                        if let favorites, WorkflowFavorites.canFavorite(workflow.path) {
                            Button { favorites.toggle(workflow.path, workspaceID: session.workspaceID) } label: {
                                Image(systemName: favorite ? "star.fill" : "star")
                                    .foregroundStyle(favorite ? RunnirTheme.warning : RunnirTheme.mutedForeground)
                            }
                            .buttonStyle(.borderless).disabled(!favorites.isAvailable)
                            .help(favorite ? "Remove from favorites" : "Add to favorites; favorites come first")
                            .accessibilityLabel(favorite ? "Remove \(workflow.name) from favorites" : "Add \(workflow.name) to favorites")
                        }
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
                        if workflow.state == "active" {
                            Button("Run...") { runWorkflow(workflow) }.buttonStyle(.link).font(.system(size: 12))
                                .help("Start this workflow by hand if it has a workflow_dispatch trigger")
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
