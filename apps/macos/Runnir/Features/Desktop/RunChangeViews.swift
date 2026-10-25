import SwiftUI

/// A small capsule label next to a run's title.
struct RunTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(tint)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

/// The concurrency suggestion: what happened and the two choices.
struct ConcurrencyHintBanner: View {
    let hint: CoreConcurrencyHint
    let workflowName: String
    let add: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb").foregroundStyle(RunnirTheme.info)
            VStack(alignment: .leading, spacing: 6) {
                Text(RunPresentation.hintText(hint, workflowName: workflowName))
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                // Side by side where they fit, one under the other in a narrow list.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { buttons }
                    VStack(alignment: .leading, spacing: 8) { buttons }
                }.font(.system(size: 12))
            }
            Spacer(minLength: 0)
        }
        .padding(12).background(RunnirTheme.info.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private var buttons: some View {
        Button("Add concurrency…", action: add).buttonStyle(DesignButtonStyle(primary: true)).fixedSize()
            .help("Open \(hint.path) in the editor with a block that cancels runs a newer commit replaced. Nothing is saved until you save it.")
        Button("Don't suggest for this workflow", action: dismiss).buttonStyle(.link).pointerStyle(.link).fixedSize()
    }
}

/// One change in By change: its header, its sections, the runs it folds
/// away, and a concurrency suggestion that names its pull request.
struct RunChangeBlock: View {
    let change: CoreRunChange
    let runs: [Int64: CoreWorkflowRun]
    let selectedRunID: Int64?
    @Binding var expanded: Set<String>
    let hints: [CoreConcurrencyHint]
    let workflowName: (Int64) -> String
    let select: (Int64) -> Void
    let addConcurrency: (String) -> Void
    let dismissHint: (String) -> Void

    /// Where the runs start: under the header's title, so they read as its.
    static let indent: CGFloat = 32

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            header
            ForEach(Array(change.sections.enumerated()), id: \.offset) { _, section in
                if let title = RunPresentation.sectionTitle(section) {
                    Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(RunnirTheme.mutedForeground)
                        .padding(.leading, Self.indent).padding(.trailing, 10).padding(.top, 5).padding(.bottom, 1)
                }
                rows(section.runIDs)
                if let text = RunPresentation.repeatsText(section) {
                    expander(text, key: "\(change.id)/\(section.headSHA)/repeats", ids: section.repeatRunIDs)
                }
            }
            if let text = RunPresentation.olderText(change) {
                expander(text, key: "\(change.id)/older", ids: change.olderRunIDs)
            }
            ForEach(hints, id: \.workflowID) { hint in
                ConcurrencyHintBanner(hint: hint, workflowName: workflowName(hint.workflowID),
                                      add: { addConcurrency(hint.path) }, dismiss: { dismissHint(hint.path) })
                    .padding(.leading, Self.indent - 6).padding(.trailing, 6).padding(.top, 4)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { DesignDivider() }
    }

    /// The pull request (number, title, state) or commit, and under it the
    /// branches, so the rows below need not repeat them.
    private var header: some View {
        let icon = PullRequestRow.ciIcon(change.status)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon.symbol).foregroundStyle(icon.tint).font(.system(size: 13)).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(RunPresentation.changeTitle(change)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    if let pullRequest = change.pullRequest, let state = RunPresentation.stateLabel(pullRequest) {
                        RunTag(text: state, tint: RunnirTheme.secondaryForeground)
                    }
                }
                if let subtitle = RunPresentation.changeSubtitle(change) {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func rows(_ ids: [Int64]) -> some View {
        ForEach(ids.compactMap { runs[$0] }) { run in
            RunChangeRow(run: run, selected: run.id == selectedRunID, pullRequest: change.pullRequest, newer: newer(run))
                .clickable().onTapGesture { select(run.id) }
        }
    }

    private func newer(_ run: CoreWorkflowRun) -> CoreWorkflowRun? {
        run.supersededBy.flatMap { runs[$0] }
    }

    @ViewBuilder private func expander(_ text: String, key: String, ids: [Int64]) -> some View {
        let open = expanded.contains(key)
        Button {
            if open { expanded.remove(key) } else { expanded.insert(key) }
        } label: {
            Label(text, systemImage: open ? "chevron.down" : "chevron.right").font(.system(size: 11))
                .foregroundStyle(RunnirTheme.secondaryForeground)
                .padding(.leading, Self.indent).padding(.trailing, 10).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.hit)
        if open { rows(ids) }
    }
}

/// A run inside a change: a status dot, workflow and number, event and age
/// on one line. The change's header already names the pull request, commit
/// and branches.
struct RunChangeRow: View {
    let run: CoreWorkflowRun
    var selected = false
    var pullRequest: CoreChangePullRequest? = nil
    var newer: CoreWorkflowRun? = nil

    private var dimmed: Bool { run.isSuperseded && !run.outcome.isActive }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(RunOutcomeIcon.color(run.outcome)).frame(width: 6, height: 6)
                .accessibilityLabel(run.outcome.label)
            Text("\(run.name) #\(run.runNumber)").font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(run.event).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
            if run.isOutdated {
                RunTag(text: "outdated", tint: RunnirTheme.info).help(RunPresentation.outdatedHelp(run, newer: newer))
            } else if dimmed {
                RunTag(text: "older commit", tint: RunnirTheme.secondaryForeground)
            }
            Spacer(minLength: 8)
            if let created = run.createdAt {
                Text(created, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                    .lineLimit(1).fixedSize()
            }
        }
        .opacity(dimmed ? 0.6 : 1)
        .padding(.leading, RunChangeBlock.indent - 1).padding(.trailing, 10).frame(height: 26)
        .clickable()
        .background(selected ? RunnirTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
        .help(([run.title] + [RunPresentation.rowHelp(run, pullRequest: pullRequest)]).joined(separator: "\n"))
        .accessibilityElement(children: .combine)
    }
}

/// The end of a run list. While it is on screen it asks for more runs: from
/// the cache first, then one page of older runs from GitHub.
struct OlderRunsFooter: View {
    let session: RepositorySession
    let hub: CoreHub
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            switch session.olderRuns {
            case .loading:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading older runs…") }
            case .failed:
                HStack(spacing: 8) {
                    Text("Couldn't load older runs.")
                    Button("Retry") { Task { await hub.showMoreRuns(workspaceID: session.workspaceID) } }.buttonStyle(.link).pointerStyle(.link)
                }
            case .budgetReached:
                HStack(spacing: 8) {
                    Text("Older runs are on GitHub.")
                    if let url = RunPresentation.actionsURL(session.runs) {
                        Button("Open Actions on GitHub") { openURL(url) }.buttonStyle(.link).pointerStyle(.link)
                    }
                }
            case .idle:
                Color.clear.frame(height: 1)
            }
        }
        .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).padding(10)
        .task(id: session.runs.count) {
            guard session.olderRuns == .idle, !session.runs.isEmpty else { return }
            await hub.showMoreRuns(workspaceID: session.workspaceID)
        }
    }
}
