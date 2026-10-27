import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite struct NotificationInboxTests {
    private func notification(_ id: String, succeeded: Bool = false, url: URL? = nil) -> RunNotification {
        RunNotification(id: id, kind: .pullRequestChecks, succeeded: succeeded, title: "Checks · \(id)", body: "body", url: url)
    }

    private func inbox(now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_000_000) }) -> NotificationInbox {
        NotificationInbox(store: nil, now: now)
    }

    @Test func aSentNotificationIsUnreadAndCounted() {
        let inbox = inbox()
        #expect(inbox.unreadCount == 0)
        inbox.record(notification("a"))
        inbox.record(notification("b", succeeded: true))
        #expect(inbox.unreadCount == 2)
        #expect(inbox.entries.map(\.id) == ["b", "a"], "newest first")
    }

    @Test func aNotificationWithTheSameIdReplacesTheEntryAndIsUnreadAgain() {
        let inbox = inbox()
        inbox.record(notification("a"))
        inbox.markRead("a")
        #expect(inbox.unreadCount == 0)
        inbox.record(notification("a"))
        #expect(inbox.entries.count == 1 && inbox.unreadCount == 1)
    }

    @Test func openingFromTheBellOrClickingTheSystemNotificationReadsIt() {
        let inbox = inbox()
        inbox.record(notification("a"))
        inbox.record(notification("b"))
        inbox.markRead("a")
        #expect(inbox.entries.first { $0.id == "a" }?.read == true && inbox.unreadCount == 1)
        inbox.markAllRead()
        #expect(inbox.unreadCount == 0)
    }

    @Test func anEntryMacOSNoLongerHoldsWasClosedThereAndIsRead() {
        let inbox = inbox()
        inbox.record(notification("shown"))
        inbox.record(notification("never shown"))
        inbox.record(notification("still there"))
        inbox.markDelivered("shown")
        inbox.markDelivered("still there")
        inbox.reconcile(stillDelivered: ["still there"])
        #expect(inbox.entries.first { $0.id == "shown" }?.read == true, "cleared in Notification Center")
        #expect(inbox.entries.first { $0.id == "still there" }?.read == false)
        #expect(inbox.entries.first { $0.id == "never shown" }?.read == false, "macOS never showed it, so it can only be read here")
    }

    @Test func theListKeepsTheNewestHundredFromTheLastThirtyDays() {
        var clock = Date(timeIntervalSince1970: 10_000_000)
        let inbox = inbox(now: { clock })
        inbox.record(notification("old"))
        clock = clock.addingTimeInterval(31 * 86_400)
        for number in 0..<(NotificationInbox.maxEntries + 5) { inbox.record(notification("n\(number)")) }
        #expect(inbox.entries.count == NotificationInbox.maxEntries)
        #expect(!inbox.entries.contains { $0.id == "old" })
        #expect(inbox.entries.first?.id == "n\(NotificationInbox.maxEntries + 4)")
    }

    @Test func theListSurvivesARestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileNotificationInboxStore(directory: directory)
        let first = NotificationInbox(store: store, now: { Date() })
        first.record(notification("a", url: URL(string: "https://github.com/o/r/pull/1")))
        first.record(notification("b"))
        first.markRead("b")
        let second = NotificationInbox(store: store, now: { Date() })
        #expect(second.entries.map(\.id) == ["b", "a"])
        #expect(second.entries.first?.read == true && second.unreadCount == 1)
        #expect(second.entries.last?.url?.absoluteString == "https://github.com/o/r/pull/1")
    }
}
