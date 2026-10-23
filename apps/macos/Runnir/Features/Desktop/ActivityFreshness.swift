import SwiftUI

/// The one line that says how fresh a workspace's GitHub activity is.
enum ActivityFreshnessText {
    static func line(_ f: CoreActivityFreshness, now: Date) -> String? {
        if f.syncing { return f.source == .none ? "Loading activity…" : "Refreshing…" }
        switch f.source {
        case .none:
            return nil
        case .cache:
            guard let synced = f.syncedAt else { return "Showing saved activity" }
            return "Showing saved activity · synced \(relative(synced, now))"
        case .live:
            guard f.access == .ok else {
                return f.syncedAt.map { "Showing activity from \(relative($0, now))" }
            }
            let checked = f.checkedAt.map { relative($0, now) } ?? "just now"
            if let changed = f.changedAt, let synced = f.syncedAt, changed < synced {
                return "No changes since \(relative(changed, now)) · checked \(checked)"
            }
            return "Up to date · checked \(checked)"
        }
    }

    static func relative(_ date: Date, _ now: Date) -> String {
        if abs(now.timeIntervalSince(date)) < 10 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// Shows `ActivityFreshnessText` for a session and keeps the times current.
struct ActivityFreshnessLine: View {
    let session: RepositorySession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let text = ActivityFreshnessText.line(session.freshness, now: context.date) {
                Text(text)
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                    .accessibilityIdentifier("activity-freshness")
            }
        }
    }
}
