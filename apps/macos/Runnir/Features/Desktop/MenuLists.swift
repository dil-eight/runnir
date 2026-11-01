import SwiftUI

// What the menu bar's lists share (S19, B39): pull requests and runs, in the
// menu bar window and the Pull Requests window.

// MARK: Dismissed items

/// A JSON file in the app's support directory of items removed from a menu
/// bar list, by key, with when: closed pull requests in
/// dismissed-pull-requests.json, failed runs in dismissed-runs.json.
/// Entries older than a week are dropped.
struct FileDismissalStore: Sendable {
    let fileURL: URL

    static let pullRequestsFile = "dismissed-pull-requests.json"
    static let runsFile = "dismissed-runs.json"
    static let maxEntries = 1000
    static let maxFileBytes = 256 * 1024
    static let keepFor: TimeInterval = 7 * 24 * 3600

    private struct Snapshot: Codable {
        var version = 1
        var dismissed: [String: Date]
    }

    init(directory: URL, fileName: String) {
        fileURL = directory.appendingPathComponent(fileName)
    }

    static func live(_ fileName: String) throws -> FileDismissalStore {
        FileDismissalStore(directory: try RunnirSupportDirectory.url(), fileName: fileName)
    }

    func load() throws -> [String: Date] {
        guard let snapshot = try JSONFile.read(Snapshot.self, from: fileURL, maxBytes: Self.maxFileBytes) else { return [:] }
        guard snapshot.version == 1, snapshot.dismissed.count <= Self.maxEntries else { throw DesktopStoreError.invalidState }
        return snapshot.dismissed
    }

    func save(_ dismissed: [String: Date]) throws {
        guard dismissed.count <= Self.maxEntries else { throw DesktopStoreError.invalidState }
        try JSONFile.write(Snapshot(dismissed: dismissed), to: fileURL, maxBytes: Self.maxFileBytes)
    }
}

/// The items removed from one menu bar list on this Mac, by key, with when,
/// kept a week in their store.
struct Dismissals {
    private(set) var items: [String: Date]
    private let store: FileDismissalStore?

    init(store: FileDismissalStore?, now: Date = Date()) {
        self.store = store
        items = Self.recent((try? store?.load()) ?? [:], now: now)
    }

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }
    func contains(_ key: String) -> Bool { items[key] != nil }

    /// Removes one more item, and saves the list.
    mutating func add(_ key: String, at now: Date) {
        var candidate = items
        candidate[key] = now
        candidate = Self.recent(candidate, now: now)
        try? store?.save(candidate)
        items = candidate
    }

    /// Brings every item back.
    mutating func removeAll() {
        try? store?.save([:])
        items = [:]
    }

    private static func recent(_ items: [String: Date], now: Date) -> [String: Date] {
        let cutoff = now.addingTimeInterval(-FileDismissalStore.keepFor)
        return items.filter { $0.value > cutoff }
    }
}

// MARK: Reading

/// A menu bar list read from the Core every three minutes while signed in,
/// and again when the menu or the window opens on a list older than a
/// minute.
@MainActor
protocol MenuList: AnyObject {
    var loadedAt: Date? { get }
    var isLoading: Bool { get }
    var dismissed: Dismissals { get }
    var now: () -> Date { get }
    /// Runs the polling loop; the list keeps it.
    var poller: MenuListPoller { get }
    /// Nothing was read yet because the Core gave no answer: asked again
    /// within seconds, not minutes.
    var awaitingCore: Bool { get }
    /// The list read still answers what is asked now.
    var isCurrent: Bool { get }
    /// What the list is of changed since it was read: read at once.
    var isOutdated: Bool { get }
    /// After "Updated …" in the header.
    var updatedDetail: String { get }
    /// Reads the list; `force` asks GitHub again however recently it was read.
    func refresh(hub: CoreHub, force: Bool) async
    /// Forgets the list when no account is signed in.
    func clear()
    /// Brings back the items removed from the list.
    func restoreDismissed()
}

extension MenuList {
    var isOutdated: Bool { false }
    var updatedDetail: String { "" }

    /// Reads again when the list is older than a minute or no longer current.
    func refreshIfStale(hub: CoreHub) async {
        if let loadedAt, now().timeIntervalSince(loadedAt) < MenuListPoller.staleAfter, isCurrent { return }
        await refresh(hub: hub, force: false)
    }

    /// Reads every three minutes while `isSignedIn` holds, looking every
    /// `retry`: a sign-in (the saved one comes up after launch, as does the
    /// Core) or a change of what the list is of is read within seconds, so
    /// the menu bar icon is right, and a sign-out clears the list.
    func startPolling(hub: CoreHub, retry: Duration = .seconds(5), isSignedIn: @escaping @MainActor () -> Bool) {
        poller.start(self, hub: hub, retry: retry, isSignedIn: isSignedIn)
    }

    func stopPolling() { poller.stop() }
}

