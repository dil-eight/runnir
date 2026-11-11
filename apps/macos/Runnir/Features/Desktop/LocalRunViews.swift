import AppKit
import SwiftUI

// MARK: Beta

/// Local runs are in beta: act runs a workflow close to GitHub, not the same
/// way, and some jobs that pass on GitHub fail here (ADR 0006 lists the known
/// cases). The badge marks the local run surfaces.
struct BetaBadge: View {
    static let help = "Local runs are in beta: act runs a workflow close to GitHub but not the same way, so a job can fail here and pass on GitHub. Check a failure on GitHub before changing the workflow for it."

    var body: some View {
        Text("Beta")
            .font(.system(size: 10, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(RunnirTheme.info).background(RunnirTheme.info.opacity(0.14), in: Capsule())
            .help(Self.help)
            .accessibilityLabel("Beta")
    }
}

// MARK: Tools

/// Container engines Runnir can point people to. Runnir never installs or
/// starts one by itself; these open the vendor's app or instructions.
enum ContainerEngineApp {
    static func bundleID(for engine: String) -> String? {
        switch engine {
        case "OrbStack": "dev.kdrag0n.MacVirt"
        case "Docker Desktop": "com.docker.docker"
        case "Rancher Desktop": "io.rancherdesktop.app"
        default: nil
        }
    }

    /// The engine's app when it is installed.
    static func installedURL(for engine: String) -> URL? {
        guard let id = bundleID(for: engine) else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    static let instructions: [(name: String, url: URL)] = [
        ("OrbStack", URL(string: "https://orbstack.dev/download")!),
        ("Docker Desktop", URL(string: "https://docs.docker.com/desktop/setup/install/mac-install/")!),
        ("Colima", URL(string: "https://github.com/abiosoft/colima#installation")!),
    ]
}

/// Installing act stays the user's step: Runnir writes the Homebrew command
/// to a Terminal script that runs it only after Return, or opens act's
/// instructions when Homebrew is missing.
enum ActInstaller {
    static let instructions = URL(string: "https://nektosact.com/installation/index.html")!
    static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    static func brew(isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        brewPaths.first(where: isExecutable)
    }

    /// Shows the command, waits for Return, then runs it.
    static func script(brew: String) -> String {
        """
        #!/bin/zsh
        echo "Runnir prepared this command to install act with Homebrew:"
        echo
        echo "    \(brew) install act"
        echo
        read "?Press Return to run it, or close this window to cancel. "
        "\(brew)" install act && echo && echo "act is installed. In Runnir, press Recheck."
        """
    }

    /// Opens the script with the app for .command files (Terminal unless
    /// changed); false when it could not be written.
    @MainActor static func openTerminal(brew: String) -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Install act.command")
        do {
            try script(brew: brew).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch { return false }
        return NSWorkspace.shared.open(url)
    }
}

/// The installed act's action: install it with Homebrew in Terminal, or open
/// act's instructions without Homebrew.
struct ActInstallButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let brew = ActInstaller.brew() {
            Button("Install with Homebrew…") {
                if !ActInstaller.openTerminal(brew: brew) { openURL(ActInstaller.instructions) }
            }
            .help("Opens Terminal with brew install act; it runs when you press Return there. Then press Recheck.")
        } else {
            Button("Install…") { openURL(ActInstaller.instructions) }
                .help("Opens act's official installation instructions")
        }
    }
}

enum LocalRunText {
    static func tool(_ status: CoreToolStatus) -> String {
        switch status.state {
        case .found: status.untested ? "\(status.version) · found · not verified with Runnir" : "\(status.version) · found"
        case .missing: status.detail.isEmpty ? "Not found" : status.detail
        default: status.detail.isEmpty ? "Not usable" : status.detail
        }
    }

    static func engine(_ engine: CoreContainerEngine) -> String {
        switch engine.state {
        case .found:
            [engine.name, engine.context.isEmpty ? nil : "context \(engine.context)", engine.local ? "local" : "remote"]
                .compactMap { $0 }.joined(separator: " · ")
        case .stopped:
            ContainerEngineApp.installedURL(for: engine.name) != nil
                ? "\(engine.name) installed but stopped · context \(engine.context)"
                : engine.detail
        default:
            engine.detail.isEmpty ? "No Docker-compatible engine found" : engine.detail
        }
    }

    static func limits(_ plan: CoreLocalRunPlan) -> String {
        "\(plan.cpus) CPU\(plan.cpus == 1 ? "" : "s") · \(memory(plan.memoryBytes)) memory · \(duration(seconds: plan.timeoutSeconds)) timeout"
    }

