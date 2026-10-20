import AppKit

enum UnsavedChoice: Equatable {
    case save, discard, cancel
}

/// The Mac's usual question before edits would be lost: Save (Return),
/// Don't Save (Command-D) or Cancel (Escape).
enum UnsavedChangesPrompt {
    static func title(for files: [String]) -> String {
        files.count == 1
            ? "Do you want to save the changes you made to \(files[0])?"
            : "Do you want to save the changes you made to \(files.count) workflow files?"
    }

    static func detail(for files: [String]) -> String {
        files.count == 1
            ? "Your changes will be lost if you don't save them."
            : "\(ListFormatter.localizedString(byJoining: files)) have unsaved changes. They will be lost if you don't save them."
    }

    @MainActor static func alert(for files: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title(for: files)
        alert.informativeText = detail(for: files)
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    @MainActor static func ask(files: [String]) -> UnsavedChoice {
        switch alert(for: files).runModal() {
        case .alertFirstButtonReturn: .save
        case .alertSecondButtonReturn: .discard
        default: .cancel
        }
    }

    @MainActor static func ask(fileName: String) -> UnsavedChoice { ask(files: [fileName]) }
}
