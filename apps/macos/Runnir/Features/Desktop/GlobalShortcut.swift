import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key with modifiers, as Carbon registers it.
struct KeyShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    /// Carbon modifier flags (cmdKey, optionKey, controlKey, shiftKey).
    var modifiers: UInt32
    /// What the key shows, such as "R".
    var key: String

    static let pullRequestsDefault = KeyShortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | optionKey), key: "R")

    /// "⌥⌘R", in the order macOS shows modifiers.
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + key
    }

    /// The modifiers as AppKit names them, to compare with menu items.
    var eventModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// A shortcut from a key press: it needs Command, Control or Option, so
    /// plain typing never triggers it.
    init?(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0,
              let key = Self.keyName(keyCode: keyCode, characters: characters) else { return nil }
        self.init(keyCode: UInt32(keyCode), modifiers: modifiers, key: key)
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    private static func keyName(keyCode: UInt16, characters: String?) -> String? {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: break
        }
        let functionKeys: [Int: String] = [kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                           kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        if let name = functionKeys[Int(keyCode)] ?? ansiKeys[Int(keyCode)] { return name }
        guard let characters, let first = characters.first, !first.isWhitespace, first.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else {
            return nil
        }
        return String(first).uppercased()
    }

    /// Letters, digits and punctuation by key position, as macOS shows
    /// shortcuts: ⌥⌘R stays "R" with a Russian layout on, and ⇧⌘2 is not "⇧⌘@".
    private static let ansiKeys: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G",
        kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N",
        kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U",
        kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
    ]
}

/// Settings › Pull Requests: the window's shortcut, on by default.
enum PullRequestShortcutSettings {
    static let enabledKey = "pullRequests.shortcutEnabled"
    static let shortcutKey = "pullRequests.shortcut"

    static func enabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func shortcut(in defaults: UserDefaults = .standard) -> KeyShortcut {
        guard let data = defaults.data(forKey: shortcutKey),
              let shortcut = try? JSONDecoder().decode(KeyShortcut.self, from: data) else { return .pullRequestsDefault }
        return shortcut
    }

    static func save(_ shortcut: KeyShortcut, in defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(shortcut), forKey: shortcutKey)
    }
}

/// Who else uses a shortcut: macOS's own (System Settings › Keyboard ›
/// Keyboard Shortcuts) and Runnir's menus. Other apps' exclusive global
/// shortcuts show when registering (`GlobalShortcutCenter`).
enum ShortcutConflicts {
    struct SystemHotKey: Equatable, Sendable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    /// The enabled system shortcuts.
    static func systemHotKeys() -> [SystemHotKey] {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let array = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return array.compactMap { entry in
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) ?? true,
                  let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                  let modifiers = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value else { return nil }
            return SystemHotKey(keyCode: code, modifiers: modifiers & UInt32(cmdKey | optionKey | controlKey | shiftKey))
        }
    }

    /// Why the shortcut is taken, if it is.
    @MainActor
    static func find(_ shortcut: KeyShortcut, system: [SystemHotKey] = systemHotKeys(), menu: NSMenu? = NSApp.mainMenu) -> [String] {
        var found: [String] = []
        if system.contains(SystemHotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)) {
            found.append("macOS uses \(shortcut.display) (System Settings › Keyboard › Keyboard Shortcuts).")
        }
        if let item = menuItem(for: shortcut, in: menu) {
            found.append("Runnir's \(item) menu command uses \(shortcut.display).")
        }
        return found
    }

    @MainActor
    private static func menuItem(for shortcut: KeyShortcut, in menu: NSMenu?) -> String? {
        guard let menu else { return nil }
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        for item in menu.items {
            var modifiers = item.keyEquivalentModifierMask.intersection(relevant)
            // AppKit reads an uppercase key equivalent as Shift with the key.
            if item.keyEquivalent != item.keyEquivalent.lowercased() { modifiers.insert(.shift) }
            if !item.keyEquivalent.isEmpty, item.keyEquivalent.uppercased() == shortcut.key, modifiers == shortcut.eventModifiers {
                return "“\(item.title)”"
            }
            if let found = menuItem(for: shortcut, in: item.submenu) { return found }
        }
        return nil
    }
}

