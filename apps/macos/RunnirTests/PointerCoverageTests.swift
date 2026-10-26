import Foundation
import Testing

/// Every control that takes a click shows the hand pointer. A button without
/// a style of its own gets it from `HandPointerButtonStyle` at the root of
/// its window; one styled by `DesignButtonStyle`, `.hit` or
/// `WorkflowTabStyle` has it in the style; any other control (a toggle,
/// picker, menu, link, tap gesture, or a button in another style) needs
/// `.handPointer()`, `.clickable()` or `.pointerStyle(.link)` in its own
/// modifiers. Items of menus, alerts and confirmation dialogs are drawn by
/// the system and are left out, as is a control marked with a
/// `// No hand pointer:` comment on its line or the line above.
@Suite struct PointerCoverageTests {
    @Test func everyClickableControlShowsTheHandPointer() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Runnir")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !$0.path.contains("/Generated/") }
        #expect(files.count > 20, "the app's sources were not found next to the tests")
        var missing: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in PointerAudit.controlsWithoutHand(in: source) {
                missing.append("\(file.lastPathComponent):\(line)")
            }
        }
        #expect(missing.isEmpty, "Controls without the hand pointer: \(missing.sorted().joined(separator: ", "))")
    }

    @Test func everyWindowRootGivesButtonsTheHand() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Runnir/App")
        let coordinator = try String(contentsOf: app.appendingPathComponent("Desktop/DesktopCoordinator.swift"), encoding: .utf8)
        let roots = coordinator.components(separatedBy: "NSHostingController(rootView:").dropFirst()
        #expect(roots.count >= 4)
        for root in roots where !root.hasPrefix(" StartupSplashView()") {
            // The root view's expression: its modifiers follow within a few lines.
            #expect(root.prefix(400).contains(".handPointerButtons()"), "A window root without handPointerButtons(): \(root.prefix(60))")
        }
        let appFile = try String(contentsOf: app.appendingPathComponent("RunnirApp.swift"), encoding: .utf8)
        #expect(appFile.contains(".handPointerButtons()"), "The menu bar window does not apply handPointerButtons()")
    }

    @Test func auditFindsControlsWithoutTheHand() {
        let source = ##"""
        VStack {
            Button("Default style") { go() }
            Button("Styled") { go() }.buttonStyle(DesignButtonStyle())
            Toggle("Switch", isOn: $on).handPointer()
            Picker("Pick", selection: $value) { Text("A") }
            Text("Row").onTapGesture { go() }
            Text("Row").clickable().onTapGesture { go() }
            // No hand pointer: the background.
            Color.clear.onTapGesture { close() }
        }
        .alert("Title", isPresented: $shown) { Button("OK") {} }
        HStack { Button("Inherited") { go() } }.buttonStyle(.hit)
        Menu { Button("Item") { go() } } label: { Text("Menu") }.handPointer()
        let pattern = #"(?<q>"[^"(]*)"#
        Button("Link") { go() }.buttonStyle(.link)
        HStack { Button("Plain") { go() } }.buttonStyle(.plain)
        """##
        #expect(PointerAudit.controlsWithoutHand(in: source) == [5, 6, 15, 16])
    }
}

/// A light reading of SwiftUI source: enough to find a control's modifiers
/// and the views around it, not a Swift parser.
enum PointerAudit {
    private static let control = try! NSRegularExpression(pattern: #"(?<![\w.])(Button|Toggle|Picker|Menu|Link)\s*[({]|\.onTapGesture\b"#)
    private static let ownHand = try! NSRegularExpression(
        pattern: #"\.pointerStyle\(\s*(?:isEnabled\s*\?\s*)?\.link|\.clickable\(\)|\.handPointer\(\)|\.buttonStyle\(\s*(?:\.hit\b|DesignButtonStyle|HitButtonStyle|WorkflowTabStyle)"#)
    private static let handStyle = try! NSRegularExpression(pattern: #"^\.buttonStyle\(\s*(?:\.hit\b|DesignButtonStyle|HitButtonStyle|WorkflowTabStyle)"#)
    private static let anyStyle = try! NSRegularExpression(pattern: #"\.buttonStyle\("#)
    private static let systemDrawn = try! NSRegularExpression(
        pattern: #"(?:^|\.)(contextMenu|alert|confirmationDialog|commands|swipeActions|toolbar|Menu|CommandGroup|CommandMenu|MenuBarExtra)$"#)

    /// 1-based lines of controls without the hand pointer.
    static func controlsWithoutHand(in source: String) -> [Int] {
        let text = Array(blankCommentsAndStrings(source).utf16)
        let original = source.components(separatedBy: "\n")
        let string = String(utf16CodeUnits: text, count: text.count)
        var lines: [Int] = []
        for match in control.matches(in: string, range: NSRange(location: 0, length: text.count)) {
            let start = match.range.location
            let line = text[..<start].filter { $0 == 10 }.count + 1
            if original[line - 1].contains("// No hand pointer:") || (line > 1 && original[line - 2].contains("// No hand pointer:")) { continue }
            if match.range(at: 1).location == NSNotFound {
                // A tap gesture: the hand comes from the modifiers of the same view.
                let chain = statement(around: start, in: text)
                if !contains(ownHand, chain) { lines.append(line) }
                continue
            }
            let enclosing = openBrackets(before: start, in: text)
            if enclosing.contains(where: { contains(systemDrawn, owner(of: $0, in: text)) }) { continue }
            let end = expressionEnd(from: start, in: text)
            if contains(ownHand, slice(text, start, end)) { continue }
            if string[Range(match.range(at: 1), in: string)!] == "Button", buttonGetsHand(own: slice(text, start, end), enclosing, in: text) { continue }
            lines.append(line)
        }
        return lines
    }

    private static func contains(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func slice(_ text: [UInt16], _ from: Int, _ to: Int) -> String {
        String(utf16CodeUnits: Array(text[max(0, from)..<min(text.count, to)]), count: min(text.count, to) - max(0, from))
    }

    /// A button gets the hand from the nearest `.buttonStyle` around it when
    /// that style gives it, or from the root style when no style is set.
    private static func buttonGetsHand(own: String, _ enclosing: [Int], in text: [UInt16]) -> Bool {
        if contains(anyStyle, own) { return false }
        for open in enclosing {
            let modifiers = slice(text, closing(open, in: text) + 1, modifiersEnd(after: closing(open, in: text) + 1, in: text))
            guard let style = anyStyle.firstMatch(in: modifiers, range: NSRange(location: 0, length: (modifiers as NSString).length)) else { continue }
            return contains(handStyle, (modifiers as NSString).substring(from: style.range.location))
        }
        return true
    }

    private static func blankCommentsAndStrings(_ source: String) -> String {
        var out = Array(source.utf16)
        let s = out
        var i = 0
        func blank(_ from: Int, _ to: Int) { for k in from..<min(to, out.count) where out[k] != 10 { out[k] = 32 } }
        func starts(_ p: String, _ at: Int) -> Bool {
            let u = Array(p.utf16); return at + u.count <= s.count && Array(s[at..<at + u.count]) == u
        }
        while i < s.count {
            if s[i] == 35 {
                // A raw string, #"..."# or #"""..."""#, with any number of #.
                var hashes = 0
                while i + hashes < s.count && s[i + hashes] == 35 { hashes += 1 }
                let open = i + hashes
                if open < s.count && s[open] == 34 {
                    let quotes = starts("\"\"\"", open) ? 3 : 1
                    let terminator = String(repeating: "\"", count: quotes) + String(repeating: "#", count: hashes)
                    var j = open + quotes
                    while j < s.count && !starts(terminator, j) { j += 1 }
                    blank(open + quotes, j)
                    i = j + terminator.utf16.count
                    continue
                }
                i += hashes
                continue
            }
            if starts("//", i) {
                var j = i; while j < s.count && s[j] != 10 { j += 1 }
                blank(i, j); i = j
            } else if starts("/*", i) {
                var j = i + 2; while j + 1 < s.count && !(s[j] == 42 && s[j + 1] == 47) { j += 1 }
                blank(i, j + 2); i = j + 2
            } else if starts("\"\"\"", i) {
                var j = i + 3; while j + 2 < s.count && !starts("\"\"\"", j) { j += 1 }
                blank(i + 3, j); i = j + 3
            } else if s[i] == 34 {
                var j = i + 1, depth = 0
                while j < s.count {
                    if depth == 0 && s[j] == 92 && j + 1 < s.count && s[j + 1] == 40 { depth = 1; j += 2; continue }
                    if depth > 0 && s[j] == 40 { depth += 1 } else if depth > 0 && s[j] == 41 { depth -= 1 }
                    else if depth == 0 && s[j] == 92 { j += 2; continue }
                    else if depth == 0 && s[j] == 34 { break }
                    j += 1
                }
                blank(i + 1, j); i = j + 1
            } else {
                i += 1
            }
        }
        return String(utf16CodeUnits: out, count: out.count)
    }

    private static func closing(_ open: Int, in text: [UInt16]) -> Int {
        var depth = 0
        for j in open..<text.count {
            switch text[j] {
            case 40, 123, 91: depth += 1
            case 41, 125, 93:
                depth -= 1
                if depth == 0 { return j }
            default: break
            }
        }
        return text.count - 1
    }

    /// Opening brackets around `offset`, innermost first.
    private static func openBrackets(before offset: Int, in text: [UInt16]) -> [Int] {
        var stack: [Int] = []
        for j in 0..<offset {
            switch text[j] {
            case 40, 123, 91: stack.append(j)
            case 41, 125, 93: if !stack.isEmpty { stack.removeLast() }
            default: break
            }
        }
        return stack.reversed()
    }

    private static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 }
    private static func isWord(_ c: UInt16) -> Bool { (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }

    /// The call or modifier an opening bracket belongs to, as `.alert` or `Menu`.
    private static func owner(of open: Int, in text: [UInt16]) -> String {
        var k = open - 1
        while k >= 0 && isSpace(text[k]) { k -= 1 }
        if k >= 0 && text[k] == 41 {
            var depth = 0
            while k >= 0 {
                if text[k] == 41 { depth += 1 } else if text[k] == 40 { depth -= 1; if depth == 0 { break } }
                k -= 1
            }
            k -= 1
        }
        var start = k
        while start >= 0 && (isWord(text[start]) || text[start] == 46) { start -= 1 }
        return slice(text, start + 1, k + 1)
    }

    /// End of a call: its arguments, trailing closures and modifiers.
    private static func expressionEnd(from start: Int, in text: [UInt16]) -> Int {
        var j = start
        while j < text.count && text[j] != 40 && text[j] != 123 { j += 1 }
        return modifiersEnd(after: closing(j, in: text) + 1, in: text)
    }

    /// End of the trailing closures and `.modifier(...)` chain from `offset`.
    private static func modifiersEnd(after offset: Int, in text: [UInt16]) -> Int {
        var j = offset
        while true {
            var k = j
            while k < text.count && isSpace(text[k]) { k += 1 }
            guard k < text.count else { return j }
            if text[k] == 123 { j = closing(k, in: text) + 1; continue }
            if isWord(text[k]) {
                // A labelled trailing closure: `label: { ... }`.
                var w = k; while w < text.count && isWord(text[w]) { w += 1 }
                var c = w; while c < text.count && isSpace(text[c]) { c += 1 }
                if c < text.count && text[c] == 58 {
                    var b = c + 1; while b < text.count && isSpace(text[b]) { b += 1 }
                    if b < text.count && text[b] == 123 { j = closing(b, in: text) + 1; continue }
                }
                return j
            }
            if text[k] == 46 {
                var w = k + 1; while w < text.count && isWord(text[w]) { w += 1 }
                j = w
                var b = w; while b < text.count && (text[b] == 32 || text[b] == 9) { b += 1 }
                if b < text.count && (text[b] == 40 || text[b] == 123) { j = closing(b, in: text) + 1 }
                continue
            }
            return j
        }
    }

    /// The view and modifiers a `.onTapGesture` at `offset` belongs to: the
    /// lines of modifiers above it, the line of the view and the rest of
    /// the chain.
    private static func statement(around offset: Int, in text: [UInt16]) -> String {
        var lineStart = offset
        while lineStart > 0 && text[lineStart - 1] != 10 { lineStart -= 1 }
        while lineStart > 0 {
            var previous = lineStart - 1
            while previous > 0 && text[previous - 1] != 10 { previous -= 1 }
            let current = slice(text, lineStart, offset).trimmingCharacters(in: .whitespaces)
            guard current.isEmpty || current.hasPrefix(".") else { break }
            lineStart = previous
        }
        return slice(text, lineStart, expressionEnd(from: offset, in: text))
    }
}
