import SwiftUI

/// A new version, at the bottom of the sidebar above the GitHub account
/// (S03, B50). Hidden while Runnir is up to date; appears with a short slide
/// up and fade, and Update turns into a bar that fills as the download comes.
struct UpdateCard: View {
    let center: UpdateCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if center.state != .idle {
                UpdateStatus(center: center)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(RunnirTheme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(RunnirTheme.border))
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("update-card")
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: center.state == .idle)
    }
}

/// What the update is doing, in the sidebar card and in Settings › About.
struct UpdateStatus: View {
    let center: UpdateCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch center.state {
            case .idle:
                EmptyView()
            case let .available(release):
                head("arrow.down.circle", RunnirTheme.primary, "Update available")
                HStack(spacing: 6) {
                    Text("Runnir \(release.version)").foregroundStyle(RunnirTheme.secondaryForeground)
                    link("What's New", release.page)
                }
                .font(.system(size: 11.5))
                Button { center.update() } label: { Text("Update").frame(maxWidth: .infinity) }
                    .buttonStyle(DesignButtonStyle(primary: true, compact: true))
                    .accessibilityIdentifier("update-now")
            case let .downloading(release, received, total):
                HStack {
                    head("arrow.down.circle", RunnirTheme.primary, "Downloading \(release.version)")
                    Spacer(minLength: 4)
                    if total > 0 {
                        Text(Self.percent(received, total)).font(.system(size: 11.5)).foregroundStyle(RunnirTheme.secondaryForeground)
                            .monospacedDigit()
                    }
                }
                UpdateProgressBar(fraction: total > 0 ? Double(received) / Double(total) : nil)
                HStack {
                    Text(total > 0 ? "\(Self.megabytes(received)) of \(Self.megabytes(total))" : Self.megabytes(received))
                        .monospacedDigit()
                    Spacer()
                    Button("Cancel") { center.cancel() }.buttonStyle(.link).pointerStyle(.link)
                }
                .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
            case let .installing(release):
                head("checkmark.shield", RunnirTheme.primary, "Installing \(release.version)…")
                UpdateProgressBar(fraction: nil)
                note("Runnir checks the signature, installs the new version and restarts.")
            case let .restartPending(release):
                head("arrow.clockwise.circle", RunnirTheme.success, "\(release.version) is installed")
                note("It opens when Runnir quits.")
                Button { center.update() } label: { Text("Restart Now").frame(maxWidth: .infinity) }
                    .buttonStyle(DesignButtonStyle(primary: true, compact: true))
            case let .failed(release, message):
                head("exclamationmark.triangle.fill", RunnirTheme.destructive, "Couldn't update")
                note(message)
                HStack(spacing: 10) {
                    Button("Try Again") { center.update() }.buttonStyle(DesignButtonStyle(compact: true))
                    link("Download", release.page)
                }
            case let .outsideApplications(release):
                head("folder.badge.questionmark", RunnirTheme.warning, "Move to Applications")
                note("Runnir \(release.version) is available. macOS runs this copy from a temporary folder, so Runnir can't replace it.")
                link("Download", release.page)
            }
        }
        .font(.system(size: 12))
    }

    private func head(_ symbol: String, _ color: Color, _ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color).font(.system(size: 13))
            Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func link(_ title: String, _ url: URL) -> some View {
        Link(title, destination: url).font(.system(size: 11.5)).pointerStyle(.link).help(url.absoluteString)
    }

    static func percent(_ received: Int64, _ total: Int64) -> String {
        "\(min(100, Int(Double(received) / Double(total) * 100)))%"
    }

    static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }
}

/// A thin bar: filling with the download, or a segment sweeping across while
/// the length is unknown and while installing.
struct UpdateProgressBar: View {
    /// nil: indeterminate.
    let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(RunnirTheme.border)
                if let fraction {
                    Capsule().fill(RunnirTheme.primary)
                        .frame(width: max(4, width * min(max(fraction, 0), 1)))
                        .animation(reduceMotion ? nil : .linear(duration: 0.2), value: fraction)
                } else if reduceMotion {
                    Capsule().fill(RunnirTheme.primary.opacity(0.6))
                } else {
                    TimelineView(.animation) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                        Capsule().fill(RunnirTheme.primary)
                            .frame(width: width * 0.35)
                            .offset(x: (width * 1.35) * phase - width * 0.35)
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel(fraction.map { "Downloaded \(Int($0 * 100)) percent" } ?? "In progress")
    }
}

/// Settings › About › Updates (S12, B50): the status with Check for Updates,
/// automatic checks, and beta versions from Runnir 1.0.0.
struct UpdateSettingsSection: View {
    @Bindable var center: UpdateCenter

    var body: some View {
        Section("Updates") {
            if center.state == .idle {
                HStack(spacing: 10) {
                    Image(systemName: center.checkError == nil ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(center.checkError == nil ? RunnirTheme.success : RunnirTheme.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(center.checkError == nil ? "Runnir is up to date" : "Couldn't check for updates")
                        Text(center.checkError ?? checkedLine)
                            .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                    }
                    Spacer()
                    if center.isChecking { ProgressView().controlSize(.small) }
                    Button("Check for Updates") { Task { await center.check(userInitiated: true) } }
                        .disabled(center.isChecking)
                        .accessibilityIdentifier("check-for-updates")
                }
            } else {
                UpdateStatus(center: center)
            }
            Toggle(isOn: $center.checksAutomatically) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check for updates automatically")
                    Text("At launch and once a day; Runnir asks GitHub for its releases without your token. Updates install only when you click Update.")
                        .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch).handPointer()
            if center.showsBetaSetting {
                Toggle(isOn: $center.getsBetas) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Get beta versions")
                        Text("Betas of the next version before its release. Turned off, Runnir waits for the next release.")
                            .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch).handPointer()
            }
        }
    }

    private var checkedLine: String {
        guard let date = center.lastChecked else { return "Not checked yet" }
        return "Checked \(date.formatted(.relative(presentation: .named)))"
    }
}
