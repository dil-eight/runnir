import SwiftUI

/// The six statuses the runs list filters by. One mapping from a run to its
/// status, used by the list, the counts in the menu and the chips.
enum RunStatusFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case succeeded, failed, cancelled, running, queued, skipped

    var id: String { rawValue }

    var label: String {
        switch self {
        case .succeeded: "Success"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .running: "In progress"
        case .queued: "Queued"
        case .skipped: "Skipped"
        }
    }

    var symbol: String {
        switch self {
        case .succeeded: "checkmark.circle"
        case .failed: "xmark.circle"
        case .cancelled: "minus.circle"
        case .running: "arrow.triangle.2.circlepath"
        case .queued: "clock"
        case .skipped: "arrow.uturn.right.circle"
        }
    }

    var tint: Color {
        switch self {
        case .succeeded: RunnirTheme.success
        case .failed: RunnirTheme.destructive
        case .cancelled, .skipped: RunnirTheme.mutedForeground
        case .running: RunnirTheme.primary
        case .queued: RunnirTheme.secondaryForeground
        }
    }

    init(_ group: CoreRunStatusGroup) {
        switch group {
        case .succeeded: self = .succeeded
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        case .running: self = .running
        case .queued: self = .queued
        case .skipped: self = .skipped
        }
    }

    /// The status the Core put the run in (`runsearch.StatusOf`); nil when it
    /// gave none, and such a run matches no ticked status.
    static func of(_ run: CoreWorkflowRun) -> RunStatusFilter? {
        run.statusGroup.map(RunStatusFilter.init)
    }

    /// Whether the run has one of `statuses`.
    static func matches(_ run: CoreWorkflowRun, _ statuses: Set<RunStatusFilter>) -> Bool {
        of(run).map(statuses.contains) ?? false
    }

    /// The runs with one of `statuses`; all of them for none.
    static func filter(_ runs: [CoreWorkflowRun], statuses: Set<RunStatusFilter>) -> [CoreWorkflowRun] {
        guard !statuses.isEmpty else { return runs }
        return runs.filter { matches($0, statuses) }
    }

    /// How many runs have each status.
    static func counts(_ runs: [CoreWorkflowRun]) -> [RunStatusFilter: Int] {
        runs.reduce(into: [:]) { counts, run in
            if let status = of(run) { counts[status, default: 0] += 1 }
        }
    }
}

// MARK: Views

/// The filter icon button of the runs list: a menu of statuses with their
/// counts, and a dot on the button while any status is chosen.
struct StatusFilterButton: View {
    @Binding var statuses: Set<RunStatusFilter>
    /// Runs per status that match the typed query and the branch filter.
    let counts: [RunStatusFilter: Int]
    let query: String
    @State private var showing = false

    private var active: Bool { !statuses.isEmpty }

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? RunnirTheme.primary : RunnirTheme.secondaryForeground)
                .frame(width: 26, height: 26)
                .background(active ? RunnirTheme.selected : RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? RunnirTheme.primary : RunnirTheme.border))
                .overlay(alignment: .topTrailing) {
                    if active {
                        Circle().fill(RunnirTheme.primary).frame(width: 8, height: 8)
                            .overlay(Circle().stroke(RunnirTheme.background, lineWidth: 1.5)).offset(x: 3, y: -3)
                    }
                }
        }
        .buttonStyle(.hit)
        .help("Filter by status")
        .accessibilityLabel("Filter by status")
        .accessibilityValue(active ? "\(statuses.count) selected" : "none")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            StatusFilterMenu(statuses: $statuses, counts: counts, query: query)
        }
    }
}

struct StatusFilterMenu: View {
    @Binding var statuses: Set<RunStatusFilter>
    let counts: [RunStatusFilter: Int]
    let query: String

    private var typed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                SectionLabel(title: "STATUS")
                Spacer(minLength: 8)
                if !typed.isEmpty {
                    Text("matching \u{201C}\(typed)\u{201D}").font(.system(size: 11)).foregroundStyle(RunnirTheme.mutedForeground).lineLimit(1)
                }
            }.padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 4)
            ForEach(RunStatusFilter.allCases) { status in row(status) }
            DesignDivider().padding(.vertical, 4)
            HStack {
                Text("\(statuses.count) selected").font(.system(size: 11)).foregroundStyle(RunnirTheme.mutedForeground)
                Spacer()
                Button("Clear all") { statuses = [] }.buttonStyle(.link).pointerStyle(.link).font(.system(size: 11)).disabled(statuses.isEmpty)
            }.padding(.horizontal, 8).padding(.bottom, 6)
        }
        .padding(6).frame(width: 240)
    }

    private func row(_ status: RunStatusFilter) -> some View {
        let on = statuses.contains(status)
        let count = counts[status] ?? 0
        return Button {
            if on { statuses.remove(status) } else { statuses.insert(status) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 14))
                    .foregroundStyle(on ? RunnirTheme.primary : RunnirTheme.mutedForeground)
                Image(systemName: status.symbol).font(.system(size: 12)).foregroundStyle(status.tint).frame(width: 16)
                Text(status.label).font(.system(size: 12))
                Spacer(minLength: 8)
                Text("\(count)").font(.system(size: 11)).foregroundStyle(RunnirTheme.mutedForeground)
            }
            .padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
            .background(on ? RunnirTheme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            // A status nothing matches stays selectable, and a ticked one keeps its chip.
            .opacity(count == 0 && !on ? 0.5 : 1)
        }
        .buttonStyle(.hit)
        .accessibilityLabel("\(status.label), \(count) \(count == 1 ? "run" : "runs")")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The chosen statuses under the search field: each can be removed on its
/// own, and Clear all removes them all (the typed query stays).
struct StatusChips: View {
    @Binding var statuses: Set<RunStatusFilter>

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(RunStatusFilter.allCases.filter(statuses.contains)) { status in chip(status) }
                }
            }
            Button("Clear all") { statuses = [] }.buttonStyle(.link).pointerStyle(.link).font(.system(size: 11)).fixedSize()
        }
    }

    private func chip(_ status: RunStatusFilter) -> some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbol).font(.system(size: 10)).foregroundStyle(status.tint)
            Text(status.label).font(.system(size: 11))
            Button { statuses.remove(status) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.hit).foregroundStyle(RunnirTheme.secondaryForeground)
                .help("Remove the \(status.label) filter").accessibilityLabel("Remove the \(status.label) filter")
        }
        .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 3)
        .background(RunnirTheme.selected, in: Capsule()).overlay(Capsule().stroke(RunnirTheme.border))
        .fixedSize()
    }
}