    /// Memory as the engines word it: "5.85 GB".
    static func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    /// A timeout: "30 min", "1 h", "1 h 30 min".
    static func duration(seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    static func elapsed(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// "Running · 00:42" for the job list; the time runs to `now` until
    /// the job finishes.
    static func jobSubtitle(_ job: CoreLocalRunJobStatus, now: Date) -> String {
        let duration = job.startedAt.map { " · " + elapsed(from: $0, to: job.finishedAt ?? now) } ?? ""
        switch job.state {
        case .waiting: return "Queued"
        case .running: return "Running" + duration
        case .succeeded: return "Succeeded" + duration
        case .failed: return "Failed" + duration
        case .cancelled: return "Cancelled"
        case .skipped, .unsupported: return job.reason.isEmpty ? "Skipped" : job.reason
        case .notRun: return job.reason.isEmpty ? "Did not run" : job.reason
        case .unknown: return "Unknown"
        }
    }

    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

struct ToolStateIcon: View {
    let state: CoreToolState
    var untested = false
    var body: some View {
        icon.accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .found: untested ? "Found, not verified" : "Found"
        case .missing: "Missing"
        case .stopped: "Stopped"
        case .unsupported: "Not supported"
        case .failed: "Check failed"
        case .unknown: "Not in use"
        }
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .found:
            Image(systemName: untested ? "exclamationmark.circle" : "checkmark.circle")
                .foregroundStyle(untested ? RunnirTheme.warning : RunnirTheme.success)
        case .stopped, .unsupported:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(RunnirTheme.warning)
        case .unknown:
            Image(systemName: "minus.circle").foregroundStyle(RunnirTheme.mutedForeground)
        default:
            Image(systemName: "xmark.circle").foregroundStyle(RunnirTheme.destructive)
        }
    }
}

/// One tool with its state and the one action that helps.
struct ToolReadinessRow<Action: View>: View {
    let title: String
    let state: CoreToolState
    var untested = false
    let detail: String
    /// The larger row of the review sheet.
    var large = false
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(spacing: large ? 12 : 10) {
            ToolStateIcon(state: state, untested: untested).font(.system(size: large ? 18 : 12))
            Text(title).font(.system(size: large ? 15 : 13, weight: large ? .semibold : .medium))
                .frame(width: large ? 150 : nil, alignment: .leading)
            Text(detail).font(.system(size: large ? 13 : 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                .lineLimit(2).truncationMode(.middle).help(detail)
            Spacer(minLength: 8)
            action()
        }
        .padding(.horizontal, large ? 14 : 10).frame(minHeight: large ? 46 : 30)
    }
}

/// One check of the compatibility card: what it is about, what was found,
/// and the verdict at the right.
struct CompatibilityRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var verdict = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(tint).frame(width: 20)
            Text(title).font(.system(size: 14, weight: .semibold)).frame(width: 150, alignment: .leading).lineLimit(1)
            Text(detail).font(.system(size: 13)).foregroundStyle(RunnirTheme.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 8)
            if !verdict.isEmpty { Text(verdict).font(.system(size: 12, weight: .medium)).foregroundStyle(tint) }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}

/// The action for a container engine that is not usable: open the app when
/// it is installed, otherwise the vendors' install instructions.
struct EngineSetupButton: View {
    let engine: CoreContainerEngine
    let recheck: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        if engine.state == .found {
            Button("Recheck", action: recheck)
        } else if engine.state == .stopped, let app = ContainerEngineApp.installedURL(for: engine.name) {
            Button("Open \(engine.name)") {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            }.help("Start \(engine.name), then press Recheck")
        } else if engine.state == .missing {
            DropdownMenu {
                ForEach(ContainerEngineApp.instructions, id: \.name) { item in
                    DropdownItem(item.name) { openURL(item.url) }
                }
            } label: { _ in
                Text("Install...")
            }
            .buttonStyle(DesignButtonStyle()).fixedSize().help("Opens the vendor's official instructions")
        } else {
            Button("Recheck", action: recheck)
        }
    }
}

// MARK: S10 Local execution review

/// A workflow file the editor holds changes of that are not saved.
struct UnsavedWorkflow: Equatable {
    let path: String
    let name: String
}

struct LocalRunSheet: View {
    @Bindable var model: LocalRunReviewModel
    let repositoryPath: String
    /// The file the editor holds unsaved changes of, if any.
    var unsavedFile: UnsavedWorkflow?
    /// Opens Secrets and Variables for this workspace.
    var manageValues: () -> Void = {}
    let onStarted: (LocalRunModel) -> Void
    @Environment(\.dismiss) private var dismiss
    /// The limits panel is open over the review.
    @State private var showingLimits = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 24).padding(.vertical, 18)
            DesignDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(RunnirTheme.warning)
                    }
                    if let unsavedFile, model.lanes.contains(where: { $0.workflowID == unsavedFile.path && !model.ticks($0).isEmpty }) {
                        Label("\(unsavedFile.name) has unsaved changes. act runs the file as it is saved on disk.", systemImage: "pencil")
                            .font(.system(size: 12)).foregroundStyle(RunnirTheme.warning)
                    }
                    workflows
                    hostWarning
                    tools
                    compatibility
                    values
                    access
                    sandboxWarning
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 300, maxHeight: 560)
            DesignDivider()
            footer.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 680)
        .background(RunnirTheme.background)
        .foregroundStyle(RunnirTheme.foreground)
        .overlayPreferenceValue(LimitsAnchorKey.self) { anchor in
            GeometryReader { proxy in
                if showingLimits, let anchor, let plan = model.prepared?.plan {
                    limitsLayer(plan: plan, link: proxy[anchor], size: proxy.size)
                }
            }
        }
        .dropdownHost()
        .task { await model.prepare() }
        .countsUsage(.overlayLocalRunReview)
    }

    /// The limits panel over the review, next to Change…: above it when there
    /// is room, under it otherwise. A click outside or Escape closes it
    /// without changing anything.
    private func limitsLayer(plan: CoreLocalRunPlan, link: CGRect, size: CGSize) -> some View {
        let width: CGFloat = 420
        let x = min(max(link.minX - 140, 16), size.width - width - 16)
        let above = link.minY > 360
        return ZStack(alignment: .topLeading) {
            // No hand pointer: a click outside the panel closes it.
            Color.clear.contentShape(Rectangle()).onTapGesture { showingLimits = false }.accessibilityHidden(true)
            LocalRunLimitsPanel(plan: plan, apply: { limits in
                showingLimits = false
                Task { await model.change(limits: limits) }
            }, reset: {
                showingLimits = false
                Task { await model.resetLimits() }
            }, close: { showingLimits = false })
            .frame(width: width)
            .frame(width: size.width, height: above ? link.minY - 8 : max(0, size.height - link.maxY - 8),
                   alignment: above ? .bottomLeading : .topLeading)
            .padding(.leading, x)
            .offset(y: above ? 0 : link.maxY + 8)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Run locally").font(.system(size: 17, weight: .semibold))
                BetaBadge()
            }
            HStack(spacing: 10) {
                if let scenarios = model.prepared?.plan.scenarios, !scenarios.isEmpty {
                    DropdownPicker("Scenario", selection: Binding(
                        get: { model.scenario ?? scenarios[0] },
                        set: { scenario in Task { await model.choose(scenario: scenario) } }
                    ), options: scenarios.map { .init(value: $0, title: $0.title) })
                    .help("What happens to the branch's change: the workflows GitHub would start for it are ticked")
                }
                let summary = model.tickedSummary
                if model.prepared != nil {
                    Text("\(summary.workflows) \(summary.workflows == 1 ? "workflow" : "workflows") · \(summary.jobs) \(summary.jobs == 1 ? "job" : "jobs") ticked")
                        .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
                if model.isPreparing { ProgressView().controlSize(.small) }
            }
        }
    }

    /// The scenario's workflows, then those it does not start, each with
    /// its jobs and a checkbox for every one that can run here.
    @ViewBuilder private var workflows: some View {
        let lanes = model.lanes
        if !lanes.isEmpty {
            let inScenario = lanes.filter { $0.kind != .outside }
            let outside = lanes.filter { $0.kind == .outside }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: "WORKFLOWS AND JOBS", large: true)
                Text("Ticked workflows run one after another, each with act. A job brings the jobs it needs.")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                laneCard(inScenario)
                if !outside.isEmpty {
                    SectionLabel(title: "NOT IN THIS SCENARIO").padding(.top, 6)
                    laneCard(outside)
                }
            }
        }
    }

    /// macOS jobs run on this Mac in the macOS sandbox, not in a container:
    /// said in full, and confirmed apart from trusting the workflow. Without
    /// the sandbox, asked for this run only, the warning says what is at stake.
    @ViewBuilder private var hostWarning: some View {
        if !model.hostJobs.isEmpty {
            let unsandboxed = model.runsUnsandboxed
            let jobs = ListFormatter.localizedString(byJoining: model.hostJobs)
            let verb = model.hostJobs.count == 1 ? "runs" : "run"
            let tint = unsandboxed ? RunnirTheme.destructive : RunnirTheme.warning
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: unsandboxed ? "exclamationmark.octagon.fill" : "laptopcomputer.trianglebadge.exclamationmark")
                        .foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(unsandboxed ? "\(jobs) \(verb) on this Mac without any isolation" : "\(jobs) \(verb) on this Mac, not in a container")
                            .font(.system(size: 13, weight: .semibold))
                        Text(unsandboxed ? Self.unsandboxedWarning : Self.sandboxedWarning)
                            .font(.system(size: 12)).foregroundStyle(unsandboxed ? RunnirTheme.foreground : RunnirTheme.secondaryForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle(isOn: Binding(get: { model.hostUnsandboxed }, set: { on in Task { await model.setUnsandboxed(on) } })) {
                    Text("Run them without the sandbox, for this run only (xcodebuild test needs it)")
                }
                .toggleStyle(.checkbox).pointerStyle(.link).font(.system(size: 12)).padding(.leading, 26)
                .disabled(model.isPreparing)
                Toggle(unsandboxed ? "I understand: run these jobs on this Mac without the sandbox" : "Run these jobs on this Mac without a container",
                       isOn: $model.hostConfirmed)
                    .toggleStyle(.checkbox).pointerStyle(.link).font(.system(size: 12, weight: unsandboxed ? .semibold : .regular))
                    .padding(.leading, 26)
            }
            .padding(14).background(tint.opacity(unsandboxed ? 0.16 : 0.12), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(unsandboxed ? tint.opacity(0.6) : .clear))
        }
    }

    static let sandboxedWarning = "macOS jobs cannot run in a container, so act runs them on this Mac in the macOS sandbox. "
        + "They cannot read your home folder outside this repository, write outside the run's folder or use your Keychain. "
        + "They do use this Mac's macOS, Xcode and tools and the network, CPU and memory limits do not apply, "
        + "and processes they leave running keep running. Steps that need root, another Xcode or your signing certificates fail, "
        + "and so does xcodebuild test: Xcode's tests cannot reach Xcode from inside the sandbox. swift test works."

    static let unsandboxedWarning = "Nothing stands between these jobs and your Mac. Their steps, and every action and script they pull in, run as you: "
        + "they can read, change and delete any file you can, including your SSH keys, cloud credentials, browser data and other repositories, "
        + "use your Keychain (macOS may ask you first), install software, keep processes running after the run, and send any of it over the network. "
        + "A careless or malicious workflow or action can do lasting damage. Only use this for workflows you wrote or reviewed, from this repository. "
        + "Root stays out of reach: sudo still does not run."

    private func laneCard(_ lanes: [CoreLocalRunLane]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                if index > 0 { DesignDivider() }
                LocalRunLaneRow(lane: lane, ticks: model.ticks(lane), afterTitle: model.lanes.first { $0.workflowID == lane.after }?.title,
                                toggleLane: { Task { await model.toggle(lane: lane) } },
                                toggleJob: { job in Task { await model.toggle(job: job, in: lane) } })
            }
        }
        .background(RunnirTheme.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RunnirTheme.border))
    }

    private func recheck() { Task { await model.prepare() } }

    @ViewBuilder private var tools: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "ENGINE AND TOOLS", large: true)
            if let readiness = model.prepared?.readiness {
                let act = readiness.act(useInstalled: model.prepared?.plan.installedAct ?? false)
                VStack(spacing: 0) {
                    ToolReadinessRow(title: "Docker CLI", state: readiness.dockerCLI.state, detail: LocalRunText.tool(readiness.dockerCLI), large: true) {
                        Button("Recheck", action: recheck)
                    }
                    DesignDivider()
                    ToolReadinessRow(title: "Container engine", state: readiness.engine.state, detail: LocalRunText.engine(readiness.engine), large: true) {
                        EngineSetupButton(engine: readiness.engine, recheck: recheck)
                    }
                    DesignDivider()
                    ToolReadinessRow(title: "act", state: act.status.state, untested: act.status.untested,
                                     detail: LocalRunText.tool(act.status) + (act.installed ? " · installed (experimental)" : " · bundled"), large: true) {
                        Button("Recheck", action: recheck)
                    }
                }
                .buttonStyle(DesignButtonStyle())
                .background(RunnirTheme.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(RunnirTheme.border))
            } else if model.isPreparing {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking tools...").font(.system(size: 12)) }
            }
        }
    }

    @ViewBuilder private var compatibility: some View {
        if let plan = model.prepared?.plan {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: "COMPATIBILITY", large: true)
                let rows = compatibilityRows(plan)
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { DesignDivider() }
                        row
                    }
                }
                .background(RunnirTheme.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(RunnirTheme.border))
            }
        }
    }

    /// What the card lists: what stops the run, the ticked jobs act may not
    /// start as expected, the images that have to be downloaded, and the
    /// plan's notes. Each job's runner is in the workflows above.
    private func compatibilityRows(_ plan: CoreLocalRunPlan) -> [CompatibilityRow] {
        var rows: [CompatibilityRow] = []
        for blocker in plan.blockers {
            rows.append(CompatibilityRow(symbol: "xmark.octagon", tint: RunnirTheme.destructive, title: "Cannot start", detail: blocker))
        }
        if let engine = model.prepared?.readiness.engine, engine.state != .found || !engine.local {
            rows.append(CompatibilityRow(symbol: "info.circle", tint: RunnirTheme.secondaryForeground, title: "Static validation",
                                         detail: "Still works without an engine.", verdict: "No engine needed"))
        }
        for lane in plan.selectedLanes {
            for job in lane.jobs where job.selected && job.support == .unknown {
                rows.append(CompatibilityRow(symbol: "questionmark.circle", tint: RunnirTheme.warning, title: job.id,
                                             detail: job.reason, verdict: "Unclear"))
            }
        }
        for image in plan.images where !image.present {
            rows.append(CompatibilityRow(symbol: "arrow.down.circle", tint: RunnirTheme.warning, title: "Image",
                                         detail: image.reference, verdict: "Download needed"))
        }
        for note in plan.notes {
            rows.append(CompatibilityRow(symbol: "info.circle", tint: RunnirTheme.secondaryForeground, title: "Note", detail: note))
        }
        return rows
    }

    @ViewBuilder private var access: some View {
        if let plan = model.prepared?.plan {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: "WHAT THIS RUN CAN ACCESS", large: true)
                accessRow("folder", "Workspace", "Copy of \(LocalRunText.abbreviated(repositoryPath)) made by actions/checkout, with uncommitted changes and without .gitignore'd files; not mounted live")
                accessRow("globe", "Network", "On (bridge network): downloads images and actions; workflow steps may send data")
                accessRow(model.runKeys.isEmpty ? "key.slash" : "key", "Secrets", model.accessSummary)
                limitsRow(plan)
                if !model.hostJobs.isEmpty {
                    accessRow("laptopcomputer", "This Mac", model.runsUnsandboxed
                              ? "macOS jobs run here without the sandbox: everything your user can reach, the network and your Keychain"
                              : "macOS jobs run here in the macOS sandbox: a copy of the repository, the run's folder and the network; not your home folder or Keychain")
                }
                accessRow("nosign", "Never mounted", "Docker socket · home directory")
            }
        }
    }

    /// The secrets and variables the run reads: saved values stay hidden,
    /// a typed value is used for this run.
    @ViewBuilder private var values: some View {
        if !model.runKeys.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SectionLabel(title: "SECRETS AND VARIABLES", large: true)
                    Spacer()
                    if model.choosesEnvironment {
                        Text("Run with").font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                        valuesMenu
                    } else if let environment = model.environment {
                        Text("\(environment)'s values first, then the Repository's").font(.system(size: 11))
                            .foregroundStyle(RunnirTheme.secondaryForeground)
                    }
                }
                if model.choosesEnvironment, let choice = model.prepared?.plan.environmentChoice {
                    Text("\(choice) Choose whose values this run gets: an environment's first, then the Repository's.")
                        .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    ForEach(model.runKeys, id: \.self) { key in
                        valueRow(key)
                        if key != model.runKeys.last { Divider() }
                    }
                }
                .background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(RunnirTheme.border))
                HStack {
                    Toggle(model.saveEnteredTitle, isOn: $model.saveEntered)
                        .toggleStyle(.checkbox).pointerStyle(.link).font(.system(size: 12))
                    Spacer()
                    Button("Manage in Secrets and Variables") {
                        manageValues()
                        dismiss()
                    }.handPointer().buttonStyle(.link).font(.system(size: 12))
                }
            }
        }
    }

    /// Whose values a run takes when the plan leaves it to the user: the
    /// Repository's or an environment's, each with how many names it leaves
    /// empty.
    private var valuesMenu: some View {
        let options: [String?] = [nil] + (model.prepared?.plan.environments ?? [])
        return DropdownMenu(alignment: .trailing) {
            ForEach(options, id: \.self) { option in
                // Counted once the saved names are read.
                let empty = model.isPreparing ? 0 : model.emptyCount(with: option)
                DropdownItem(option ?? "Repository", detail: empty > 0 ? "\(empty) empty" : nil, checked: option == model.environment) {
                    Task { await model.choose(option) }
                }
            }
            DropdownNote("Environments named in workflows or set up on GitHub. Runnir asks again on every run.")
        } label: { open in
            HStack(spacing: 6) {
                Text(model.environment.map { "\($0)'s values" } ?? "the Repository's values").lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(RunnirTheme.secondaryForeground)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).frame(height: 26)
            .background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(open ? RunnirTheme.primary : RunnirTheme.border))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.hit).fixedSize()
        .accessibilityLabel("Whose values this run takes")
    }

    private func valueRow(_ key: LocalRunValueKey) -> some View {
        let missing = model.missing.contains(key)
        let entered = !(model.entered[key] ?? "").isEmpty
        let caption = model.refused.contains(key) ? "Keychain refused access · empty in this run"
            : entered ? "Entered for this run" : missing ? "Missing · empty in this run"
            : model.environment.map { model.fromEnvironment.contains(key) ? "Saved for \($0)" : "Saved for the Repository" }
            ?? (key.kind == .secret ? "Saved secret" : "Saved variable")
        let binding = Binding(get: { model.entered[key] ?? "" }, set: { model.entered[key] = $0 })
        let placeholder = model.saved.contains(key) && !model.refused.contains(key)
            ? (key.kind == .secret ? "••••••••••••" : "Saved value") : "Value for this run"
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(key.name).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                Text(caption).font(.system(size: 11))
                    .foregroundStyle(missing ? RunnirTheme.warning : entered ? RunnirTheme.primary : RunnirTheme.secondaryForeground)
            }
            .frame(width: 220, alignment: .leading)
            ValueField(placeholder: placeholder, text: binding, secure: key.kind == .secret,
                       border: missing ? RunnirTheme.warning : entered ? RunnirTheme.primary : nil)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var sandboxWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(RunnirTheme.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text("A container is not a security sandbox").font(.system(size: 13, weight: .semibold))
                Text("Only run workflows you trust. Runnir limits mounts and credentials, but cannot guarantee isolation for arbitrary code.")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14).background(RunnirTheme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("I trust this workflow and repository", isOn: $model.trusted).toggleStyle(.checkbox).pointerStyle(.link).font(.system(size: 13))
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button {
                Task {
                    if let run = await model.run() {
                        onStarted(run)
                        dismiss()
                    }
                }
            } label: {
                if model.isStarting { ProgressView().controlSize(.small) } else { Label("Run Locally", systemImage: "play.fill") }
            }
            .buttonStyle(DesignButtonStyle(primary: true)).keyboardShortcut(.defaultAction).disabled(!model.canRun)
            .help(model.prepared?.confirmationID == nil ? "Resolve the problems above first"
                  : !model.trusted ? "Confirm that you trust this workflow"
                  : !model.hostJobs.isEmpty && !model.hostConfirmed
                    ? (model.runsUnsandboxed ? "Confirm that the macOS jobs run on this Mac without the sandbox" : "Confirm that the macOS jobs run on this Mac without a container")
                  : "Start act with this plan")
        }.buttonStyle(DesignButtonStyle())
    }

    /// The run's limits with Change…, and under them what is worth knowing:
    /// a note about the engine and what the limits risk.
    private func limitsRow(_ plan: CoreLocalRunPlan) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(RunnirTheme.secondaryForeground).frame(width: 18)
                Text("Limits").foregroundStyle(RunnirTheme.secondaryForeground).frame(width: 130, alignment: .leading)
                Text(LocalRunText.limits(plan))
                if plan.ownLimits {
                    Text("set for this workspace").font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(RunnirTheme.border))
                }
                Button("Change\u{2026}") { showingLimits.toggle() }
                    .buttonStyle(.link).pointerStyle(.link)
                    .disabled(plan.maxCPUs == 0 && plan.maxMemoryBytes == 0 || model.isPreparing)
                    .help(plan.maxCPUs == 0 && plan.maxMemoryBytes == 0 ? "The engine has not said what it has" : "CPUs, memory and timeout for this workspace's local runs")
                    .anchorPreference(key: LimitsAnchorKey.self, value: .bounds) { $0 }
            }.font(.system(size: 14))
            if !plan.limitNote.isEmpty {
                Label(plan.limitNote, systemImage: "info.circle")
                    .font(.system(size: 12.5)).foregroundStyle(RunnirTheme.secondaryForeground)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 28)
            }
            ForEach(plan.limitWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12.5)).foregroundStyle(RunnirTheme.warning)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, 28)
            }
        }
    }

    private func accessRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(RunnirTheme.secondaryForeground).frame(width: 18)
            Text(title).foregroundStyle(RunnirTheme.secondaryForeground).frame(width: 130, alignment: .leading)
            Text(detail).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 14))
    }
}

