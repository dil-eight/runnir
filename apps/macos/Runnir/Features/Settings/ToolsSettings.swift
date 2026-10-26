import SwiftUI

/// Settings > Tools (S12): what local runs use, as the Core finds it, and
/// the experimental switch to an installed act.
@MainActor
@Observable
final class ToolsSettingsModel {
    private(set) var readiness: CoreToolReadiness?
    private(set) var isChecking = false
    private(set) var unavailable = false
    @ObservationIgnored private let hub: CoreHub?

    init(hub: CoreHub?) { self.hub = hub }

    func check(refresh: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        guard let hub, let readiness = await hub.toolReadiness(refresh: refresh) else {
            unavailable = true
            return
        }
        unavailable = false
        self.readiness = readiness
    }
}

struct ToolsSettingsSection: View {
    @State var model: ToolsSettingsModel
    @AppStorage(LocalRunSettings.useInstalledActKey) private var useInstalledAct = false

    var body: some View {
        Section {
            if let readiness = model.readiness {
                rows(readiness)
            } else if model.unavailable {
                Text("Runnir Core is not running, so tools can't be checked.").foregroundStyle(RunnirTheme.secondaryForeground)
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking tools...") }
            }
            Toggle(isOn: $useInstalledAct) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Use installed act")
                        Text("Experimental").font(.system(size: 10, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 1)
                            .foregroundStyle(RunnirTheme.warning).background(RunnirTheme.warning.opacity(0.14), in: Capsule())
                    }
                    Text(installedActCaption).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
            }.handPointer()
        } header: {
            HStack {
                Text("Tools")
                Spacer()
                Button(model.isChecking ? "Checking..." : "Recheck") { Task { await model.check(refresh: true) } }
                    .buttonStyle(DesignButtonStyle(compact: true)).disabled(model.isChecking)
            }
        } footer: {
            Label("Runnir never installs tools by itself, starts an engine or switches your Docker context. Install with Homebrew opens Terminal with the command for you to run; Setup opens the vendor's official instructions.",
                  systemImage: "info.circle")
                .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
        }
        .task { await model.check(refresh: false) }
    }

    private var installedActCaption: String {
        let tested = model.readiness?.testedActVersion ?? ""
        let minimum = model.readiness?.minimumActVersion ?? ""
        return "Local runs use the act bundled with Runnir\(tested.isEmpty ? "" : " (\(tested))"), the version they were verified with. "
            + "When this is on and an act\(minimum.isEmpty ? "" : " \(minimum) or newer") is installed, runs use it instead."
    }

    @ViewBuilder private func rows(_ readiness: CoreToolReadiness) -> some View {
        ToolReadinessRow(title: "act (bundled)", state: readiness.bundledAct.state, detail: LocalRunText.tool(readiness.bundledAct)) { EmptyView() }
        ToolReadinessRow(title: "act (installed)", state: readiness.installedAct.state == .missing && !useInstalledAct ? .unknown : readiness.installedAct.state,
                         untested: readiness.installedAct.untested, detail: installedDetail(readiness.installedAct)) {
            if readiness.installedAct.state != .found {
                ActInstallButton().buttonStyle(DesignButtonStyle(compact: true))
            }
        }
        ToolReadinessRow(title: "Docker CLI", state: readiness.dockerCLI.state, detail: LocalRunText.tool(readiness.dockerCLI)) { EmptyView() }
        ToolReadinessRow(title: "Container engine", state: readiness.engine.state, detail: LocalRunText.engine(readiness.engine)) {
            EngineSetupButton(engine: readiness.engine) { Task { await model.check(refresh: true) } }
                .buttonStyle(DesignButtonStyle(compact: true))
        }
    }

    private func installedDetail(_ act: CoreToolStatus) -> String {
        var text = LocalRunText.tool(act)
        if act.state == .found, !act.path.isEmpty { text += " · " + LocalRunText.abbreviated(act.path) }
        if useInstalledAct, act.state != .found { text += " · runs use the bundled act" }
        return text
    }
}
