import Foundation
import Testing
@testable import Runnir

/// Runnir's own dropdowns (Dropdown.swift): where the panel opens, and that
/// no system menu, popover or menu-style picker comes back into the app.
@Suite struct DropdownTests {
    @Test func thePanelOpensUnderItsButtonOrAboveWhenOnlyThatFits() {
        let top = CGRect(x: 0, y: 100, width: 80, height: 26)
        let low = CGRect(x: 0, y: 500, width: 80, height: 26)
        let middle = CGRect(x: 0, y: 150, width: 80, height: 26)
        #expect(DropdownPlacement.top(button: top, panelHeight: 200, space: 600) == 130, "under the button, 4 points apart")
        #expect(DropdownPlacement.top(button: low, panelHeight: 200, space: 600) == 296, "above when it does not fit under")
        #expect(DropdownPlacement.top(button: middle, panelHeight: 500, space: 600) == 180, "under when it fits neither way")
    }

    @Test func thePanelStaysInsideTheWindowSideways() {
        let right = CGRect(x: 1100, y: 100, width: 140, height: 26)
        #expect(DropdownPlacement.shift(button: right, panelWidth: 100, space: 1280, trailing: false) == 0, "it fits as lined up")
        #expect(DropdownPlacement.shift(button: right, panelWidth: 340, space: 1280, trailing: false) == -168, "8 points from the right side")
        let left = CGRect(x: 20, y: 100, width: 26, height: 26)
        #expect(DropdownPlacement.shift(button: left, panelWidth: 200, space: 1280, trailing: true) == 162, "8 points from the left side")
        #expect(DropdownPlacement.shift(button: left, panelWidth: 0, space: 1280, trailing: true) == 0, "a panel not measured yet stays put")
    }

    @Test func theAppUsesItsOwnDropdowns() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Runnir")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !$0.path.contains("/Generated/") }
        #expect(files.count > 20, "the app's sources were not found next to the tests")
        var found: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in SystemDropdownAudit.lines(in: source) {
                found.append("\(file.lastPathComponent):\(line)")
            }
        }
        #expect(found.isEmpty, "System dropdowns where Runnir's own belong (DropdownMenu, DropdownPicker, .dropdown): \(found.sorted().joined(separator: ", "))")
    }

    @Test func theAuditFindsSystemDropdowns() {
        let source = ##"""
        Menu { Button("A") {} } label: { Text("Menu") }
        DropdownMenu { DropdownItem("A") {} } label: { _ in Text("Ours") }
        Text("Filter").popover(isPresented: $shown) { Text("Panel") }
        Picker("Owner", selection: $owner) { Text("All") }
        Picker("Mode", selection: $mode) { Text("A") }
            .pickerStyle(.segmented)
        DropdownPicker("Owner", selection: $owner, options: [])
        Text("Row").contextMenu { Button("Copy") {} }
        // A Menu { } in a comment is fine.
        Menu("Install...") { }
        """##
        #expect(SystemDropdownAudit.lines(in: source) == [1, 3, 4, 10])
    }
}

/// A light reading of SwiftUI source, as PointerAudit's: SwiftUI menus,
/// popovers, and pickers other than segmented, radio-group or inline ones.
/// Right-click context menus stay the system's.
enum SystemDropdownAudit {
    private static let menuOrPopover = try! NSRegularExpression(pattern: #"(?<![\w.])Menu\s*[({]|\.popover\("#)
    private static let picker = try! NSRegularExpression(pattern: #"(?<![\w.])Picker\s*\("#)
    private static let drawnInline = try! NSRegularExpression(pattern: #"\.pickerStyle\(\s*\.(?:segmented|radioGroup|inline)"#)

    /// 1-based lines of system dropdowns.
    static func lines(in source: String) -> [Int] {
        let lines = source.components(separatedBy: "\n")
        var found: [Int] = []
        for (index, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            if matches(menuOrPopover, line) {
                found.append(index + 1)
            } else if matches(picker, line) {
                // A picker's style follows its options within a few lines,
                // before the next picker.
                var end = index + 1
                while end < min(index + 8, lines.count), !matches(picker, lines[end]) { end += 1 }
                if !matches(drawnInline, lines[index..<end].joined(separator: "\n")) { found.append(index + 1) }
            }
        }
        return found
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