// MARK: S11 Local run output

struct LocalRunView: View {
    @Bindable var run: LocalRunModel
    @State private var follow = true
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            summary
            DesignDivider()
            banners
            HStack(spacing: 0) {
                jobList.frame(width: 280)
                DesignDivider(vertical: true)
                output
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 22) {
            HStack(spacing: 6) {
                Text(run.plan.scenario.map { "Local · \($0.title)" } ?? "Local · not a GitHub run")
                    .help("Runs on this Mac with act, not on GitHub")
                BetaBadge()
            }
            Text("\(run.plan.engineName.isEmpty ? "Container engine" : run.plan.engineName) · act \(run.plan.actVersion)\(run.plan.installedAct ? " (installed)" : "")")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(RunnirTheme.secondaryForeground)
            Text("No GitHub token injected")
            if let client = run.startedBy {
                Label("Started by \(McpClientName.display(client))", systemImage: "terminal")
                    .help("An agent started this run through Runnir's MCP server")
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(timing(now: context.date)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
        }
        .font(.system(size: 12)).padding(.horizontal, 20).frame(height: 36)
    }

    private func timing(now: Date) -> String {
        guard let started = run.startedAt else { return run.isFinished ? "" : "Waiting to start" }
        if let finished = run.finishedAt {
            return "Finished · took \(LocalRunText.elapsed(from: started, to: finished))"
        }
        return "Started \(LocalRunText.elapsed(from: started, to: now)) ago"
    }

    @ViewBuilder private var banners: some View {
        if let lost = run.lostMessage {
            banner(lost, symbol: "questionmark.circle", tint: RunnirTheme.warning)
        }
        if let problem = run.readProblem {
            banner(problem, symbol: "exclamationmark.triangle", tint: RunnirTheme.warning)
        }
        if let problem = run.cleanupProblem {
            banner(problem, symbol: "trash.slash", tint: RunnirTheme.destructive)
        }
        if let stopError = run.stopError {
            banner(stopError, symbol: "exclamationmark.triangle", tint: RunnirTheme.warning)
        }
    }

    private func banner(_ text: String, symbol: String, tint: Color) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(text).font(.system(size: 12)).textSelection(.enabled)
                Spacer(minLength: 0)
            }.padding(.horizontal, 20).padding(.vertical, 8).background(tint.opacity(0.1))
            DesignDivider()
        }
    }

    private var jobList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(run.lanes, id: \.lane.id) { group in
                    laneHeader(group.lane, jobs: group.jobs)
                    ForEach(group.jobs) { job in jobButton(job) }
                }
                Button { run.selectedJobID = nil } label: {
                    Label("All output", systemImage: "text.alignleft").font(.system(size: 12))
                        .padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        .background(run.selectedJobID == nil ? RunnirTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.hit).foregroundStyle(RunnirTheme.secondaryForeground)
            }.padding(8)
        }
    }

    /// A workflow of the run: its name and file, above its jobs.
    private func laneHeader(_ lane: CoreLocalRunLane, jobs: [CoreLocalRunJobStatus]) -> some View {
        HStack(spacing: 6) {
            Text(lane.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(RunnirTheme.secondaryForeground)
            Text(lane.event).font(.system(size: 10, design: .monospaced)).foregroundStyle(RunnirTheme.mutedForeground)
            Spacer(minLength: 0)
        }
        .textCase(.uppercase)
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
        .accessibilityAddTraits(.isHeader)
    }

    private func jobButton(_ job: CoreLocalRunJobStatus) -> some View {
                    Button { run.selectedJobID = job.id } label: {
                        HStack(alignment: .top, spacing: 10) {
                            LocalJobIcon(state: job.state).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.name.isEmpty ? job.jobID : job.name).font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(job.state == .unsupported ? RunnirTheme.secondaryForeground : RunnirTheme.foreground)
                                // A running job's time keeps counting between reports.
                                TimelineView(.periodic(from: .now, by: job.state == .running ? 1 : 3600)) { context in
                                    Text(LocalRunText.jobSubtitle(job, now: context.date))
                                }.font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
                        .background(run.selectedJobID == job.id ? RunnirTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.hit)
    }

    private var output: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("\(run.selectedJobID.flatMap(run.job).map { $0.name.isEmpty ? $0.jobID : $0.name } ?? "All") · output")
                    .font(.system(size: 13, weight: .semibold))
                statusChip
                Spacer()
                Button { copyOutput() } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(DesignButtonStyle(compact: true)).disabled(run.visibleLines.isEmpty)
                .help("Copy all of this output")
                Toggle("Follow output", isOn: $follow).toggleStyle(.checkbox).pointerStyle(.link).font(.system(size: 12))
            }.padding(.horizontal, 16).frame(height: 40)
            DesignDivider()
            if run.discarded {
                Label("Output is bounded: showing the last \(LocalRunModel.maxLines.formatted()) lines. Earlier output was discarded.", systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                    .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 26, alignment: .leading).background(RunnirTheme.surface)
            }
            lines
            DesignDivider()
            Label(run.isFinished ? "The run's containers and temporary files were removed when it ended."
                  : "Stopping removes the run's containers and temporary files. Quitting Runnir or closing this workspace asks what to do with this run.", systemImage: "info.circle")
                .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lines: some View {
        let visible = run.visibleLines
        return ZStack(alignment: .topLeading) {
            LocalRunOutputText(lines: visible, follow: follow)
            if visible.isEmpty {
                Text(run.isFinished ? "No output for this job." : "Waiting for output...")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).padding(16)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Puts the output shown on the pasteboard, whatever is selected.
    private func copyOutput() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(run.visibleText, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    @ViewBuilder private var statusChip: some View {
        let (text, tint) = status
        Text(text).font(.system(size: 11, weight: .medium)).padding(.horizontal, 8).frame(height: 20)
            .foregroundStyle(tint).background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
    }

    private var status: (String, Color) {
        if run.lostMessage != nil { return ("Unknown", RunnirTheme.warning) }
        switch run.phase {
        case .queued: return ("Queued", RunnirTheme.secondaryForeground)
        case .running: return (run.stopRequested ? "Stopping" : "Running", RunnirTheme.info)
        case .stopping: return ("Stopping", RunnirTheme.warning)
        case .cleaningUp: return ("Cleaning up", RunnirTheme.secondaryForeground)
        case .unknown: return ("Connecting", RunnirTheme.secondaryForeground)
        case .finished:
            switch run.state {
            case .succeeded: return ("Succeeded", RunnirTheme.success)
            case .cancelled: return ("Cancelled", RunnirTheme.secondaryForeground)
            default:
                if run.plan.selectedLanes.count > 1, let failure = run.failure { return ("Failed · \(failure)", RunnirTheme.destructive) }
                return (run.exitCode.map { "Failed · exit code \($0)" } ?? "Failed", RunnirTheme.destructive)
            }
        }
    }
}

/// A local run's output as one read-only text, so a selection runs across
/// lines, Command-A selects all of it, Command-C copies the selection and
/// Command-F finds in it. New lines are added at the end and the first ones
/// dropped when the output is bounded, so a selection survives both.
struct LocalRunOutputText: NSViewRepresentable {
    let lines: [CoreLocalRunLine]
    let follow: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = RunnirColorToken.editor.nsColor
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.importsGraphics = false
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
            textView.isAutomaticLinkDetectionEnabled = false
            textView.isAutomaticDataDetectionEnabled = false
            textView.drawsBackground = true
            textView.backgroundColor = RunnirColorToken.editor.nsColor
            textView.textContainerInset = NSSize(width: 10, height: 8)
            textView.setAccessibilityLabel("Output")
            context.coordinator.textView = textView
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.show(lines, follow: follow)
    }

    @MainActor
    final class Coordinator {
        static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        weak var textView: NSTextView?
        /// The lines shown, by sequence, and each one's length in the text.
        private var shown: [UInt64] = []
        private var lengths: [Int] = []
        private var followed = false

        func show(_ lines: [CoreLocalRunLine], follow: Bool) {
            guard let textView, let storage = textView.textStorage else { return }
            let ids = lines.map(\.sequence)
            let changed = ids != shown
            if changed {
                storage.beginEditing()
                if let first = ids.first, let start = shown.firstIndex(of: first),
                   ids.count >= shown.count - start, ids[shown.count - start - 1] == shown.last {
                    // The same lines, maybe fewer at the top and more below.
                    if start > 0 {
                        storage.deleteCharacters(in: NSRange(location: 0, length: lengths[..<start].reduce(0, +)))
                        shown.removeFirst(start)
                        lengths.removeFirst(start)
                    }
                    append(lines[shown.count...], to: storage)
                } else {
                    storage.setAttributedString(NSAttributedString())
                    shown = []
                    lengths = []
                    append(lines[...], to: storage)
                }
                storage.endEditing()
            }
            if follow, changed || !followed { textView.scrollToEndOfDocument(nil) }
            followed = follow
        }

        private func append(_ lines: ArraySlice<CoreLocalRunLine>, to storage: NSTextStorage) {
            guard !lines.isEmpty else { return }
            let text = NSMutableAttributedString()
            for line in lines {
                let piece = line.text + "\n"
                let color = (line.isError ? RunnirColorToken.destructive : RunnirColorToken.foreground).nsColor
                text.append(NSAttributedString(string: piece, attributes: [.font: Self.font, .foregroundColor: color]))
                shown.append(line.sequence)
                lengths.append((piece as NSString).length)
            }
            storage.append(text)
        }
    }
}

struct LocalJobIcon: View {
    let state: CoreLocalJobState
    var body: some View {
        icon.accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .waiting: "Queued"
        case .running: "Running"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .skipped: "Skipped"
        case .unsupported: "Not supported locally"
        case .notRun: "Did not run"
        case .unknown: "Unknown"
        }
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .waiting: Image(systemName: "clock").foregroundStyle(RunnirTheme.secondaryForeground)
        case .running: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(RunnirTheme.info).spinning(true)
        case .succeeded: Image(systemName: "checkmark.circle").foregroundStyle(RunnirTheme.success)
        case .failed: Image(systemName: "xmark.circle").foregroundStyle(RunnirTheme.destructive)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(RunnirTheme.secondaryForeground)
        case .skipped, .unsupported: Image(systemName: "nosign").foregroundStyle(RunnirTheme.warning)
        case .notRun, .unknown: Image(systemName: "minus.circle").foregroundStyle(RunnirTheme.mutedForeground)
        }
    }
}

