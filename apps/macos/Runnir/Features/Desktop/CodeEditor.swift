import AppKit
import SwiftUI

/// One replacement the editor applies as a single undoable change, as
/// typing would, when its text is still `before`.
struct CodeEditorEdit: Equatable, Sendable {
    let id: Int
    let before: String
    /// UTF-16 range in `before`.
    let range: NSRange
    let replacement: String

    /// The replacement that turns `before` into `after`: what lies between
    /// their common start and common end. nil when they are equal.
    init?(from before: String, to after: String, id: Int) {
        guard before != after else { return nil }
        let old = Array(before.utf16), new = Array(after.utf16)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        self.id = id
        self.before = before
        range = NSRange(location: prefix, length: old.count - prefix - suffix)
        replacement = String(decoding: new[prefix..<(new.count - suffix)], as: UTF16.self)
    }
}

/// The workflow editor: an AppKit text view with line numbers, YAML colors,
/// lines with diagnostics marked, and the usual Mac editing (undo, find).
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    /// 1-based lines with diagnostics.
    var flaggedLines: Set<Int>
    /// A line chosen from the diagnostics; shown and scrolled to when
    /// `revealCount` changes.
    var highlightedLine: Int?
    var revealCount: Int
    var isEditable: Bool
    /// An edit to apply once, undoable (the concurrency block).
    var edit: CodeEditorEdit? = nil

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    /// UTF-16 offsets where each line starts. A line break always starts
    /// another line, so text ending with one has an empty last line.
    nonisolated static func lineStarts(of string: NSString) -> [Int] {
        var starts = [0]
        var index = 0
        while index < string.length {
            var lineEnd = 0, contentsEnd = 0
            string.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: index, length: 0))
            guard lineEnd > index else { break }
            if contentsEnd < lineEnd { starts.append(lineEnd) }
            index = lineEnd
        }
        return starts
    }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width, .height]
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.font = Coordinator.font
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.backgroundColor = RunnirColorToken.editor.nsColor
        textView.textColor = RunnirColorToken.foreground.nsColor
        textView.insertionPointColor = RunnirColorToken.foreground.nsColor
        textView.typingAttributes = Coordinator.plainAttributes
        textView.setAccessibilityLabel("Workflow source")
        textView.delegate = context.coordinator
        storage.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = RunnirColorToken.editor.nsColor
        let ruler = LineNumberRuler(textView: textView, coordinator: context.coordinator)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.load(text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        guard let textView = coordinator.textView else { return }
        textView.isEditable = isEditable
        if let edit, edit.id != coordinator.appliedEdit, textView.string == edit.before {
            coordinator.appliedEdit = edit.id
            // After this update: the change sets the binding.
            Task { @MainActor in coordinator.apply(edit) }
        } else if textView.string != text {
            // A new file or a reload from disk, not an edit.
            coordinator.load(text)
        }
        coordinator.mark(flagged: flaggedLines, highlighted: highlightedLine)
        if revealCount != coordinator.revealCount {
            coordinator.revealCount = revealCount
            if let line = highlightedLine { coordinator.reveal(line: line) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        static let plainAttributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: RunnirColorToken.foreground.nsColor,
        ]

        var text: Binding<String>
        weak var textView: NSTextView?
        weak var ruler: LineNumberRuler?
        var revealCount = 0
        /// UTF-16 offsets where each line starts.
        private(set) var lineStarts: [Int] = [0]
        private(set) var flagged: Set<Int> = []
        private var highlighted: Int?
        private var loading = false

        /// The last edit applied, so each one is applied once.
        var appliedEdit = 0

        /// Replaces text as one undoable change, as typing would; the
        /// delegate then updates the binding.
        func apply(_ edit: CodeEditorEdit) {
            guard let textView, textView.string == edit.before,
                  textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
            textView.textStorage?.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.replacement, attributes: Self.plainAttributes))
            textView.didChangeText()
            textView.undoManager?.setActionName("Add Concurrency")
        }

        init(text: Binding<String>) { self.text = text }

        func load(_ value: String) {
            guard let textView, let storage = textView.textStorage else { return }
            loading = true
            storage.setAttributedString(NSAttributedString(string: value, attributes: Self.plainAttributes))
            loading = false
            textView.undoManager?.removeAllActions()
            recountLines()
            color(NSRange(location: 0, length: storage.length), startsEditing: true)
            applyMarks()
            ruler?.needsDisplay = true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text.wrappedValue = textView.string
            recountLines()
            applyMarks()
            ruler?.needsDisplay = true
        }

        // Colors are set while the storage processes the edit, so the new
        // text never shows uncolored; attributes may change here.
        nonisolated func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                                     range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated { recolor(around: editedRange) }
        }

        private func recolor(around editedRange: NSRange) {
            guard !loading, let storage = textView?.textStorage else { return }
            let range = (storage.string as NSString).lineRange(for: editedRange)
            color(range, startsEditing: false)
        }

        /// The 1-based line that contains a UTF-16 offset.
        func line(at offset: Int) -> Int {
            var low = 0, high = lineStarts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
            }
            return low + 1
        }

        func range(ofLine line: Int) -> NSRange? {
            guard let storage = textView?.textStorage, line >= 1, line <= lineStarts.count else { return nil }
            let start = lineStarts[line - 1]
            let end = line < lineStarts.count ? lineStarts[line] : storage.length
            return NSRange(location: start, length: max(0, end - start))
        }

        func mark(flagged: Set<Int>, highlighted: Int?) {
            guard flagged != self.flagged || highlighted != self.highlighted else { return }
            self.flagged = flagged
            self.highlighted = highlighted
            applyMarks()
            ruler?.needsDisplay = true
        }

        func reveal(line: Int) {
            guard let textView, let range = range(ofLine: line) else { return }
            textView.scrollRangeToVisible(range)
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
        }

        private func recountLines() {
            lineStarts = CodeEditor.lineStarts(of: (textView?.string ?? "") as NSString)
        }

        /// Recolors whole lines. During the storage's own processing of an
        /// edit the changes join that edit, so `startsEditing` is false.
        private func color(_ range: NSRange, startsEditing: Bool) {
            guard let storage = textView?.textStorage, range.length > 0 else { return }
            let string = storage.string as NSString
            if startsEditing { storage.beginEditing() }
            storage.addAttributes(Self.plainAttributes, range: range)
            var index = range.location
            while index < NSMaxRange(range) {
                let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
                let line = string.substring(with: lineRange)
                for (tokenRange, token) in YAMLSyntaxHighlighting.tokens(in: line) {
                    storage.addAttribute(.foregroundColor, value: token.colorToken.nsColor,
                                         range: NSRange(location: lineRange.location + tokenRange.location, length: tokenRange.length))
                }
                index = NSMaxRange(lineRange)
                if lineRange.length == 0 { break }
            }
            if startsEditing { storage.endEditing() }
        }

        private func applyMarks() {
            guard let textView, let layout = textView.layoutManager, let storage = textView.textStorage else { return }
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
            let destructive = RunnirColorToken.destructive.nsColor
            for line in flagged.union(highlighted.map { [$0] } ?? []) {
                guard let range = range(ofLine: line), range.length > 0 else { continue }
                let alpha = line == highlighted ? 0.22 : 0.10
                layout.addTemporaryAttribute(.backgroundColor, value: destructive.withAlphaComponent(alpha), forCharacterRange: range)
            }
        }
    }
}

