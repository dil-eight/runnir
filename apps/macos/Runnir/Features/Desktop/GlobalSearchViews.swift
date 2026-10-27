import SwiftUI

/// The search field in the middle of the title strip. It is a button that
/// opens the results layer, where the typing happens.
struct GlobalSearchField: View {
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(RunnirTheme.mutedForeground)
                Text("Search runs, pull requests, workflows and settings")
                    .font(.system(size: 12.5)).foregroundStyle(RunnirTheme.mutedForeground).lineLimit(1)
                Spacer(minLength: 8)
                Text("\u{2318}K").font(.system(size: 11, weight: .medium)).foregroundStyle(RunnirTheme.mutedForeground)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RunnirTheme.selected, in: RoundedRectangle(cornerRadius: 5))
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(hovering ? RunnirTheme.selected : RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(RunnirTheme.border))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.hit)
        .keyboardShortcut("k", modifiers: .command)
        .onHover { hovering = $0 }
        .help("Search everything saved on this Mac (\u{2318}K)")
        .accessibilityLabel("Search")
        .accessibilityIdentifier("global-search-field")
    }
}

/// The results of the global search, in a layer under the field: scope,
/// kinds with counts, the results grouped by kind, and the keys.
struct GlobalSearchLayer: View {
    @Bindable var model: GlobalSearchModel
    let choose: (SearchResult) -> Void
    let close: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            // No hand pointer: a click outside the panel closes it.
            Color.black.opacity(0.18).contentShape(Rectangle()).onTapGesture(perform: close).accessibilityHidden(true)
            panel.padding(.top, 46)
        }
        .transition(.opacity)
        .onAppear { focused = true }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            queryRow
            DesignDivider()
            tabs
            DesignDivider()
            content
            DesignDivider()
            footer
        }
        .frame(width: 700)
        .frame(maxHeight: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(RunnirTheme.surface)
        .foregroundStyle(RunnirTheme.foreground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RunnirTheme.border))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search")
    }

    // MARK: Query

    private var queryRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(RunnirTheme.secondaryForeground)
            TextField("Search runs, pull requests, workflows and settings", text: $text)
                .textFieldStyle(.plain).font(.system(size: 15))
                .focused($focused)
                .onChange(of: text) { _, value in model.update(query: value) }
                .onSubmit { if let selected = model.selected { choose(selected) } }
                .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                .accessibilityIdentifier("global-search-input")
            if model.status == .searching { ProgressView().controlSize(.small) }
            Picker("Search in", selection: $model.scope) {
                Text("All workspaces").tag(GlobalSearchModel.Scope.all)
                Text("This workspace").tag(GlobalSearchModel.Scope.thisWorkspace)
            }
            .pickerStyle(.segmented).labelsHidden().pointerStyle(.link).fixedSize()
            .accessibilityLabel("Search in")
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(GlobalSearchModel.Tab.allCases, id: \.self) { tab in
                let selected = model.tab == tab
                Button { model.tab = tab } label: {
                    HStack(spacing: 5) {
                        Text(tab.title)
                        Text("\(model.count(tab))").foregroundStyle(RunnirTheme.mutedForeground)
                    }
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(selected ? RunnirTheme.selected : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.hit)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    // MARK: Results

    @ViewBuilder private var content: some View {
        if model.query.isEmpty {
            note(symbol: "magnifyingglass", title: "Search everything saved on this Mac",
                 detail: "Runs, pull requests, workflows and local runs of your workspaces, and settings. "
                    + "Try branch:main status:failed, a commit hash, or #142. Nothing is sent to GitHub.")
        } else if model.visible.isEmpty {
            if model.status == .searching {
                note(symbol: "hourglass", title: "Searching\u{2026}", detail: nil)
            } else {
                note(symbol: "questionmark.circle", title: "Nothing found for \u{201C}\(model.query)\u{201D}",
                     detail: model.status == .unavailable ? "Runnir Core is not running, so only settings were searched."
                        : "Only what is saved on this Mac is searched. Runs older than the saved ones can be searched on GitHub from the Runs list.")
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.kind) { group in
                            RunGroupHeader(title: "\(group.kind.title.uppercased()) \u{00B7} \(group.rows.filter { !$0.isMore }.count)")
                            ForEach(group.rows) { result in
                                row(result).id(result.id)
                            }
                        }
                        ForEach(Array(model.unreadable.enumerated()), id: \.offset) { _, item in
                            Label("\(item.name): \(item.reason)", systemImage: "exclamationmark.triangle")
                                .font(.system(size: 11)).foregroundStyle(RunnirTheme.warning).padding(.horizontal, 14).padding(.top, 8)
                        }
                        ForEach(model.problems, id: \.self) { problem in
                            Label(problem, systemImage: "info.circle")
                                .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).padding(.horizontal, 14).padding(.top, 8)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 400)
                .onChange(of: model.selection) { _, id in if let id { proxy.scrollTo(id) } }
            }
        }
    }

    private var groups: [(kind: SearchResult.Kind, rows: [SearchResult])] {
        SearchResult.Kind.allCases.compactMap { kind in
            let rows = model.visible.filter { $0.kind == kind }
            return rows.isEmpty ? nil : (kind, rows)
        }
    }

    private func note(symbol: String, title: String, detail: String?) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(RunnirTheme.mutedForeground)
            Text(title).font(.system(size: 13, weight: .medium))
            if let detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 40).padding(.vertical, 28).frame(maxWidth: .infinity)
    }

    private func row(_ result: SearchResult) -> some View {
        let selected = result.id == model.selection
        return Button { choose(result) } label: {
            HStack(alignment: .top, spacing: 10) {
                if let outcome = result.outcome {
                    RunOutcomeIcon(outcome: outcome).frame(width: 18).padding(.top, 1)
                } else {
                    Image(systemName: result.isMore ? "ellipsis.circle" : result.kind.symbol).font(.system(size: 13))
                        .foregroundStyle(RunnirTheme.secondaryForeground).frame(width: 18).padding(.top, 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.isMore ? AttributedString(result.title) : SearchText.marked(result.title, words: model.words))
                        .font(.system(size: 13, weight: result.isMore ? .regular : .medium)).lineLimit(1)
                        .foregroundStyle(result.isMore ? RunnirTheme.primary : RunnirTheme.foreground)
                    Text(result.isMore ? AttributedString(result.detail) : SearchText.marked(result.detail, words: model.words))
                        .font(.system(size: 11.5)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let place = place(of: result) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(place).font(.system(size: 11.5)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
                        if let age = result.age { Text(age).font(.system(size: 11)).foregroundStyle(RunnirTheme.mutedForeground).lineLimit(1) }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(selected ? RunnirTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hit)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func place(of result: SearchResult) -> String? {
        if case .setting(let section) = result.destination { return "Settings \u{203A} \(section.title)" }
        return result.workspaceName
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            if !model.query.isEmpty {
                Button { choose(Self.githubRow(model.query, workspace: model.currentWorkspaceID)) } label: {
                    Label("Runs older than the saved ones: search GitHub\u{2026}", systemImage: "network")
                }
                .buttonStyle(.link).pointerStyle(.link)
                .help("Opens the Runs list with this search; the deep search on GitHub starts there, from a button")
            }
            Spacer(minLength: 0)
            keyHint("\u{2191}\u{2193}", "move")
            keyHint("\u{21A9}", "open")
            keyHint("esc", "close")
        }
        .font(.system(size: 11.5)).foregroundStyle(RunnirTheme.secondaryForeground)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func keyHint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 11, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 1)
                .background(RunnirTheme.selected, in: RoundedRectangle(cornerRadius: 4))
            Text(action)
        }
    }

    /// The row that stands for the footer's link: the Runs list of the
    /// window's workspace with the typed query.
    static func githubRow(_ query: String, workspace: UUID) -> SearchResult {
        SearchResult(id: "github-search", kind: .run, title: "Search GitHub", detail: query, workspaceID: workspace, workspaceName: nil,
                     age: nil, outcome: nil, destination: .runsList(query: query), isMore: true)
    }
}
