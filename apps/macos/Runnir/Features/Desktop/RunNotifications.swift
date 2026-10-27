import AppKit
import SwiftUI
@preconcurrency import UserNotifications

/// A notification about a finished run, sent by this Mac only (S19).
struct RunNotification: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case pullRequestChecks, localRun }

    let id: String
    let kind: Kind
    let succeeded: Bool
    let title: String
    let body: String
    /// Opened when the notification is clicked: the pull request on GitHub.
    var url: URL?
    /// Shown when the notification is clicked: the workspace of a local run.
    var workspaceID: UUID?

    /// The checks of an open pull request finished: all passed, or one failed.
    static func checksFinished(_ pr: CorePullRequest) -> RunNotification? {
        let name = "\(pr.repository) #\(pr.number)"
        switch pr.ci {
        case .failed:
            let failed = pr.ciFailed == 1 ? "1 of \(pr.ciRuns) checks failed" : "\(pr.ciFailed) of \(pr.ciRuns) checks failed"
            return RunNotification(id: "pr:\(pr.id):failed", kind: .pullRequestChecks, succeeded: false,
                                   title: "Checks failed · \(name)", body: "\(pr.title) — \(failed).", url: pr.ciURL ?? pr.htmlURL)
        case .passed:
            let passed = pr.ciRuns == 1 ? "the check passed" : "all \(pr.ciRuns) checks passed"
            return RunNotification(id: "pr:\(pr.id):passed", kind: .pullRequestChecks, succeeded: true,
                                   title: "Checks passed · \(name)", body: "\(pr.title) — \(passed).", url: pr.htmlURL)
        default:
            return nil
        }
    }

    /// A local run finished; a stopped run, or one whose result is unknown,
    /// tells nothing worth a notification.
    @MainActor static func localRunFinished(_ run: LocalRunModel, workspaceName: String) -> RunNotification? {
        guard run.phase == .finished, run.lostMessage == nil, !run.stopRequested else { return nil }
        let plan = run.plan
        let workflow = plan.workflowName.isEmpty ? (plan.workflowID as NSString).lastPathComponent : plan.workflowName
        let job = plan.jobs.first { $0.id == plan.jobID }?.name
        let what = job.map { "\(workflow) › \($0)" } ?? workflow
        let duration = run.startedAt.flatMap { start in run.finishedAt.map { Self.duration($0.timeIntervalSince(start)) } }
        switch run.state {
        case .succeeded:
            let body = duration.map { "\(what) finished in \($0)." } ?? "\(what) finished."
            return RunNotification(id: "local:\(run.executionID)", kind: .localRun, succeeded: true,
                                   title: "Local run passed · \(workspaceName)", body: body, workspaceID: run.workspaceID)
        case .failed:
            var body = duration.map { "\(what) stopped after \($0)" } ?? "\(what) failed"
            body += run.exitCode.map { ": the job exited with code \($0)." } ?? "."
            return RunNotification(id: "local:\(run.executionID)", kind: .localRun, succeeded: false,
                                   title: "Local run failed · \(workspaceName)", body: body, workspaceID: run.workspaceID)
        default:
            return nil
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) s" }
        let minutes = total / 60, rest = total % 60
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }
}

/// Settings › Notifications, kept in UserDefaults. Both kinds are on by
/// default, for successes and failures.
enum NotificationSettings {
    static let pullRequestChecksKey = "notifications.pullRequestChecks"
    static let localRunsKey = "notifications.localRuns"
    static let failuresOnlyKey = "notifications.failuresOnly"

    static func allows(_ notification: RunNotification, in defaults: UserDefaults = .standard) -> Bool {
        let key = notification.kind == .pullRequestChecks ? pullRequestChecksKey : localRunsKey
        let enabled = defaults.object(forKey: key) as? Bool ?? true
        return enabled && (notification.succeeded ? !defaults.bool(forKey: failuresOnlyKey) : true)
    }
}

