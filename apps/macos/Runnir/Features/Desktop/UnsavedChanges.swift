import Foundation

enum UnsavedChoice: Equatable {
    case save, discard, cancel
}

/// The Mac's usual question before edits would be lost, in Runnir's own
/// dialog: Save (Return), Don't Save (Command-D) or Cancel (Escape).
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

    static func question(for files: [String]) -> DialogAsker.Question {
        DialogAsker.Question(title: title(for: files), message: detail(for: files),
                             choices: [DialogChoice(title: "Don't Save", commandKey: "d"), DialogChoice(title: "Cancel"),
                                       DialogChoice(title: "Save", kind: .action)],
                             cancel: 1)
    }

    /// The choice an answer to `question` names.
    static func choice(_ answer: Int) -> UnsavedChoice {
        switch answer {
        case 2: .save
        case 0: .discard
        default: .cancel
        }
    }
}
