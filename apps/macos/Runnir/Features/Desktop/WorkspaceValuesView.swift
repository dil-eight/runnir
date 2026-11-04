import AppKit
import SwiftUI

/// S16 Secrets and Variables: values for local runs of this workspace, kept
/// on this Mac in Keychain. Names come from the workflows; only values are
/// typed.
struct WorkspaceValuesView: View {
    @Bindable var model: WorkspaceValuesModel
    let workspaceID: UUID
    let session: RepositorySession
    let hub: CoreHub
    let store: any LocalRunValueStoring
    /// A sign-in brings GitHub's environments, so the list is asked again.
    var github: GitHubSession?
    @Environment(\.controlActiveState) private var activeState
    @State private var importOpen = false
    @State private var envFiles = EnvFiles.looking

    /// What the environments depend on: the workflows, and GitHub's for a
    /// job an expression places.
    private struct EnvironmentsQuestion: Equatable {
        let workflows: [CoreWorkflow]
        let connection: GitHubConnection?
    }

    /// The repository's .env files in the Import .env menu, as last listed.
    private enum EnvFiles: Equatable {
        case looking
        case listed([CoreRepositoryEnvFile])
        case unavailable
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(scope).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = model.error {
                        message(error, symbol: "exclamationmark.triangle", tint: RunnirTheme.destructive)
                    }
                    if let summary = model.importSummary {
                        message(summary, symbol: "square.and.arrow.down", tint: RunnirTheme.secondaryForeground)
                    }
                    if model.secrets.isEmpty && model.variables.isEmpty && model.unused.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "key.slash").font(.system(size: 24)).foregroundStyle(RunnirTheme.mutedForeground)
                            Text(model.environment.map { "No job deploying to \($0) reads secrets or variables" }
                                 ?? "No workflow in this workspace reads secrets or variables").font(.system(size: 14, weight: .semibold))
                            Text("Names appear here when a workflow uses secrets.NAME or vars.NAME.")
                                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                    table("SECRETS", rows: model.secrets)
                    table("VARIABLES", rows: model.variables)
                    table("SAVED, NOT USED BY ANY WORKFLOW", rows: model.unused, unused: true)
                    Text("Values stay on this Mac in Keychain and are used only for local runs. GitHub Actions secrets stay on GitHub.")
                        .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
                .padding(24).frame(maxWidth: 960, alignment: .leading)
            }
        }
        .task(id: session.workflows) { await model.load(workspaceID: workspaceID, workflows: session.workflows, store: store) }
        // Apart from the rows, as the Core may ask GitHub.
        .task(id: EnvironmentsQuestion(workflows: session.workflows, connection: github?.connection)) {
            if let environments = await hub.environments(workspaceID: workspaceID) { model.update(environments: environments) }
        }
        // Values saved from Run Locally or another window of this workspace.
        .onReceive(NotificationCenter.default.publisher(for: .localRunValuesChanged).receive(on: RunLoop.main)) { note in
            guard note.userInfo?["workspaceID"] as? UUID == workspaceID else { return }
            Task { await model.load(workspaceID: workspaceID, workflows: session.workflows, store: store) }
        }
        .onDisappear { model.hideSecrets() }
        .onChange(of: activeState) { _, state in
            if state != .key { model.hideSecrets() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if !model.environments.isEmpty { environmentPicker }
            Spacer()
            Button { importOpen.toggle() } label: {
                HStack(spacing: 6) {
                    Text("Import .env")
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(RunnirTheme.secondaryForeground)
                        .rotationEffect(.degrees(importOpen ? 180 : 0))
                }
            }
            .buttonStyle(DesignButtonStyle(open: importOpen))
            .help("Fill values from a .env file of this repository or one you choose; nothing is saved until you press Save")
            .dropdown(isPresented: $importOpen) { importMenu }
            // Listed again at every opening: a file may have come or gone.
            .task(id: importOpen) { if importOpen { await listEnvFiles() } }
            Button("Revert") { model.revert() }.disabled(!model.isDirty)
            Button("Save") { Task { _ = await model.save(workspaceID: workspaceID, store: store) } }
                .buttonStyle(DesignButtonStyle(primary: true)).keyboardShortcut("s").disabled(!model.isDirty)
        }
        .buttonStyle(DesignButtonStyle()).padding(.horizontal, 24).frame(height: 52)
    }

    /// What the set shown is for.
    private var scope: String {
        guard let environment = model.environment else {
            return model.environments.isEmpty ? "Values for local runs, kept in Keychain on this Mac."
                : "Every job gets these values, unless its environment sets its own. Kept in Keychain on this Mac."
        }
        if model.staleEnvironments.contains(environment) {
            return "No workflow deploys to \(environment) any more. Its saved values stay until you forget them."
        }
        switch (model.namedByJobs.contains(environment), model.pickedByExpression) {
        case (true, true):
            return "Jobs with environment: \(environment) get these values, and so do jobs whose environment an expression picks "
                + "when you run them with \(environment)'s. A name left empty here gets the Repository's value."
        case (false, true):
            return "Jobs whose environment an expression picks get these values when you run them with \(environment)'s. "
                + "A name left empty here gets the Repository's value, as on GitHub."
        default:
            return "Jobs with environment: \(environment) get these values. A name left empty here gets the Repository's value, as on GitHub."
        }
    }

    /// The Repository's values and each environment's, a dot on a set in
    /// which some job would get an empty value.
    private var environmentPicker: some View {
        HStack(spacing: 2) {
            segment(nil, title: "Repository")
            ForEach(model.environments, id: \.self) { segment($0, title: $0) }
        }
        .padding(2)
        .background(RunnirTheme.secondary, in: RoundedRectangle(cornerRadius: 7))
    }

    private func segment(_ environment: String?, title: String) -> some View {
        let chosen = model.environment == environment
        let stale = environment.map { model.staleEnvironments.contains($0) } ?? false
        return Button { model.select(environment) } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: chosen ? .medium : .regular))
                    .foregroundStyle(chosen ? RunnirTheme.foreground : stale ? RunnirTheme.mutedForeground : RunnirTheme.secondaryForeground)
                if model.incomplete.contains(environment) {
                    Circle().fill(RunnirTheme.warning).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10).frame(height: 23)
            .background(chosen ? RunnirTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hit)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityValue(model.incomplete.contains(environment) ? "Some values missing" : "")
    }

    @ViewBuilder private func table(_ title: String, rows: [WorkspaceValuesModel.Row], unused: Bool = false) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: title)
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        WorkspaceValueRow(model: model, row: row, unused: unused) {
                            Task { await model.reveal(row.key, workspaceID: workspaceID, store: store, ask: OwnerConfirmation.ask(reason:)) }
                        }
                        if row.id != rows.last?.id { Divider() }
                    }
                }
                .background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(RunnirTheme.border))
            }
        }
    }

    private func message(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 12)).foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    /// S16's Import .env menu: the repository's .env files, then any file.
    private var importMenu: some View {
        DropdownList(minWidth: 300) {
            DropdownHeader("In this repository")
            switch envFiles {
            case .looking:
                DropdownNote("Looking for .env files…")
            case .unavailable:
                DropdownNote("Runnir Core is not ready. Try again in a moment.")
            case .listed(let files) where files.isEmpty:
                DropdownNote("No .env files in this repository.")
            case .listed(let files):
                ForEach(files, id: \.path) { file in
                    DropdownItem(file.path, systemImage: "doc.text", detail: file.ignored ? "ignored by Git" : nil, monospaced: true) {
                        importFile(URL(fileURLWithPath: session.path).appending(path: file.path, directoryHint: .notDirectory))
                    }
                }
            }
            DropdownDivider()
            DropdownItem("Choose File…", systemImage: "folder", action: chooseFile)
            DropdownNote("Templates (.sample, .example) and node_modules are left out. Nothing is saved until you press Save.")
        }
        .frame(width: 300)
    }

    private func listEnvFiles() async {
        if let files = await hub.envFiles(workspaceID: workspaceID) {
            envFiles = .listed(files)
        } else if envFiles == .looking {
            envFiles = .unavailable
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.message = "Choose a .env file to fill values from. Nothing is saved until you press Save."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: session.path)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url)
    }

    private func importFile(_ url: URL) {
        Task {
            switch await hub.readEnvFile(url: url) {
            case .read(let file): model.apply(file)
            case .failed(let reason): model.showImportFailure(reason)
            }
        }
    }
}

