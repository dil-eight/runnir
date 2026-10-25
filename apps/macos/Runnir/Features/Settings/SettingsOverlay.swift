import SwiftUI

/// A part of Settings, listed in the overlay's sidebar.
enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case account, runs, notifications, pullRequests, tools, storage, privacy

    var id: Self { self }

    var title: String {
        switch self {
        case .account: "Account"
        case .runs: "Runs"
        case .notifications: "Notifications"
        case .pullRequests: "Pull Requests"
        case .tools: "Tools"
        case .storage: "Storage"
        case .privacy: "Privacy"
        }
    }

    var symbol: String {
        switch self {
        case .account: "person.crop.circle"
        case .runs: "play.circle"
        case .notifications: "bell"
        case .pullRequests: "arrow.triangle.pull"
        case .tools: "wrench.and.screwdriver"
        case .storage: "internaldrive"
        case .privacy: "hand.raised"
        }
    }
}

/// Settings shown over one window, and the section open in it.
struct SettingsPresentation: Equatable, Sendable {
    let windowID: UUID
    var section: SettingsSection
}

extension EnvironmentValues {
    /// Opens Settings over the window the view is in, at a section (nil:
    /// the one open last). Unset outside Runnir's windows.
    @Entry var openRunnirSettings: (@MainActor (SettingsSection?) -> Void)? = nil
}

/// Settings over a window (S12): the window behind is dimmed and blurred,
/// sections on the left, the chosen one on the right. Escape, the close
/// button or a click outside closes it.
struct SettingsOverlay: View {
    let desktop: DesktopCoordinator

    var body: some View {
        ZStack {
            // The window behind is blurred by `settingsOverlay`; this dims it.
            Color(red: 0.04, green: 0.05, blue: 0.06).opacity(0.32)
                .contentShape(Rectangle())
                .onTapGesture { desktop.closeSettings() }
                .accessibilityHidden(true)
            panel
                .frame(maxWidth: 900, maxHeight: 640)
                .padding(24)
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }

    private var section: SettingsSection { desktop.settings?.section ?? .account }

    private var panel: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSection.allCases) { item in sidebarRow(item) }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 14).padding(.horizontal, 12)
            .frame(width: 220)
            .frame(maxHeight: .infinity)
            .background(RunnirTheme.sidebar)
            DesignDivider(vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                Text(section.title)
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(RunnirTheme.surface)
        .foregroundStyle(RunnirTheme.foreground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RunnirTheme.border))
        .overlay(alignment: .topTrailing) {
            Button { desktop.closeSettings() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RunnirTheme.secondaryForeground)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(RunnirTheme.selected))
            }
            .buttonStyle(.hit)
            .keyboardShortcut(.cancelAction)
            .help("Close Settings")
            .accessibilityLabel("Close Settings")
            .padding(14)
        }
        .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
    }

    private func sidebarRow(_ item: SettingsSection) -> some View {
        let selected = item == section
        return Button { desktop.showSettingsSection(item) } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol).frame(width: 16)
                    .foregroundStyle(selected ? RunnirTheme.primary : RunnirTheme.secondaryForeground)
                Text(item.title).font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? RunnirTheme.foreground : RunnirTheme.secondaryForeground)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? RunnirTheme.selected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hit)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings-section-\(item.rawValue)")
    }

    @ViewBuilder private var content: some View {
        Form {
            switch section {
            case .account:
                Section("GitHub.com") {
                    if let github = desktop.github {
                        GitHubAccountSettings(session: github, credentialKind: desktop.core?.credentialKind)
                    } else {
                        Text("GitHub sign-in is not available.").foregroundStyle(RunnirTheme.secondaryForeground)
                    }
                }
                if let servers = desktop.enterpriseServers { EnterpriseServersSection(servers: servers, hub: desktop.core) }
            case .runs:
                ManualRunSettingsSection()
            case .notifications:
                NotificationSettingsSection()
            case .pullRequests:
                PullRequestShortcutSettingsSection(center: desktop.shortcuts)
            case .tools:
                ToolsSettingsSection(model: ToolsSettingsModel(hub: desktop.core))
            case .storage:
                StorageSettingsSection(model: StorageSettingsModel(hub: desktop.core, workspaces: { desktop.snapshot.workspaces }))
            case .privacy:
                Section("Telemetry") {
                    Text("Runnir does not enable telemetry by default and does not send repository data to a Runnir backend.")
                        .foregroundStyle(RunnirTheme.secondaryForeground)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 12)
        .id(section)
    }
}

extension View {
    /// Shows Settings over this window while they are open in it, and lets
    /// views inside open them here.
    func settingsOverlay(desktop: DesktopCoordinator, windowID: UUID) -> some View {
        let shown = desktop.settings?.windowID == windowID
        return blur(radius: shown ? 8 : 0)
            .accessibilityHidden(shown)
            .overlay {
                if shown { SettingsOverlay(desktop: desktop) }
            }
            .animation(.easeOut(duration: 0.15), value: shown)
        .environment(\.openRunnirSettings) { section in desktop.showSettings(in: windowID, section: section) }
    }
}