/// Where Change… is, so the limits panel opens next to it.
private struct LimitsAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// The limits of a local run for the workspace (B45): a stepper each for the
/// CPUs, the memory and the timeout, up to what the engine has; what the
/// limits the run has now risk; Reset to defaults and Done. Done plans the
/// run again with the new limits, which then has to be confirmed again.
struct LocalRunLimitsPanel: View {
    let plan: CoreLocalRunPlan
    let apply: (CoreLocalRunLimits) -> Void
    let reset: () -> Void
    let close: () -> Void
    @State private var draft: CoreLocalRunLimits?
    @State private var escape: Any?

    private var limits: CoreLocalRunLimits { draft ?? plan.limits }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Limits for this workspace").font(.system(size: 14, weight: .semibold))
                Text("Kept for the workspace and used by its next local runs.").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
            row("CPUs", value: "\(limits.cpus)", ceiling: plan.maxCPUs > 0 ? "of \(plan.maxCPUs)\(plan.engineName.isEmpty ? "" : " on \(plan.engineName)")" : "",
                atCeiling: plan.maxCPUs > 0 && limits.cpus >= plan.maxCPUs,
                canLess: limits.cpus > 1, canMore: plan.maxCPUs == 0 || limits.cpus < plan.maxCPUs) { delta in
                update { $0.cpus = LimitSteps.cpus($0.cpus, by: delta, max: plan.maxCPUs) }
            }
            row("Memory", value: LocalRunText.memory(limits.memoryBytes),
                ceiling: plan.maxMemoryBytes > 0 ? "of \(LocalRunText.memory(plan.maxMemoryBytes))" : "",
                atCeiling: plan.maxMemoryBytes > 0 && limits.memoryBytes * 10 >= plan.maxMemoryBytes * 9,
                canLess: limits.memoryBytes > LimitSteps.minMemory,
                canMore: plan.maxMemoryBytes == 0 || limits.memoryBytes < plan.maxMemoryBytes) { delta in
                update { $0.memoryBytes = LimitSteps.memory($0.memoryBytes, by: delta, max: plan.maxMemoryBytes) }
            }
            row("Timeout", value: LocalRunText.duration(seconds: limits.timeoutSeconds), ceiling: "up to 6 h", atCeiling: false,
                canLess: limits.timeoutSeconds > LimitSteps.minTimeout, canMore: limits.timeoutSeconds < LimitSteps.maxTimeout) { delta in
                update { $0.timeoutSeconds = LimitSteps.timeout($0.timeoutSeconds, by: delta) }
            }
            // What the limits the run has now risk, as the Core says it.
            ForEach(plan.limitWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RunnirTheme.warning.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            }
            DesignDivider()
            Text("Changing a limit prepares the run again: confirm it again before it starts.")
                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).fixedSize(horizontal: false, vertical: true)
            HStack {
                let canReset = plan.ownLimits || draft != nil
                Button(action: reset) {
                    Text("Reset to defaults").font(.system(size: 12.5))
                        .foregroundStyle(canReset ? RunnirTheme.primary : RunnirTheme.mutedForeground)
                }
                .buttonStyle(.hit).disabled(!canReset)
                Spacer()
                Button("Done") { if let draft, draft != plan.limits { apply(draft) } else { close() } }
                    .buttonStyle(DesignButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .background(RunnirTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RunnirTheme.border))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .onAppear(perform: watchEscape)
        .onDisappear(perform: stopWatching)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Limits")
        .countsUsage(.overlayLocalRunLimits)
    }

    private func update(_ change: (inout CoreLocalRunLimits) -> Void) {
        var next = limits
        change(&next)
        draft = next
    }

    private func row(_ title: String, value: String, ceiling: String, atCeiling: Bool, canLess: Bool, canMore: Bool,
                     step: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(RunnirTheme.secondaryForeground).frame(width: 70, alignment: .leading)
            HStack(spacing: 0) {
                stepButton("minus", enabled: canLess, label: "Less \(title.lowercased())") { step(-1) }
                Rectangle().fill(RunnirTheme.border).frame(width: 1)
                Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(atCeiling ? RunnirTheme.warning : RunnirTheme.foreground).frame(width: 82)
                Rectangle().fill(RunnirTheme.border).frame(width: 1)
                stepButton("plus", enabled: canMore, label: "More \(title.lowercased())") { step(1) }
            }
            .frame(height: 30)
            .background(RunnirTheme.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(RunnirTheme.border))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title).accessibilityValue(value)
            Text(ceiling).font(.system(size: 12)).foregroundStyle(RunnirTheme.mutedForeground).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func stepButton(_ symbol: String, enabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? RunnirTheme.foreground : RunnirTheme.mutedForeground)
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.hit).disabled(!enabled).accessibilityLabel(label)
    }

    /// Escape closes the panel, not the review under it.
    private func watchEscape() {
        stopWatching()
        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { close() }
            return nil
        }
    }

    private func stopWatching() {
        if let escape { NSEvent.removeMonitor(escape) }
        escape = nil
    }
}

