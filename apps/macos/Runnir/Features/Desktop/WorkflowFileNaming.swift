import SwiftUI

/// What the name sheet does: add a workflow file, or rename the open one.
enum WorkflowFileNameRequest: Identifiable, Equatable {
    case create
    case rename(LocalWorkflowFile)

    var id: String {
        switch self {
        case .create: "create"
        case .rename(let file): "rename \(file.relativePath)"
        }
    }
}

enum WorkflowFileName {
    /// The file name for what was typed: trimmed, with ".yml" added when it
    /// does not end in .yml or .yaml. The Core decides whether it is allowed.
    static func normalized(_ text: String) -> String {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty else { return "" }
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "yml" || ext == "yaml" ? name : name + ".yml"
    }

    /// A free name for a new file: "workflow.yml", then "workflow-2.yml"...
    static func suggestion(avoiding files: [LocalWorkflowFile]) -> String {
        let taken = Set(files.map { $0.name.lowercased() })
        var candidate = "workflow.yml"
        var number = 2
        while taken.contains(candidate) {
            candidate = "workflow-\(number).yml"
            number += 1
        }
        return candidate
    }
}

/// Asks for a workflow file name. `commit` returns why the Core refused it,
/// or nil once the file was created or renamed.
struct WorkflowFileNameSheet: View {
    let request: WorkflowFileNameRequest
    let files: [LocalWorkflowFile]
    let commit: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var error: String?
    @State private var isWorking = false
    @FocusState private var focused: Bool

    init(request: WorkflowFileNameRequest, files: [LocalWorkflowFile], commit: @escaping (String) async -> String?) {
        self.request = request
        self.files = files
        self.commit = commit
        switch request {
        case .create: _text = State(initialValue: WorkflowFileName.suggestion(avoiding: files))
        case .rename(let file): _text = State(initialValue: file.name)
        }
    }

    private var name: String { WorkflowFileName.normalized(text) }

    private var unchanged: Bool {
        if case .rename(let file) = request { return name == file.name }
        return false
    }

    /// Caught before asking the Core; on a Mac a name differing only in case
    /// is usually the same file.
    private var taken: Bool {
        files.contains { $0.name.lowercased() == name.lowercased() && !isRenamed($0) }
    }

    private func isRenamed(_ file: LocalWorkflowFile) -> Bool {
        if case .rename(let renamed) = request { return renamed == file }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                TextField("File name", text: $text)
                    .textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { submit() }
                    .onChange(of: text) { error = nil }
                    .accessibilityIdentifier("workflow-file-name")
                Text(name.isEmpty ? " " : ".github/workflows/\(name)")
                    .font(.system(size: 11).monospaced()).foregroundStyle(RunnirTheme.secondaryForeground)
                    .lineLimit(1).truncationMode(.middle)
            }
            if let message = error ?? (taken ? "A file with that name already exists in .github/workflows." : nil) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.warning).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                // Not while the Core works: the result belongs to this sheet.
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isWorking)
                Button(isWorking ? workingTitle : actionTitle) { submit() }
                    .buttonStyle(DesignButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || unchanged || taken || isWorking)
            }.buttonStyle(DesignButtonStyle())
        }
        .padding(20).frame(width: 440)
        .interactiveDismissDisabled(isWorking)
        .onAppear { focused = true }
    }

    private var title: String {
        switch request {
        case .create: "New Workflow File"
        case .rename(let file): "Rename \(file.name)"
        }
    }

    private var detail: String {
        switch request {
        case .create:
            "Adds a file to .github/workflows with one job you can run by hand, on GitHub after you push it or here with Run Locally. Nothing is committed."
        case .rename:
            "Renames the file in .github/workflows. Its star moves and its presets are copied to the new name; GitHub keeps the old name until the change reaches the default branch. Nothing is committed."
        }
    }

    private var actionTitle: String {
        switch request {
        case .create: "Create"
        case .rename: "Rename"
        }
    }

    private var workingTitle: String {
        switch request {
        case .create: "Creating..."
        case .rename: "Renaming..."
        }
    }

    private func submit() {
        guard !name.isEmpty, !unchanged, !taken, !isWorking else { return }
        isWorking = true
        Task {
            let message = await commit(name)
            isWorking = false
            if let message { error = message } else { dismiss() }
        }
    }
}
