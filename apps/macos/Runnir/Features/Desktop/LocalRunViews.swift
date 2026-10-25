import AppKit
import SwiftUI

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
            }.handPointer()
            .help("Opens Terminal with brew install act; it runs when you press Return there. Then press Recheck.")
        } else {
            Button("Install…") { openURL(ActInstaller.instructions) }.handPointer()
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
        let memory = ByteCountFormatter.string(fromByteCount: Int64(plan.memoryBytes), countStyle: .memory)
        let minutes = plan.timeoutSeconds / 60
        return "\(plan.cpus) CPU\(plan.cpus == 1 ? "" : "s") · \(memory) memory · \(minutes) min timeout"
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
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(spacing: 10) {
            ToolStateIcon(state: state, untested: untested).font(.system(size: 12))
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                .lineLimit(2).truncationMode(.middle).help(detail)
            Spacer(minLength: 8)
            action()
        }
        .padding(.horizontal, 10).frame(minHeight: 30)
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
            Button("Recheck", action: recheck).handPointer()
        } else if engine.state == .stopped, let app = ContainerEngineApp.installedURL(for: engine.name) {
            Button("Open \(engine.name)") {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            }.handPointer().help("Start \(engine.name), then press Recheck")
        } else if engine.state == .missing {
            Menu("Install...") {
                ForEach(ContainerEngineApp.instructions, id: \.name) { item in
                    Button(item.name) { openURL(item.url) }
                }
            }.handPointer().fixedSize().help("Opens the vendor's official instructions")
        } else {
            Button("Recheck", action: recheck).handPointer()
        }
    }
}

// MARK: S10 Local execution review

struct LocalRunSheet: View {
    @Bindable var model: LocalRunReviewModel
    let repositoryPath: String
    /// The workflow's name when the editor holds changes that are not saved.
    var unsavedFile: String?
    /// Opens Secrets and Variables for this workspace.
    var manageValues: () -> Void = {}
    let onStarted: (LocalRunModel) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 24).padding(.vertical, 18)
            DesignDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(RunnirTheme.warning)
                    }
                    if let unsavedFile {
                        Label("\(unsavedFile) has unsaved changes. act runs the file as it is saved on disk.", systemImage: "pencil")
                            .font(.system(size: 12)).foregroundStyle(RunnirTheme.warning)
                    }
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
        .task { await model.prepare() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run locally").font(.system(size: 17, weight: .semibold))
            HStack(spacing: 8) {
                Text(URL(fileURLWithPath: model.workflowID).lastPathComponent)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(RunnirTheme.mutedForeground)
                Menu {
                    Button("All jobs") { choose(job: nil) }
                    Divider()
                    ForEach(model.jobs, id: \.id) { job in Button(job.id) { choose(job: job.id) } }
                } label: { Text("job: \(model.jobID ?? "all")") }
                    .menuStyle(.button).buttonStyle(.plain).pointerStyle(.link).fixedSize()
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(RunnirTheme.mutedForeground)
                Menu {
                    ForEach(model.prepared?.plan.events ?? [], id: \.self) { event in Button(event) { choose(event: event) } }
                } label: { Text("event: \(model.event ?? model.prepared?.plan.event ?? "—")") }
                    .menuStyle(.button).buttonStyle(.plain).pointerStyle(.link).fixedSize()
                    .disabled((model.prepared?.plan.events.count ?? 0) < 2)
                if model.isPreparing { ProgressView().controlSize(.small) }
            }
            .font(.system(size: 12, design: .monospaced)).foregroundStyle(RunnirTheme.secondaryForeground)
        }
    }

    private func choose(job: String?) {
        model.jobID = job
        Task { await model.prepare() }
    }

    private func choose(event: String) {
        model.event = event
        Task { await model.prepare() }
    }

    private func recheck() { Task { await model.prepare() } }

    @ViewBuilder private var tools: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "ENGINE AND TOOLS")
            if let readiness = model.prepared?.readiness {
                let act = readiness.act(useInstalled: model.prepared?.plan.installedAct ?? false)
                VStack(spacing: 2) {
                    ToolReadinessRow(title: "Docker CLI", state: readiness.dockerCLI.state, detail: LocalRunText.tool(readiness.dockerCLI)) {
                        Button("Recheck", action: recheck)
                    }
                    ToolReadinessRow(title: "Container engine", state: readiness.engine.state, detail: LocalRunText.engine(readiness.engine)) {
                        EngineSetupButton(engine: readiness.engine, recheck: recheck)
                    }
                    ToolReadinessRow(title: "act", state: act.status.state, untested: act.status.untested,
                                     detail: LocalRunText.tool(act.status) + (act.installed ? " · installed (experimental)" : " · bundled")) {
                        Button("Recheck", action: recheck)
                    }
                }
                .buttonStyle(DesignButtonStyle())
                .padding(.vertical, 4).background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 6))
            } else if model.isPreparing {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking tools...").font(.system(size: 12)) }
            }
        }
    }

    @ViewBuilder private var compatibility: some View {
        if let plan = model.prepared?.plan {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: "COMPATIBILITY")
                ForEach(plan.blockers, id: \.self) { blocker in
                    line(blocker, symbol: "xmark.octagon", tint: RunnirTheme.destructive)
                }
                if let engine = model.prepared?.readiness.engine, engine.state != .found || !engine.local {
                    line("Static validation still works without an engine.", symbol: "info.circle", tint: RunnirTheme.secondaryForeground)
                }
                ForEach(plan.jobs) { job in
                    switch job.support {
                    case .supported:
                        line("\(job.id): runs-on \(job.runsOn.joined(separator: ", ")) in \(job.image).", symbol: "checkmark.circle", tint: RunnirTheme.success)
                    case .unsupported:
                        line("\(job.id): \(job.reason). act skips it.", symbol: "minus.circle", tint: RunnirTheme.mutedForeground)
                    case .unknown:
                        line("\(job.id): \(job.reason).", symbol: "questionmark.circle", tint: RunnirTheme.warning)
                    }
                }
                ForEach(plan.images.filter { !$0.present }, id: \.reference) { image in
                    line("Image download needed: \(image.reference).", symbol: "arrow.down.circle", tint: RunnirTheme.warning)
                }
                ForEach(plan.notes, id: \.self) { note in
                    line(note, symbol: "info.circle", tint: RunnirTheme.secondaryForeground)
                }
            }
        }
    }

    @ViewBuilder private var access: some View {
        if let plan = model.prepared?.plan {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: "WHAT THIS RUN CAN ACCESS")
                accessRow("folder", "Workspace", "Copy of \(LocalRunText.abbreviated(repositoryPath)) made by actions/checkout, with uncommitted changes and without .gitignore'd files; not mounted live")
                accessRow("globe", "Network", "On (bridge network): downloads images and actions; workflow steps may send data")
                accessRow(model.runKeys.isEmpty ? "key.slash" : "key", "Secrets", model.accessSummary)
                accessRow("gauge.with.dots.needle.33percent", "Limits", LocalRunText.limits(plan))
                accessRow("nosign", "Never mounted", "Docker socket · home directory")
            }
        }
    }

    /// The secrets and variables the run reads: saved values stay hidden,
    /// a typed value is used for this run.
    @ViewBuilder private var values: some View {
        if !model.runKeys.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: "SECRETS AND VARIABLES")
                VStack(spacing: 0) {
                    ForEach(model.runKeys, id: \.self) { key in
                        valueRow(key)
                        if key != model.runKeys.last { Divider() }
                    }
                }
                .background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(RunnirTheme.border))
                HStack {
                    Toggle("Save entered values to this workspace", isOn: $model.saveEntered)
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

    private func valueRow(_ key: LocalRunValueKey) -> some View {
        let missing = model.missing.contains(key)
        let entered = !(model.entered[key] ?? "").isEmpty
        let caption = model.refused.contains(key) ? "Keychain refused access · empty in this run"
            : entered ? "Entered for this run" : missing ? "Missing · empty in this run"
            : key.kind == .secret ? "Saved secret" : "Saved variable"
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
            .help(model.prepared?.confirmationID == nil ? "Resolve the problems above first" : model.trusted ? "Start act with this plan" : "Confirm that you trust this workflow")
        }.buttonStyle(DesignButtonStyle())
    }

    private func line(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 14)
            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }.font(.system(size: 13))
    }

    private func accessRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(RunnirTheme.secondaryForeground).frame(width: 16)
            Text(title).foregroundStyle(RunnirTheme.secondaryForeground).frame(width: 110, alignment: .leading)
            Text(detail).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 13))
    }
}

