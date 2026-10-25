import AppKit

enum UnsavedChoice: Equatable {
    case save, discard, cancel
}

/// The Mac's usual question before edits would be lost: Save (Return),
/// Don't Save (Command-D) or Cancel (Escape).
enum UnsavedChangesPrompt {
    static func title(for files: [String]) -> String {
        if files.count == 1 { return "Do you want to save the changes you made to \(files[0])?" }
        let workflows = files.allSatisfy { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
        return "Do you want to save the changes you made to \(files.count) \(workflows ? "workflow files" : "items")?"
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
        choice(alert(for: files).runModal())
    }

    /// Asks in a sheet on `window`. AppKit shows it once a sheet still on
    /// the window (one that is closing, say) is gone, so the two never
    /// stack. Without a window it asks in a dialog.
    @MainActor static func ask(fileName: String, sheetOn window: NSWindow?) async -> UnsavedChoice {
        guard let window else { return ask(fileName: fileName) }
        let alert = alert(for: [fileName])
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        return choice(response)
    }

    static func choice(_ response: NSApplication.ModalResponse) -> UnsavedChoice {
        switch response {
        case .alertFirstButtonReturn: .save
        case .alertSecondButtonReturn: .discard
        default: .cancel
        }
    }

    @MainActor static func ask(fileName: String) -> UnsavedChoice { ask(files: [fileName]) }
}
