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
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let error = model.error {
                        message(error, symbol: "exclamationmark.triangle", tint: RunnirTheme.destructive)
                    }
                    if let summary = model.importSummary {
                        message(summary, symbol: "square.and.arrow.down", tint: RunnirTheme.secondaryForeground)
                    }
                    if model.secrets.isEmpty && model.variables.isEmpty && model.unused.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "key.slash").font(.system(size: 24)).foregroundStyle(RunnirTheme.mutedForeground)
                            Text("No workflow in this workspace reads secrets or variables").font(.system(size: 14, weight: .semibold))
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
        .onDisappear { model.hideSecrets() }
        .onChange(of: activeState) { _, state in
            if state != .key { model.hideSecrets() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Secrets and Variables").font(.system(size: 15, weight: .semibold))
            Text("for local runs").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
            Spacer()
            Button("Import .env…", action: importFile)
                .help("Fill values from a .env file you choose; nothing is saved until you press Save")
            Button("Revert") { model.revert() }.disabled(!model.isDirty)
            Button("Save") { Task { _ = await model.save(workspaceID: workspaceID, store: store) } }
                .buttonStyle(DesignButtonStyle(primary: true)).keyboardShortcut("s").disabled(!model.isDirty)
        }
        .buttonStyle(DesignButtonStyle()).padding(.horizontal, 24).frame(height: 52)
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

    private func importFile() {
        let panel = NSOpenPanel()
        panel.message = "Choose a .env file to fill values from. Nothing is saved until you press Save."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: session.path)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            switch await hub.readEnvFile(path: url.path) {
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
        let missing = !row.saved && !edited
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
        HStack(spacing: 6) {
            Group {
                if concealed {
                    SecureField(row.saved ? "••••••••••••" : "Value", text: binding)
                } else {
                    TextField("Value", text: binding)
                }
            }
            .textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(missing ? RunnirTheme.warning : edited ? RunnirTheme.primary : .clear))
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
        return missing ? "Missing · \(readers)" : readers
    }
}