/// One name and its value field.
private struct WorkspaceValueRow: View {
    @Bindable var model: WorkspaceValuesModel
    let row: WorkspaceValuesModel.Row
    let unused: Bool
    let reveal: () -> Void

    var body: some View {
        let key = row.key
        let forgotten = model.removals.contains(key)
        let edited = model.edits[key] != nil
        let missing = !row.saved && !edited && row.needed
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(key.name).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                Text(caption(missing: missing, edited: edited, forgotten: forgotten)).font(.system(size: 11))
                    .foregroundStyle(missing && !unused ? RunnirTheme.warning : edited ? RunnirTheme.primary : RunnirTheme.secondaryForeground)
                    .lineLimit(1)
            }
            .frame(width: 300, alignment: .leading)
            if unused {
                Text(key.kind == .secret ? "Secret" : "Variable").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                Spacer()
            } else {
                field(key: key, missing: missing, edited: edited)
            }
            Group {
                if row.saved && forgotten {
                    Button("Undo") { model.undoForget(key) }
                } else if row.saved {
                    Button { model.forget(key) } label: { Image(systemName: "trash") }
                        .help("Forget the saved value when you press Save")
                } else {
                    Color.clear
                }
            }
            .frame(width: 52)
        }
        .buttonStyle(DesignButtonStyle(compact: true)).padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private func field(key: LocalRunValueKey, missing: Bool, edited: Bool) -> some View {
        let binding = Binding(get: { model.text(for: key) }, set: { model.setText($0, for: key) })
        let concealed = key.kind == .secret && model.shown[key] == nil
        let placeholder = concealed && row.saved ? "••••••••••••" : row.inherited && !row.saved ? "The Repository's value" : "Value"
        HStack(spacing: 6) {
            ValueField(placeholder: placeholder, text: binding, secure: concealed,
                       border: missing ? RunnirTheme.warning : edited ? RunnirTheme.primary : nil)
            if key.kind == .secret && row.saved && !edited {
                if model.shown[key] == nil {
                    Button(action: reveal) { Image(systemName: "eye") }.handPointer().buttonStyle(.borderless)
                        .help("Show the saved value (Touch ID or your password)")
                } else {
                    Button { model.hideSecrets() } label: { Image(systemName: "eye.slash") }.handPointer().buttonStyle(.borderless)
                        .help("Hide the value")
                }
            }
        }
    }

    private func caption(missing: Bool, edited: Bool, forgotten: Bool) -> String {
        if forgotten { return "Forgotten when you press Save" }
        if model.refused.contains(row.key) { return "Keychain refused access" }
        if unused { return "not used by any workflow" }
        let readers = row.workflows.joined(separator: ", ")
        if edited { return "Edited · \(readers)" }
        if missing { return "Missing · \(readers)" }
        if row.inherited && !row.saved { return "From the Repository · \(readers)" }
        if !row.overriddenBy.isEmpty {
            let own = row.overriddenBy.count == 1 ? "sets its own" : "set their own"
            return "\(readers) · \(ListFormatter.localizedString(byJoining: row.overriddenBy)) \(own)"
        }
        return readers
    }
}

/// A value input of Secrets and Variables and the Run Locally review: 32
/// points high and monospaced, its border saying missing or edited.
struct ValueField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var border: Color?

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 13, design: .monospaced))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RunnirTheme.editor, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(border ?? RunnirTheme.border))
    }
}