/// One workflow of the review: its checkbox, name, file and what starts it,
/// then its jobs with theirs.
struct LocalRunLaneRow: View {
    let lane: CoreLocalRunLane
    let ticks: Set<String>
    /// The workflow a chained one follows.
    let afterTitle: String?
    let toggleLane: () -> Void
    let toggleJob: (CoreLocalRunJob) -> Void

    var body: some View {
        let state = LocalRunTicks.state(of: lane, ticks)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TickBox(state: state, label: lane.title, action: toggleLane)
                    .disabled(!LocalRunTicks.tickable(lane))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(lane.title).font(.system(size: 13, weight: .semibold))
                        Text(URL(fileURLWithPath: lane.workflowID).lastPathComponent)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(RunnirTheme.secondaryForeground)
                        Spacer(minLength: 8)
                        if !lane.event.isEmpty {
                            Text(lane.event).font(.system(size: 11, design: .monospaced)).foregroundStyle(RunnirTheme.secondaryForeground)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(RunnirTheme.border))
                                .help("The event act gets for this workflow")
                        }
                    }
                    Text(detail).font(.system(size: 11))
                        .foregroundStyle(lane.parseError.isEmpty ? RunnirTheme.secondaryForeground : RunnirTheme.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if lane.parseError.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(lane.jobs) { job in jobRow(job) }
                }
                .padding(.leading, 28)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .opacity(state == .off && lane.kind != .direct && lane.kind != .chained ? 0.75 : 1)
    }

    private var detail: String {
        if !lane.parseError.isEmpty { return lane.parseError }
        switch lane.kind {
        case .outside: return lane.skipped.isEmpty ? "Not started in this scenario" : "Not started in this scenario: \(lane.skipped)"
        case .manual: return "Started by hand on GitHub"
        case .chained: return [afterTitle.map { "After \($0) succeeds" }, lane.why.isEmpty ? nil : lane.why].compactMap { $0 }.joined(separator: " · ")
        case .direct: return lane.why
        }
    }

    private func jobRow(_ job: CoreLocalRunJob) -> some View {
        let ticked = ticks.contains(job.id)
        let caption: String = switch job.support {
        case .unsupported: job.reason
        case .unknown: job.reason
        case .host: job.skipped.isEmpty ? "\(job.runsOn.joined(separator: ", ")) · on this Mac, in the macOS sandbox" : "Skipped on GitHub: \(job.skipped)"
        case .supported: job.skipped.isEmpty ? "\(job.runsOn.joined(separator: ", ")) · \(job.image)" : "Skipped on GitHub: \(job.skipped)"
        }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            TickBox(state: ticked ? .on : .off, label: job.name.isEmpty ? job.id : job.name) { toggleJob(job) }
                .disabled(!LocalRunTicks.tickable(job))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(job.name.isEmpty ? job.id : job.name).font(.system(size: 12, weight: .medium))
                    if !job.needs.isEmpty {
                        Text("needs \(job.needs.joined(separator: ", "))").font(.system(size: 11))
                            .foregroundStyle(RunnirTheme.mutedForeground)
                    }
                }
                Text(caption).font(.system(size: 11))
                    .foregroundStyle(job.support == .unsupported ? RunnirTheme.mutedForeground : job.support == .host ? RunnirTheme.warning : RunnirTheme.secondaryForeground)
                    .lineLimit(2)
            }
        }
        .opacity(LocalRunTicks.tickable(job) ? 1 : 0.6)
    }
}

/// A checkbox that can be half on: ticked, a dash for some of a group, or
/// empty.
struct TickBox: View {
    let state: LocalRunTicks.State
    let label: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(state == .off ? RunnirTheme.secondaryForeground : RunnirTheme.primary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.hit)
        .accessibilityLabel(label)
        .accessibilityValue(state == .on ? "ticked" : state == .mixed ? "partly ticked" : "not ticked")
        .help(isEnabled ? (state == .off ? "Tick to run" : "Untick") : "Can't run on this Mac")
    }

    private var symbol: String {
        switch state {
        case .on: "checkmark.square.fill"
        case .mixed: "minus.square.fill"
        case .off: "square"
        }
    }
}
