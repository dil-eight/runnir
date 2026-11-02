// Renders the macOS app icon sets from the brand mark in docs/design/assets.
// The mark and the tile color come from the "Brand" frames in runnir.pen; the
// pills naming a build (B47) from "S19 / Menu bar icon / Build marks".
//
// Usage: swift scripts/make-app-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let markURL = root.appendingPathComponent("docs/design/assets/logo-mark-light.png")
let catalog = root.appendingPathComponent("apps/macos/Runnir/Assets.xcassets")

guard let mark = NSImage(contentsOf: markURL),
      let markImage = mark.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fatalError("cannot read \(markURL.path)") }

func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The word and color of the pill on a build other than a release.
struct BuildMark { let word: String; let color: UInt32 }

let sets: [(name: String, mark: BuildMark?)] = [
    ("AppIcon", nil),
    ("AppIcon-Dev", BuildMark(word: "DEV", color: 0xFBBF24)),
    ("AppIcon-Alpha", BuildMark(word: "ALPHA", color: 0xA78BFA)),
    ("AppIcon-Beta", BuildMark(word: "BETA", color: 0x7C9CFF)),
]

// Apple's macOS icon grid on a 1024 canvas: an 824 pt rounded tile, inset 100 pt.
func render(size: Int, buildMark: BuildMark?) -> Data {
    let scale = CGFloat(size) / 1024
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: srgb(0x000000, alpha: 0.35))
    context.addPath(path)
    context.setFillColor(srgb(0x14161A))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [srgb(0x22252B), srgb(0x14161A), srgb(0x0E0F12)] as CFArray,
                              locations: [0, 0.55, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY), options: [])
    context.restoreGState()

    context.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 183.5, cornerHeight: 183.5, transform: nil))
    context.setStrokeColor(srgb(0xFFFFFF, alpha: 0.10))
    context.setLineWidth(3)
    context.strokePath()

    let markWidth: CGFloat = 580
    let markHeight = markWidth * CGFloat(markImage.height) / CGFloat(markImage.width)
    context.draw(markImage, in: CGRect(x: 512 - markWidth / 2, y: 512 - markHeight / 2, width: markWidth, height: markHeight))

    if let buildMark {
        // A pill inside the tile's lower edge naming the build: 170 high,
        // its lower edge 40 above the tile's, outlined to stand off the mark.
        // It stays within the tile: macOS puts an icon whose shape leaves the
        // rounded tile on a plain backing tile.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 112, weight: .heavy), .kern: 6,
            .foregroundColor: NSColor(cgColor: srgb(0x14161A))!,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: buildMark.word, attributes: attributes))
        let text = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let pill = CGRect(x: 512 - (text.width + 120) / 2, y: 140, width: text.width + 120, height: 170)
        context.addPath(CGPath(roundedRect: pill.insetBy(dx: -14, dy: -14), cornerWidth: 99, cornerHeight: 99, transform: nil))
        context.setFillColor(srgb(0x0E0F12))
        context.fillPath()
        context.addPath(CGPath(roundedRect: pill, cornerWidth: 85, cornerHeight: 85, transform: nil))
        context.setFillColor(srgb(buildMark.color))
        context.fillPath()
        context.textPosition = CGPoint(x: pill.midX - text.width / 2 - text.minX, y: pill.midY - text.height / 2 - text.minY)
        CTLineDraw(line, context)
    }

    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

struct Entry { let points: Int; let scale: Int }
let entries = [16, 32, 128, 256, 512].flatMap { [Entry(points: $0, scale: 1), Entry(points: $0, scale: 2)] }

for set in sets {
    let iconSet = catalog.appendingPathComponent("\(set.name).appiconset")
    try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
    var images: [String] = []
    for entry in entries {
        let name = "icon_\(entry.points)x\(entry.points)\(entry.scale == 2 ? "@2x" : "").png"
        try render(size: entry.points * entry.scale, buildMark: set.mark).write(to: iconSet.appendingPathComponent(name))
        images.append("""
            {
              "filename" : "\(name)",
              "idiom" : "mac",
              "scale" : "\(entry.scale)x",
              "size" : "\(entry.points)x\(entry.points)"
            }
        """)
    }
    let contents = """
    {
      "images" : [
    \(images.joined(separator: ",\n"))
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
    try contents.write(to: iconSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    print("wrote \(entries.count) images to \(iconSet.path)")
}
try """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

""".write(to: catalog.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
