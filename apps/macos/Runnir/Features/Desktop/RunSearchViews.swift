import SwiftUI

/// A heading over a group of results in the runs list.
struct RunGroupHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 10.5, weight: .semibold)).tracking(0.5).foregroundStyle(RunnirTheme.mutedForeground)
            .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
    }
}

/// Under the results of a search: the way on to GitHub, and where a deep
/// search stands. It reads pages of 100 runs from GitHub, up to 10 a step,
/// filtering by what GitHub can and matching the rest here.
struct DeepSearchFooter: View {
    @Bindable var model: RunSearchModel
    /// GitHub can be asked: signed in and the repository readable.
    let githubReady: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.deep {
            case .idle:
                Button { model.searchGitHub() } label: { Label("Not found? Search GitHub\u{2026}", systemImage: "network") }
                    .buttonStyle(.link).pointerStyle(.link).disabled(!githubReady)
                    .help(githubReady ? "Read older runs from GitHub for this search; what it reads is kept in the search index"
                         : "Searching GitHub needs a signed-in account that can read this repository")
            case .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching GitHub\u{2026} \(model.runsRead.formatted()) runs read").foregroundStyle(RunnirTheme.secondaryForeground)
                    Spacer(minLength: 4)
                    Button("Cancel") { model.cancelDeep() }.buttonStyle(.link).pointerStyle(.link)
                }
            case .more:
                Text("Looked through \(model.runsRead.formatted()) runs\(lookedBack). Narrow the search with branch:, author: or after:, or search deeper.")
                    .foregroundStyle(RunnirTheme.secondaryForeground).fixedSize(horizontal: false, vertical: true)
                Button("Search deeper") { model.searchDeeper() }.buttonStyle(DesignButtonStyle())
            case .done:
                Text("Searched every run GitHub has\(lookedBack). \(foundText)").foregroundStyle(RunnirTheme.secondaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Search again") { model.searchGitHub() }.buttonStyle(.link).pointerStyle(.link)
            case .rateLimited(let until):
                Label("GitHub search is paused: the rate limit is used up\(resetText(until)). Saved runs and the search index still work.",
                      systemImage: "clock")
                    .foregroundStyle(RunnirTheme.warning).fixedSize(horizontal: false, vertical: true)
            case .failed:
                Label("GitHub could not be searched now.", systemImage: "exclamationmark.triangle").foregroundStyle(RunnirTheme.warning)
                Button("Try again") { model.searchGitHub() }.buttonStyle(.link).pointerStyle(.link)
            case .busy:
                Text("Another search of this repository is still running.").foregroundStyle(RunnirTheme.secondaryForeground)
                Button("Try again") { model.searchDeeper() }.buttonStyle(.link).pointerStyle(.link)
            }
        }
        .font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var lookedBack: String {
        model.lookedBackTo.map { ", back to \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
    }

    private var foundText: String {
        let count = model.githubRuns.count
        return count == 0 ? "None matched." : "\(count) matched."
    }

    private func resetText(_ date: Date?) -> String {
        guard let date else { return "" }
        return ", it resets \(date.formatted(.relative(presentation: .named)))"
    }
}
