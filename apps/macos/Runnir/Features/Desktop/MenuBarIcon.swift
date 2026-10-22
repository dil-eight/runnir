import AppKit

/// The menu bar item's image (S19): the glyph cut from the logo mark, with a
/// colored dot for pull request checks. The plain glyph is a template that
/// macOS tints; with a dot the image draws the glyph in the menu bar's text
/// color itself, since a template cannot carry a color.
enum MenuBarIcon {
    enum Badge: Equatable {
        case none
        /// A check of an open pull request failed.
        case failed
        /// Checks are running.
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

    /// The image for a state; `dimmed` when no account is signed in.
    static func image(badge: Badge, dimmed: Bool) -> NSImage {
        let base = glyph
        guard badge != .none || dimmed else { return base }
        let dot: NSColor? = switch badge {
        case .failed: failedColor
        case .running: runningColor
        case .none: nil
        }
        let size = NSSize(width: max(base.size.width, 21), height: max(base.size.height, 18))
        let image = NSImage(size: size, flipped: true) { rect in
            // The glyph in the menu bar's text color, drawn for the current
            // appearance each time the item is drawn.
            let glyphRect = NSRect(origin: .zero, size: base.size)
            NSGraphicsContext.saveGraphicsState()
            base.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: dimmed ? 0.45 : 1)
            NSColor.labelColor.set()
            glyphRect.fill(using: .sourceAtop)
            NSGraphicsContext.restoreGraphicsState()
            if let dot {
                let dotRect = NSRect(x: rect.maxX - 7.5, y: rect.maxY - 7, width: 7, height: 7)
                // A ring of clear space keeps the dot apart from the ring.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.5, dy: -1.5)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                dot.set()
                NSBezierPath(ovalIn: dotRect).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