/// The polling loop of a MenuList.
@MainActor
final class MenuListPoller {
    static let interval: Duration = .seconds(180)
    static let staleAfter: TimeInterval = 60
    private var task: Task<Void, Never>?

    func start(_ list: some MenuList, hub: CoreHub, retry: Duration, isSignedIn: @escaping @MainActor () -> Bool) {
        task?.cancel()
        task = Task { [weak list] in
            let clock = ContinuousClock()
            var lastRead: ContinuousClock.Instant?
            while !Task.isCancelled {
                guard let list else { return }
                if !isSignedIn() {
                    list.clear()
                    lastRead = nil
                } else {
                    let every = list.loadedAt == nil && list.awaitingCore ? retry : Self.interval
                    if list.isOutdated || lastRead.map({ clock.now - $0 >= every }) ?? true {
                        lastRead = clock.now
                        await list.refresh(hub: hub, force: false)
                    }
                }
                try? await Task.sleep(for: retry)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

// MARK: Views

/// What a menu bar list shows: signed out, checking the saved sign-in, or
/// the list.
enum MenuListState: Equatable {
    case restoring, signedOut, lists

    @MainActor
    static func of(_ desktop: DesktopCoordinator) -> MenuListState {
        let enterprise = !(desktop.core?.signedInServers.isEmpty ?? true)
        guard let github = desktop.github, github.user == nil, !enterprise else { return .lists }
        if case .restoring = github.connection { return .restoring }
        return .signedOut
    }
}

/// A menu bar list's place: the saved sign-in being checked, the signed-out
/// screen, or the list itself.
struct MenuListContent<Lists: View>: View {
    let desktop: DesktopCoordinator
    let inset: CGFloat
    @ViewBuilder var lists: Lists

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch MenuListState.of(desktop) {
            case .restoring:
                ListProgress(text: "Checking the saved sign-in...").padding(.horizontal, inset).padding(.vertical, 16)
            case .signedOut:
                PullRequestsSignedOut(desktop: desktop)
            case .lists:
                lists
            }
        }
    }
}

/// A spinner with what is being read.
struct ListProgress: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(text) }
            .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
    }
}

/// A note about a menu bar list, in small secondary text.
struct ListNote: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What a menu bar list shows with nothing in it: a symbol, a title, a line
/// under it and, for some, a button.
struct ListEmptyState<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String?
    let inset: CGFloat
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(tint)
            Text(title).font(.system(size: 13, weight: .medium))
            if let detail {
                Text(detail)
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            accessory
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, inset).padding(.top, 14).padding(.bottom, 16)
    }
}

extension ListEmptyState where Accessory == EmptyView {
    init(symbol: String, tint: Color, title: String, detail: String?, inset: CGFloat) {
        self.init(symbol: symbol, tint: tint, title: title, detail: detail, inset: inset) { EmptyView() }
    }
}

/// The chips counting a menu bar list's items, read by VoiceOver as one.
struct ListChips<Content: View>: View {
    let inset: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .padding(.horizontal, inset).padding(.bottom, 12)
            .accessibilityElement(children: .combine)
    }
}

/// A count with a symbol above a menu bar list: "2 failing", "3 running".
struct ListChip: View {
    let symbol: String
    let label: String
    let tint: Color
    let background: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(label).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(background))
    }
}

/// A section's title and count in a menu bar list.
struct ListSectionHeader: View {
    let title: String
    let count: Int
    let inset: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(RunnirTheme.secondaryForeground)
            Text("\(count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(RunnirTheme.mutedForeground)
        }
        .padding(.horizontal, inset).padding(.top, 10).padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Removes a row from a menu bar list: a 28-point target with its own
/// hover, so a near miss removes instead of opening the row under it. It
/// shows while the row is hovered; VoiceOver removes with the row's action.
struct ListRemoveButton: View {
    let visible: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? RunnirTheme.foreground : RunnirTheme.secondaryForeground)
                .frame(width: 28, height: 28)
                .background(Circle().fill(hovering ? RunnirTheme.secondary : .clear).frame(width: 22, height: 22))
        }
        .buttonStyle(.hit)
        .onHover { hovering = $0 }
        .opacity(visible ? 1 : 0)
        .padding(.top, -6).padding(.trailing, -6)
        .help("Remove from this list")
        .accessibilityHidden(true)
    }
}

extension View {
    /// A row of a menu bar list: highlighted while hovered, opening on a
    /// click, and one VoiceOver button that opens, with a Remove action when
    /// the row can be removed.
    func menuListRow(hovering: Binding<Bool>, help: String, open: @escaping () -> Void, remove: (() -> Void)?) -> some View {
        padding(.vertical, 7).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering.wrappedValue ? RunnirTheme.selected : .clear))
            .clickable()
            .onHover { hovering.wrappedValue = $0 }
            .onTapGesture(perform: open)
            .help(help)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open() }
            .accessibilityActions {
                if let remove { Button("Remove from this list", action: remove) }
            }
    }
}
