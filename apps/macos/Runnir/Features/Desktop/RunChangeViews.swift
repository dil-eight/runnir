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
        Button("Don't suggest for this workflow", action: dismiss).buttonStyle(.link).fixedSize()
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            ForEach(Array(change.sections.enumerated()), id: \.offset) { _, section in
                if let title = RunPresentation.sectionTitle(section) {
                    Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(RunnirTheme.secondaryForeground)
                        .padding(.horizontal, 10).padding(.top, 4)
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
                    .padding(.horizontal, 6).padding(.top, 4)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { DesignDivider() }
    }

    private var header: some View {
        let icon = PullRequestRow.ciIcon(change.status)
        return HStack(spacing: 8) {
            Image(systemName: icon.symbol).foregroundStyle(icon.tint).font(.system(size: 13))
            Text(RunPresentation.changeTitle(change)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 6)
            if let pullRequest = change.pullRequest, let state = RunPresentation.stateLabel(pullRequest) {
                RunTag(text: state, tint: RunnirTheme.secondaryForeground)
            } else if change.pullRequest == nil, let branch = change.sections.first?.branch {
                Text(branch).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func rows(_ ids: [Int64]) -> some View {
        ForEach(ids.compactMap { runs[$0] }) { run in
            RunRow(run: run, selected: run.id == selectedRunID, pullRequest: change.pullRequest)
                .onTapGesture { select(run.id) }
        }
    }

    @ViewBuilder private func expander(_ text: String, key: String, ids: [Int64]) -> some View {
        let open = expanded.contains(key)
        Button {
            if open { expanded.remove(key) } else { expanded.insert(key) }
        } label: {
            Label(text, systemImage: open ? "chevron.down" : "chevron.right").font(.system(size: 11))
        }
        .buttonStyle(.borderless).foregroundStyle(RunnirTheme.secondaryForeground)
        .padding(.horizontal, 10).padding(.vertical, 2)
        if open { rows(ids) }
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
                    Button("Retry") { Task { await hub.showMoreRuns(workspaceID: session.workspaceID) } }.buttonStyle(.link)
                }
            case .budgetReached:
                HStack(spacing: 8) {
                    Text("Older runs are on GitHub.")
                    if let url = RunPresentation.actionsURL(session.runs) {
                        Button("Open Actions on GitHub") { openURL(url) }.buttonStyle(.link)
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
