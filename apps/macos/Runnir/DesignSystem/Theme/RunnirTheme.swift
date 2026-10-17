import SwiftUI
import AppKit

enum RunnirPalette: UInt32, Sendable {
    case white = 0xFFFFFF
    case neutral25 = 0xFBFBFC
    case neutral50 = 0xF5F6F8
    case neutral100 = 0xEBEDF1
    case neutral200 = 0xD8DCE3
    case neutral400 = 0x9AA3AF
    case neutral500 = 0x69727E
    case neutral550 = 0x626B77
    case neutral600 = 0x5B6471
    case neutral700 = 0x2A2F37
    case neutral750 = 0x262B33
    case neutral800 = 0x1F2329
    case neutral850 = 0x1A1D22
    case neutral900 = 0x181B20
    case neutral950 = 0x14161A
    case neutral975 = 0x101216
    case neutralForeground = 0xECEEF1
    case blue100 = 0xE3E9FB
    case blue400 = 0x7C9CFF
    case blue600 = 0x3D63DD
    case green400 = 0x4ADE80
    case green700 = 0x15803D
    case amber400 = 0xFBBF24
    case amber700 = 0xA16207
    case red400 = 0xF87171
    case red700 = 0xB91C1C

    var nsColor: NSColor {
        NSColor(srgbRed: Double((rawValue >> 16) & 255) / 255,
                green: Double((rawValue >> 8) & 255) / 255,
                blue: Double(rawValue & 255) / 255, alpha: 1)
    }
}

enum RunnirColorToken: String, CaseIterable, Sendable {
    case background, sidebar, surface, selected, editor
    case foreground, secondaryForeground, mutedForeground, border
    case primary, primaryForeground, secondary, secondaryContent
    case success, warning, destructive, info, focusRing
    case syntaxKey, syntaxString, syntaxLiteral

    var palette: (light: RunnirPalette, dark: RunnirPalette) {
        switch self {
        case .background: (.white, .neutral900)
        case .sidebar: (.neutral100, .neutral850)
        case .surface, .secondary: (.neutral50, .neutral800)
        case .selected: (.blue100, .neutral750)
        case .editor: (.neutral25, .neutral975)
        case .foreground, .secondaryContent: (.neutral950, .neutralForeground)
        case .secondaryForeground: (.neutral600, .neutral400)
        case .mutedForeground: (.neutral550, .neutral500)
        case .border: (.neutral200, .neutral700)
        case .primary, .info, .focusRing, .syntaxKey: (.blue600, .blue400)
        case .primaryForeground: (.white, .neutral950)
        case .success, .syntaxString: (.green700, .green400)
        case .warning, .syntaxLiteral: (.amber700, .amber400)
        case .destructive: (.red700, .red400)
        }
    }

    func resolved(for appearance: NSAppearance) -> NSColor {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return (isDark ? palette.dark : palette.light).nsColor
    }

    var color: Color {
        Color(nsColor: NSColor(name: NSColor.Name("runnir.\(rawValue)")) { appearance in
            resolved(for: appearance)
        })
    }
}

enum RunnirTheme {
    static let contentPadding: CGFloat = 24
    static let background = RunnirColorToken.background.color
    static let sidebar = RunnirColorToken.sidebar.color
    static let surface = RunnirColorToken.surface.color
    static let selected = RunnirColorToken.selected.color
    static let editor = RunnirColorToken.editor.color
    static let foreground = RunnirColorToken.foreground.color
    static let secondaryForeground = RunnirColorToken.secondaryForeground.color
    static let mutedForeground = RunnirColorToken.mutedForeground.color
    static let border = RunnirColorToken.border.color
    static let primary = RunnirColorToken.primary.color
    static let primaryForeground = RunnirColorToken.primaryForeground.color
    static let secondary = RunnirColorToken.secondary.color
    static let secondaryContent = RunnirColorToken.secondaryContent.color
    static let success = RunnirColorToken.success.color
    static let warning = RunnirColorToken.warning.color
    static let destructive = RunnirColorToken.destructive.color
    static let info = RunnirColorToken.info.color
    static let focusRing = RunnirColorToken.focusRing.color
    static let syntaxKey = RunnirColorToken.syntaxKey.color
    static let syntaxString = RunnirColorToken.syntaxString.color
    static let syntaxLiteral = RunnirColorToken.syntaxLiteral.color
}

#if DEBUG
private struct ColorTokenCatalog: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(RunnirColorToken.allCases, id: \.self) { token in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 4).fill(token.color).frame(width: 44, height: 28)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(RunnirTheme.border))
                        Text(token.rawValue).font(.system(size: 13, design: .monospaced))
                        Spacer()
                    }
                }
            }.padding(24)
        }
        .foregroundStyle(RunnirTheme.foreground).background(RunnirTheme.background)
        .frame(width: 400, height: 640)
    }
}

#Preview("Color tokens / Light") {
    ColorTokenCatalog().preferredColorScheme(.light)
}

#Preview("Color tokens / Dark") {
    ColorTokenCatalog().preferredColorScheme(.dark)
}
#endif
