import SwiftUI

/// One notification Runnir sent, kept in the bell's list.
struct InboxEntry: Codable, Identifiable, Equatable, Sendable {
    /// The notification's id: a new one with the same id replaces the entry.
    let id: String
    let title: String
    let body: String
    let succeeded: Bool
    let isLocalRun: Bool
    /// Opened when the entry is chosen: the pull request on GitHub.
    var url: URL?
    /// Shown when the entry is chosen: the workspace of a local run.
    var workspaceID: UUID?
    var at: Date
    var read = false
    /// When macOS took it to show. Only such an entry can be read by closing
    /// it there; one it never showed stays unread until opened here.
    var deliveredAt: Date?
}

/// notifications.json in the app's support directory: the bell's list.
struct FileNotificationInboxStore: Sendable {
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("notifications.json") }
    static let maxFileBytes = 512 * 1024

    static func live() throws -> FileNotificationInboxStore {
        FileNotificationInboxStore(directory: try RunnirSupportDirectory.url())
    }

    func load() throws -> [InboxEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maxFileBytes else { throw DesktopStoreError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode([InboxEntry].self, from: Data(contentsOf: fileURL))
    }

    func save(_ entries: [InboxEntry]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try AtomicFile.write(try encoder.encode(entries), to: fileURL)
    }
}

/// The notifications Runnir sent, newest first, with what is still unread.
/// One list for the whole app: read in one window, read in all.
///
/// An entry is read when it is opened from the bell, when the person came
/// from the system notification (clicked it), or when it was closed in the
/// system: dismissed, or cleared from Notification Center. A dismissal while
/// the app is not running is not reported, so the list is compared with what
/// macOS still delivers whenever the app starts or becomes active.
@MainActor
@Observable
final class NotificationInbox {
    /// The newest this many entries, and nothing older than the days below.
    static let maxEntries = 100
    static let keepDays = 30

    private(set) var entries: [InboxEntry] = []
    @ObservationIgnored private let store: FileNotificationInboxStore?
    @ObservationIgnored private let now: () -> Date

    init(store: FileNotificationInboxStore?, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
        entries = (try? store?.load()) ?? []
        trim()
    }

    var unreadCount: Int { entries.filter { !$0.read }.count }

    /// Adds a notification Runnir is sending, unread. A notification with the
    /// id of one already listed replaces it.
    func record(_ notification: RunNotification) {
        let entry = InboxEntry(id: notification.id, title: notification.title, body: notification.body, succeeded: notification.succeeded,
                               isLocalRun: notification.kind == .localRun, url: notification.url, workspaceID: notification.workspaceID, at: now())
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        trim()
        persist()
    }

    /// macOS took the notification to show.
    func markDelivered(_ id: String) {
        let at = now()
        update(id) { $0.deliveredAt = at }
    }

    func markRead(_ id: String) {
        update(id) { $0.read = true }
    }

    func markAllRead() {
        guard entries.contains(where: { !$0.read }) else { return }
        for index in entries.indices { entries[index].read = true }
        persist()
    }

    /// Entries macOS showed that it no longer holds were closed there.
    /// `checkedAt` is when the list of what it holds was asked for: an entry
    /// delivered after that is not in the list yet and stays as it is.
    func reconcile(stillDelivered ids: Set<String>, checkedAt: Date) {
        var changed = false
        for index in entries.indices where !entries[index].read && !ids.contains(entries[index].id) {
            guard let delivered = entries[index].deliveredAt, delivered < checkedAt else { continue }
            entries[index].read = true
            changed = true
        }
        if changed { persist() }
    }