/// Registers the Pull Requests window's global shortcut with Carbon, which
/// needs no accessibility permission and refuses a shortcut another app
/// already registered.
@MainActor
@Observable
final class GlobalShortcutCenter {
    enum Status: Equatable {
        case off
        case registered(KeyShortcut)
        /// It could not be registered; the reason is for the user.
        case unavailable(String)
    }

    private(set) var status: Status = .off
    @ObservationIgnored var action: @MainActor () -> Void = {}
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?
    private static let signature: OSType = 0x524E_4E52 // "RNNR"

    /// Applies the saved settings.
    func applySettings(defaults: UserDefaults = .standard) {
        apply(enabled: PullRequestShortcutSettings.enabled(in: defaults), shortcut: PullRequestShortcutSettings.shortcut(in: defaults))
    }

    func apply(enabled: Bool, shortcut: KeyShortcut) {
        unregister()
        guard enabled else {
            status = .off
            return
        }
        installHandlerIfNeeded()
        var reference: EventHotKeyRef?
        // Exclusive: refused while another app holds the same keys
        // exclusively, and no app can take them exclusively from Runnir.
        // An app that registered them without exclusivity is not reported.
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: Self.signature, id: 1),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        switch result {
        case noErr:
            hotKey = reference
            status = .registered(shortcut)
        case OSStatus(eventHotKeyExistsErr):
            status = .unavailable("Another app already uses \(shortcut.display). Choose another shortcut.")
        default:
            status = .unavailable("macOS did not accept \(shortcut.display) (error \(result)). Choose another shortcut.")
        }
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let center = Unmanaged<GlobalShortcutCenter>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { center.action() }
            return noErr
        }, 1, &eventType, context, &handler)
    }
}

/// Settings › Pull Requests: the shortcut, its switch and what it conflicts with.
struct PullRequestShortcutSettingsSection: View {
    let center: GlobalShortcutCenter
    @AppStorage(PullRequestShortcutSettings.enabledKey) private var enabled = true
    @State private var shortcut = PullRequestShortcutSettings.shortcut()
    @State private var recording = false
    @State private var monitor: Any?
    @State private var refusal: String?

    var body: some View {
        Section("Pull Requests") {
            Toggle("Open the Pull Requests window with a shortcut", isOn: $enabled).handPointer()
                .onChange(of: enabled) { center.apply(enabled: enabled, shortcut: shortcut) }
            HStack {
                Text("Shortcut")
                Spacer()
                Button(recording ? "Type a shortcut…" : shortcut.display) { recording ? stopRecording() : startRecording() }.handPointer()
                    .font(.system(size: 12, design: .monospaced))
                    .help(recording ? "Press the keys, or Escape to keep the current shortcut" : "Click, then press the new shortcut")
                    .accessibilityIdentifier("pull-requests-shortcut")
                Button("Reset") { save(.pullRequestsDefault) }.handPointer()
                    .disabled(shortcut == .pullRequestsDefault)
            }
            .disabled(!enabled)
            if let refusal {
                Label(refusal, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(RunnirTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .unavailable(let reason) = center.status {
                Label(reason, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(RunnirTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if enabled {
                Text("\(shortcut.display) opens the window from any app. The menu bar item shows the same list.")
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        refusal = nil
        recording = true
        // Off while recording, so pressing the current shortcut records it
        // instead of opening the window.
        center.apply(enabled: false, shortcut: shortcut)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape {
                stopRecording()
                return nil
            }
            guard let candidate = KeyShortcut(keyCode: event.keyCode, flags: event.modifierFlags, characters: event.charactersIgnoringModifiers) else {
                refusal = "Use Command, Control or Option with a key."
                return nil
            }
            stopRecording()
            save(candidate)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        center.apply(enabled: enabled, shortcut: shortcut)
    }

    /// Keeps a shortcut nothing else uses; otherwise says who uses it.
    private func save(_ candidate: KeyShortcut) {
        let conflicts = ShortcutConflicts.find(candidate)
        guard conflicts.isEmpty else {
            refusal = conflicts.joined(separator: " ") + " The shortcut stays \(shortcut.display)."
            return
        }
        let previous = shortcut
        center.apply(enabled: enabled, shortcut: candidate)
        if case .unavailable(let reason) = center.status {
            refusal = reason + " The shortcut stays \(previous.display)."
            center.apply(enabled: enabled, shortcut: previous)
            return
        }
        refusal = nil
        shortcut = candidate
        PullRequestShortcutSettings.save(candidate)
    }
}
