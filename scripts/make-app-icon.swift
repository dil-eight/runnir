// Renders the macOS app icon set from the brand mark in docs/design/assets.
// The mark and the tile color come from the "Brand" frames in runnir.pen.
//
// Usage: swift scripts/make-app-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let markURL = root.appendingPathComponent("docs/design/assets/logo-mark-light.png")
let iconSet = root.appendingPathComponent("apps/macos/Runnir/Assets.xcassets/AppIcon.appiconset")

guard let mark = NSImage(contentsOf: markURL),
      let markImage = mark.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fatalError("cannot read \(markURL.path)") }

func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Apple's macOS icon grid on a 1024 canvas: an 824 pt rounded tile, inset 100 pt.
func render(size: Int) -> Data {
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

    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

struct Entry { let points: Int; let scale: Int }
let entries = [16, 32, 128, 256, 512].flatMap { [Entry(points: $0, scale: 1), Entry(points: $0, scale: 2)] }

try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
var images: [String] = []
for entry in entries {
    let name = "icon_\(entry.points)x\(entry.points)\(entry.scale == 2 ? "@2x" : "").png"
    try render(size: entry.points * entry.scale).write(to: iconSet.appendingPathComponent(name))
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
try """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

""".write(to: iconSet.deletingLastPathComponent().appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(entries.count) images to \(iconSet.path)")