/// Line numbers beside the editor; lines with diagnostics are numbered in red.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private weak var coordinator: CodeEditor.Coordinator?

    init(textView: NSTextView, coordinator: CodeEditor.Coordinator) {
        self.textView = textView
        self.coordinator = coordinator
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        setAccessibilityHidden(true)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let coordinator, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        RunnirColorToken.editor.nsColor.setFill()
        bounds.fill()

        let lineCount = coordinator.lineStarts.count
        let digits = max(2, String(lineCount).count)
        let width = CGFloat(digits) * 7.5 + 16
        if abs(ruleThickness - width) > 0.5 { ruleThickness = width }

        let string = textView.string as NSString
        let visible = textView.visibleRect
        // The ruler can draw before the text view has laid out new text;
        // without this only the first line would get a number.
        layout.ensureLayout(forBoundingRect: visible, in: container)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let inset = textView.textContainerInset.height

        func draw(_ number: Int, atY y: CGFloat, height: CGFloat) {
            let flagged = coordinator.flagged.contains(number)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: (flagged ? RunnirColorToken.destructive : RunnirColorToken.mutedForeground).nsColor,
            ]
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            let point = convert(NSPoint(x: 0, y: y + inset), from: textView)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: point.y + (height - size.height) / 2), withAttributes: attributes)
        }

        var index = characters.location
        var number = coordinator.line(at: index)
        while index <= NSMaxRange(characters), index < string.length {
            let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: lineRange.location)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            draw(number, atY: fragment.minY, height: fragment.height)
            number += 1
            index = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
        // The empty line after a final newline, or an empty file.
        if index >= string.length, number == lineCount {
            let extra = layout.extraLineFragmentRect
            let height = extra.height > 0 ? extra.height : layout.defaultLineHeight(for: CodeEditor.Coordinator.font)
            draw(number, atY: extra.height > 0 ? extra.minY : 0, height: height)
        }
    }
}
