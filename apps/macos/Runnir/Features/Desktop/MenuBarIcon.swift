import AppKit

/// The menu bar item's image (S19): the glyph cut from the logo mark, with a
/// colored dot for pull request checks and the user's runs, and the build's
/// word in a capsule after it on a build other than a release (B47). The plain
/// glyph is a template that macOS tints; otherwise the image draws in the menu
/// bar's text color itself, since a template cannot carry a color.
enum MenuBarIcon {
    enum Badge: Equatable {
        case none
        /// A check of an open pull request or one of the user's runs failed.
        case failed
        /// Checks or runs are running.
        case running
    }

    static let failedColor = NSColor(srgbRed: 0.949, green: 0.373, blue: 0.361, alpha: 1)
    static let runningColor = NSColor(srgbRed: 0.176, green: 0.831, blue: 0.749, alpha: 1)

    /// The glyph alone, as macOS draws it in light and dark menu bars.
    static var glyph: NSImage {
        let image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        return image
    }

    static func badge(for ci: CorePullRequestCI?) -> Badge {
        switch ci {
        case .failed: .failed
        case .running: .running
        default: .none
        }
    }

    /// The worse of the pull request checks and the watched runs (B39).
    static func badge(for ci: CorePullRequestCI?, runs: Badge) -> Badge {
        let checks = badge(for: ci)
        if checks == .failed || runs == .failed { return .failed }
        if checks == .running || runs == .running { return .running }
        return .none
    }

    /// "Runnir Beta, a run failed, checks running": what the icon stands for.
    static func accessibilityLabel(checks ci: CorePullRequestCI?, runs: Badge, build: RunnirBuild = .current) -> String {
        var parts = [build.spokenName]
        switch runs {
        case .failed: parts.append("a run failed")
        case .running: parts.append("runs in progress")
        case .none: break
        }
        switch badge(for: ci) {
        case .failed: parts.append("a check failed")
        case .running: parts.append("checks running")
        case .none: break
        }
        return parts.joined(separator: ", ")
    }

    /// The space between the glyph's area and the build's capsule.
    static let markGap: CGFloat = 2
    /// The height of the build's capsule.
    static let markHeight: CGFloat = 11
    private static let markPadding: CGFloat = 3
    private static var markAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 7.5, weight: .bold), .kern: 0.4, .foregroundColor: NSColor.black]
    }

    /// The width of the capsule holding `mark`.
    static func markWidth(_ mark: String) -> CGFloat {
        ceil((mark as NSString).size(withAttributes: markAttributes).width) + 2 * markPadding
    }

    /// The image for a state; `dimmed` when no account is signed in.
    static func image(badge: Badge, dimmed: Bool, build: RunnirBuild = .current) -> NSImage {
        let base = glyph
        let mark = build.mark
        guard badge != .none || dimmed || mark != nil else { return base }
        let dot: NSColor? = switch badge {
        case .failed: failedColor
        case .running: runningColor
        case .none: nil
        }
        // The glyph's area, as wide as the dot needs; the capsule follows it.
        let area = NSSize(width: max(base.size.width, 21), height: max(base.size.height, 18))
        let capsuleWidth = mark.map(markWidth) ?? 0
        let size = NSSize(width: area.width + (mark == nil ? 0 : markGap + capsuleWidth), height: area.height)
        let image = NSImage(size: size, flipped: true) { rect in
            // The glyph in the menu bar's text color, drawn for the current
            // appearance each time the item is drawn.
            let glyphRect = NSRect(origin: .zero, size: base.size)
            NSGraphicsContext.saveGraphicsState()
            // The drawing is flipped; without respectFlipped the glyph comes out upside down.
            base.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: dimmed ? 0.45 : 1,
                      respectFlipped: true, hints: nil)
            NSColor.labelColor.set()
            glyphRect.fill(using: .sourceAtop)
            NSGraphicsContext.restoreGraphicsState()
            if let dot {
                let dotRect = NSRect(x: area.width - 7.5, y: area.height - 7, width: 7, height: 7)
                // A ring of clear space keeps the dot apart from the ring.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.5, dy: -1.5)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                dot.set()
                NSBezierPath(ovalIn: dotRect).fill()
            }
            if let mark {
                // The capsule in the text color with the word cut out, so it
                // reads on any menu bar and leaves color to the dot.
                let capsule = NSRect(x: area.width + Self.markGap, y: (rect.height - Self.markHeight) / 2,
                                     width: capsuleWidth, height: Self.markHeight)
                NSGraphicsContext.saveGraphicsState()
                NSColor.labelColor.withAlphaComponent(dimmed ? 0.45 : 1).set()
                NSBezierPath(roundedRect: capsule, xRadius: 3, yRadius: 3).fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                let text = (mark as NSString).size(withAttributes: Self.markAttributes)
                (mark as NSString).draw(at: NSPoint(x: capsule.midX - text.width / 2, y: capsule.midY - text.height / 2),
                                        withAttributes: Self.markAttributes)
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