/// Sends run notifications through macOS's notification center, asking for
/// permission the first time, and opens what a clicked one is about.
@MainActor
final class RunNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Hands a notification to macOS; replaced in tests.
    var deliver: (RunNotification) -> Void
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var showWorkspace: (UUID) -> Void = { _ in }
    /// The bell's list: every notification Runnir sends is recorded in it.
    var inbox: NotificationInbox?
    private let defaults: UserDefaults
    /// The category of run notifications: macOS tells the delegate when one
    /// is dismissed, which reads it in the bell too.
    static let categoryID = "dev.runnir.run"

    init(defaults: UserDefaults = .standard, deliver: ((RunNotification) -> Void)? = nil) {
        self.defaults = defaults
        self.deliver = deliver ?? { _ in }
        super.init()
        if deliver == nil { self.deliver = { [weak self] in self?.post($0) } }
    }

    /// The live notifier, the notification center's delegate.
    static func live(inbox: NotificationInbox? = nil) -> RunNotifier {
        let notifier = RunNotifier()
        notifier.inbox = inbox
        let center = UNUserNotificationCenter.current()
        center.delegate = notifier
        center.setNotificationCategories([
            UNNotificationCategory(identifier: categoryID, actions: [], intentIdentifiers: [], options: [.customDismissAction]),
        ])
        return notifier
    }

    func notify(_ notification: RunNotification?) {
        guard let notification, NotificationSettings.allows(notification, in: defaults) else { return }
        inbox?.record(notification)
        deliver(notification)
    }

    /// Reads in the bell what macOS no longer holds of what it showed.
    func reconcile() async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        inbox?.reconcile(stillDelivered: Set(delivered.map { $0.request.identifier }))
    }

    private func post(_ notification: RunNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = notification.succeeded ? nil : .default
        content.threadIdentifier = notification.kind == .pullRequestChecks ? "pull-request-checks" : "local-runs"
        content.categoryIdentifier = Self.categoryID
        var info: [String: String] = [:]
        if let url = notification.url { info["url"] = url.absoluteString }
        if let workspace = notification.workspaceID { info["workspace"] = workspace.uuidString }
        content.userInfo = info
        let request = UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        let id = notification.id
        Task { [weak self] in
            // macOS asks once; a refusal leaves notifications off, and the entry
            // stays in the bell, unread until it is opened there.
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            guard (try? await center.add(request)) != nil else { return }
            await MainActor.run { self?.inbox?.markDelivered(id) }
        }
    }

    // Shown while Runnir is in front too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let url = (info["url"] as? String).flatMap(URL.init(string:))
        let workspace = (info["workspace"] as? String).flatMap(UUID.init(uuidString:))
        let id = response.notification.request.identifier
        // Closed in the system without opening it: read, and nothing opens.
        let dismissed = response.actionIdentifier == UNNotificationDismissActionIdentifier
        completionHandler()
        Task { @MainActor in
            self.inbox?.markRead(id)
            guard !dismissed else { return }
            if let url { self.open(url) } else if let workspace { self.showWorkspace(workspace) }
        }
    }
}

/// Settings › Notifications.
struct NotificationSettingsSection: View {
    @AppStorage(NotificationSettings.pullRequestChecksKey) private var pullRequestChecks = true
    @AppStorage(NotificationSettings.localRunsKey) private var localRuns = true
    @AppStorage(NotificationSettings.failuresOnlyKey) private var failuresOnly = false
    @State private var deniedBySystem = false

    var body: some View {
        Section("Notifications") {
            Toggle(isOn: $pullRequestChecks) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pull request checks")
                    Text("When the checks of a pull request you opened finish.").font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
            }.handPointer()
            Toggle(isOn: $localRuns) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local runs")
                    Text("When a run with act on this Mac finishes or fails.").font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
            }.handPointer()
            Picker("Notify about", selection: $failuresOnly) {
                Text("Failures and successes").tag(false)
                Text("Failures only").tag(true)
            }
            .pickerStyle(.segmented).pointerStyle(.link)
            .disabled(!pullRequestChecks && !localRuns)
            if deniedBySystem {
                HStack(alignment: .top) {
                    Label("macOS has notifications from Runnir turned off.", systemImage: "bell.slash")
                        .font(.system(size: 11)).foregroundStyle(RunnirTheme.warning)
                    Spacer()
                    Button("Open System Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                }
            }
            Text("Notifications are sent by this Mac only — nothing goes through a server. macOS asks once whether Runnir may show them.")
                .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).fixedSize(horizontal: false, vertical: true)
        }
        .task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            deniedBySystem = settings.authorizationStatus == .denied
        }
    }
}