    private func update(_ id: String, _ change: (inout InboxEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let before = entries[index]
        change(&entries[index])
        if entries[index] != before { persist() }
    }

    private func trim() {
        let cutoff = now().addingTimeInterval(-Double(Self.keepDays) * 86_400)
        entries.removeAll { $0.at < cutoff }
        if entries.count > Self.maxEntries { entries = Array(entries.prefix(Self.maxEntries)) }
    }

    private func persist() {
        try? store?.save(entries)
    }
}

// MARK: The bell

/// The bell in the title strip: the number of unread notifications; a click
/// opens or closes the list, which the window shows (`NotificationPanel`).
struct NotificationBell: View {
    let inbox: NotificationInbox
    @Binding var showing: Bool

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "bell")
                .font(.system(size: 14))
                .foregroundStyle(inbox.unreadCount > 0 ? RunnirTheme.foreground : RunnirTheme.secondaryForeground)
                .frame(width: 30, height: 30)
                // Pressed while its list is open.
                .background(showing ? RunnirTheme.selected : RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(RunnirTheme.border))
                .overlay(alignment: .topTrailing) {
                    if inbox.unreadCount > 0 {
                        Text(inbox.unreadCount > 99 ? "99+" : "\(inbox.unreadCount)")
                            .font(.system(size: 9.5, weight: .bold)).foregroundStyle(RunnirTheme.primaryForeground)
                            .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                            .background(RunnirTheme.primary, in: Capsule())
                            .overlay(Capsule().stroke(RunnirTheme.window, lineWidth: 2))
                            .offset(x: 5, y: -5)
                    }
                }
        }
        .buttonStyle(.hit)
        .help(inbox.unreadCount > 0 ? "\(inbox.unreadCount) unread notifications" : "Notifications")
        .accessibilityLabel("Notifications")
        .accessibilityValue(inbox.unreadCount > 0 ? "\(inbox.unreadCount) unread" : "none unread")
    }
}

/// The bell's list as a panel under the title strip, as drawn (S19): an
/// opaque surface with a border and a shadow, no arrow. A click outside it,
/// Escape or the bell closes it.
struct NotificationPanel: View {
    let inbox: NotificationInbox
    let open: (InboxEntry) -> Void
    let openSettings: () -> Void
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // No hand pointer: a click outside the panel closes it.
            Color.clear.contentShape(Rectangle()).onTapGesture(perform: close).accessibilityHidden(true)
            NotificationList(inbox: inbox, open: { entry in
                close()
                open(entry)
            }, openSettings: {
                close()
                openSettings()
            })
            .background(RunnirTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(RunnirTheme.border))
            .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
            .padding(.top, 44).padding(.trailing, 16)
            // Escape closes the panel.
            Button("Close notifications", action: close)
                .keyboardShortcut(.cancelAction).buttonStyle(.hit).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .transition(.opacity)
    }
}

/// When a notification was sent, as the list words it: "now", "12 min ago",
/// "3 h ago", "Yesterday", "4 days ago", then the date.
enum NotificationTime {
    static func text(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600)) h ago" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 1 { return "Yesterday" }
        if days < 7 { return "\(days) days ago" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

struct NotificationList: View {
    let inbox: NotificationInbox
    let open: (InboxEntry) -> Void
    let openSettings: () -> Void
    /// The entry under the pointer, drawn as the one a click opens.
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notifications").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { inbox.markAllRead() } label: {
                    Text("Mark all as read").font(.system(size: 12))
                        .foregroundStyle(inbox.unreadCount == 0 ? RunnirTheme.mutedForeground : RunnirTheme.primary)
                }
                .buttonStyle(.hit).disabled(inbox.unreadCount == 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            DesignDivider()
            if inbox.entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bell.slash").font(.system(size: 22)).foregroundStyle(RunnirTheme.mutedForeground)
                    Text("Nothing yet").font(.system(size: 13, weight: .medium))
                    Text("Runnir lists here what it notifies you about: finished pull request checks and local runs.")
                        .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).multilineTextAlignment(.center)
                }
                .padding(24).frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(inbox.entries) { entry in
                            row(entry)
                            DesignDivider()
                        }
                    }
                }.frame(maxHeight: 480)
            }
            DesignDivider()
            Button { openSettings() } label: {
                Text("Notification Settings\u{2026}").font(.system(size: 12)).foregroundStyle(RunnirTheme.primary)
            }
            .buttonStyle(.hit).padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 360)
    }

    private func row(_ entry: InboxEntry) -> some View {
        Button { open(entry) } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(entry.read ? Color.clear : RunnirTheme.primary).frame(width: 7, height: 7).padding(.top, 6)
                Image(systemName: entry.succeeded ? "checkmark.circle" : "xmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(entry.succeeded ? RunnirTheme.success : RunnirTheme.destructive).padding(.top, 1)
                    .accessibilityLabel(entry.succeeded ? "Passed" : "Failed")
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.system(size: 12.5, weight: entry.read ? .regular : .semibold)).lineLimit(2)
                    Text(entry.body).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(NotificationTime.text(entry.at))
                        .font(.system(size: 11)).foregroundStyle(RunnirTheme.mutedForeground)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(hovered == entry.id ? RunnirTheme.selected : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hit)
        .onHover { inside in
            if inside { hovered = entry.id } else if hovered == entry.id { hovered = nil }
        }
        .accessibilityValue(entry.read ? "read" : "unread")
    }
}