// MARK: S11 Local run output

struct LocalRunView: View {
    @Bindable var run: LocalRunModel
    @State private var follow = true

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
            Text("Local · not a GitHub run")
            Text("\(run.plan.engineName.isEmpty ? "Container engine" : run.plan.engineName) · act \(run.plan.actVersion)\(run.plan.installedAct ? " (installed)" : "")")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(RunnirTheme.secondaryForeground)
            Text("No GitHub token injected")
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
                ForEach(run.jobs) { job in
                    Button { run.selectedJobID = job.id } label: {
                        HStack(alignment: .top, spacing: 10) {
                            LocalJobIcon(state: job.state).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.name.isEmpty ? job.id : job.name).font(.system(size: 13, weight: .medium))
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
                Button { run.selectedJobID = nil } label: {
                    Label("All output", systemImage: "text.alignleft").font(.system(size: 12))
                        .padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        .background(run.selectedJobID == nil ? RunnirTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.hit).foregroundStyle(RunnirTheme.secondaryForeground)
            }.padding(8)
        }
    }

    private var output: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("\(run.selectedJobID ?? "All") · output").font(.system(size: 13, weight: .semibold))
                statusChip
                Spacer()
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
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, line in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)").foregroundStyle(RunnirTheme.mutedForeground).frame(width: 40, alignment: .trailing)
                            Text(line.text).foregroundStyle(line.isError ? RunnirTheme.destructive : RunnirTheme.foreground)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }.font(.system(size: 12, design: .monospaced)).padding(.horizontal, 12).padding(.vertical, 1).id(line.id)
                    }
                    if visible.isEmpty {
                        Text(run.isFinished ? "No output for this job." : "Waiting for output...")
                            .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).padding(16)
                    }
                }.padding(.vertical, 8)
            }
            .background(RunnirTheme.editor)
            .onChange(of: visible.last?.id) { _, last in
                if follow, let last { proxy.scrollTo(last, anchor: .bottom) }
            }
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
            default: return (run.exitCode.map { "Failed · exit code \($0)" } ?? "Failed", RunnirTheme.destructive)
            }
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
        case .running: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(RunnirTheme.info)
        case .succeeded: Image(systemName: "checkmark.circle").foregroundStyle(RunnirTheme.success)
        case .failed: Image(systemName: "xmark.circle").foregroundStyle(RunnirTheme.destructive)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(RunnirTheme.secondaryForeground)
        case .skipped, .unsupported: Image(systemName: "nosign").foregroundStyle(RunnirTheme.warning)
        case .notRun, .unknown: Image(systemName: "minus.circle").foregroundStyle(RunnirTheme.mutedForeground)
        }
    }
}
