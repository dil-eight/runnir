# Build Marks (B47) Implementation Plan

> Executed on 2026-11-01. On 2026-11-04 every name below moved from `io.dil8.runnir` to `com.runnir`, runnir.com's domain ([spec](../specs/2026-11-01-build-marks-design.md)); the plan keeps the names it was written with.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tell release, alpha, beta and dev builds of Runnir apart by their app icon and menu bar icon, make dev a separate app (Runnir Dev) with its own data, and name everything under `io.dil8.runnir`.

**Architecture:** One build setting, `RUNNIR_BUILD` (`dev` unless the release workflow passes another), drives the bundle ID, display name and app icon set in Xcode and lands in Info.plist as `RunnirBuild`. The app reads it once (`RunnirBuild.current`) and derives its folders, Keychain services and menu bar capsule from it. The Core gains `serve --cache-dir` so two Cores never share act's cache.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Swift Testing; Go (Core CLI and local runs); GitHub Actions; a Swift script for the icon sets.

**Spec:** `docs/superpowers/specs/2026-11-01-build-marks-design.md`. **Branch:** `dilbarov/build-marks`.

## Global Constraints

- Builds: `release`, `alpha`, `beta`, `dev`. Tag `v1.2.3` is release, `v1.2.3-alpha.N` alpha, `v1.2.3-beta.N` beta; any other tag fails the release workflow. Everything built without a tag is dev.
- Bundle IDs: `io.dil8.runnir` for release, alpha and beta; `io.dil8.runnir.dev` for dev; tests `io.dil8.runnir.tests` and `io.dil8.runnir.uitests`. Display name `Runnir`, or `Runnir Dev` for dev.
- Every reverse-DNS name is under `io.dil8.runnir`; no `com.dileight` or `dev.runnir` name stays in code.
- Folders: `Runnir`, or `Runnir Dev` for dev, in Application Support, Logs and Caches.
- Keychain prefix: `io.dil8.runnir`, or `io.dil8.runnir.dev` for dev.
- App icon pill colors: DEV `#FBBF24`, ALPHA `#A78BFA`, BETA `#7C9CFF`. The menu bar capsule is monochrome (the menu bar's text color, the word cut out); the CI dot keeps its place on the glyph's corner.
- No migration of earlier data, no fallback to earlier names (AGENTS.md: no backward compatibility before the first release tag).
- No new dependencies. Never add AI attribution to commits, docs or PRs.
- Xcode builds need Go 1.27.3 first on PATH: `export PATH="$HOME/go/pkg/mod/golang.org/toolchain@v0.0.1-go1.27.3.darwin-arm64/bin:$PATH"`.

## File Structure

| File | Change | Responsibility |
| --- | --- | --- |
| `scripts/make-app-icon.swift` | Modify | Renders `AppIcon`, `AppIcon-Dev`, `AppIcon-Alpha`, `AppIcon-Beta` |
| `apps/macos/Runnir/Assets.xcassets/AppIcon-{Dev,Alpha,Beta}.appiconset/` | Create (generated) | The marked icon sets |
| `apps/macos/Runnir/Info.plist` | Create | Partial Info.plist: `RunnirBuild = $(RUNNIR_BUILD)` |
| `apps/macos/Runnir/App/RunnirBuild.swift` | Create | `enum RunnirBuild`: the build and the names it implies |
| `apps/macos/Runnir.xcodeproj/project.pbxproj` | Modify | Build settings, bundle IDs, new files |
| `apps/macos/RunnirTests/RunnirBuildTests.swift` | Create | Tests of the build and the names it implies |
| `core/cmd/runnir/main.go`, `main_test.go` | Modify | `serve --cache-dir` |
| `core/internal/localrun/runner.go`, `runner_test.go` | Modify | Container label `io.dil8.runnir.execution` |
| `apps/macos/Runnir/App/Desktop/DesktopStateStore.swift` | Modify | `RunnirSupportDirectory.url(build:)` |
| `apps/macos/Runnir/IPC/CoreProcessSupervisor.swift` | Modify | Log and cache folders by build |
| `apps/macos/Runnir/IPC/ProcessCoreLauncher.swift` | Modify | Passes `--cache-dir` |
| `apps/macos/Runnir/Core/Security/KeychainCredentialStore.swift` | Modify | `service(for:)` |
| `apps/macos/Runnir/Core/Security/LocalRunValueStore.swift` | Modify | `prefix(for:)`, notification name |
| `apps/macos/Runnir/Features/Desktop/RunNotifications.swift` | Modify | Category and action IDs |
| `apps/macos/Runnir/Features/Desktop/MenuBarIcon.swift` | Modify | The capsule and the spoken name |
| `apps/macos/RunnirTests/{WorkspaceCacheTests,LocalRunValuesTests,PullRequestsTests,WatchedRunsTests}.swift` | Modify | Tests for the above |
| `scripts/check-app-build.sh` | Create | Checks a built app's bundle ID, build and icon set |
| `.github/workflows/release.yml`, `app-build.yml` | Modify | Pass and check the build |
| `README.md`, `docs/architecture/{grpc-api,github-enterprise,workspace-persistence}.md`, `docs/security/github-authentication.md`, `docs/decisions/0005-developer-id-without-app-sandbox.md`, `docs/product/mvp-implementation-checklist.md`, the spec | Modify | Current names and folders, B47 built |

---

### Task 1: The marked app icon sets

**Files:**
- Modify: `scripts/make-app-icon.swift`
- Create (generated): `apps/macos/Runnir/Assets.xcassets/AppIcon-Dev.appiconset/`, `AppIcon-Alpha.appiconset/`, `AppIcon-Beta.appiconset/`

**Interfaces:**
- Produces: icon sets named `AppIcon`, `AppIcon-Dev`, `AppIcon-Alpha`, `AppIcon-Beta` in `Assets.xcassets` (Task 2 selects one by name).

- [ ] **Step 1: Rewrite the script to render four sets**

Replace the whole of `scripts/make-app-icon.swift` with:

```swift
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
        // A pill on the tile's lower edge naming the build: 180 high, its
        // lower edge 70 above the canvas's, outlined to stand off the tile.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 112, weight: .heavy), .kern: 6,
            .foregroundColor: NSColor(cgColor: srgb(0x14161A))!,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: buildMark.word, attributes: attributes))
        let text = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let pill = CGRect(x: 512 - (text.width + 120) / 2, y: 70, width: text.width + 120, height: 180)
        context.addPath(CGPath(roundedRect: pill.insetBy(dx: -14, dy: -14), cornerWidth: 104, cornerHeight: 104, transform: nil))
        context.setFillColor(srgb(0x0E0F12))
        context.fillPath()
        context.addPath(CGPath(roundedRect: pill, cornerWidth: 90, cornerHeight: 90, transform: nil))
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
```

- [ ] **Step 2: Render the sets**

Run: `swift scripts/make-app-icon.swift`
Expected: four `wrote 10 images to …` lines (AppIcon, AppIcon-Dev, AppIcon-Alpha, AppIcon-Beta).

- [ ] **Step 3: Check the result**

Run: `git status --short apps/macos/Runnir/Assets.xcassets && git diff --stat apps/macos/Runnir/Assets.xcassets/AppIcon.appiconset`
Expected: three new `AppIcon-*.appiconset` folders. `AppIcon.appiconset` should be unchanged; if its PNG bytes differ, open `icon_512x512@2x.png` from both versions and confirm they look the same.

Open `apps/macos/Runnir/Assets.xcassets/AppIcon-Beta.appiconset/icon_512x512@2x.png` and `…/icon_32x32.png`: the pill reads BETA on blue at the lower edge, the outline separates it from the tile.

- [ ] **Step 4: Commit**

```bash
git add scripts/make-app-icon.swift apps/macos/Runnir/Assets.xcassets
git commit -m "App: icon sets for dev, alpha and beta builds (B47)"
```

---

### Task 2: The build setting, Info.plist and `RunnirBuild`

**Files:**
- Create: `apps/macos/Runnir/Info.plist`
- Create: `apps/macos/Runnir/App/RunnirBuild.swift`
- Create: `apps/macos/RunnirTests/RunnirBuildTests.swift`
- Modify: `apps/macos/Runnir.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: the icon sets of Task 1.
- Produces: `enum RunnirBuild: String, CaseIterable, Sendable { case dev, alpha, beta, release }` with `static let current: RunnirBuild`, `init(infoValue: String?)`, `var mark: String?`, `var spokenName: String`, `var folderName: String`, `var keychainPrefix: String`. Built app: `CFBundleIdentifier` `io.dil8.runnir.dev`, `CFBundleDisplayName` `Runnir Dev`, `RunnirBuild` `dev`, `CFBundleIconName` `AppIcon-Dev` unless `RUNNIR_BUILD` is passed.

- [ ] **Step 1: Write the failing tests**

Create `apps/macos/RunnirTests/RunnirBuildTests.swift`:

```swift
import Foundation
import Testing
@testable import Runnir

@Suite struct RunnirBuildTests {
    @Test func theInfoValueNamesTheBuildAndAnythingElseIsDev() {
        #expect(RunnirBuild(infoValue: "release") == .release)
        #expect(RunnirBuild(infoValue: "alpha") == .alpha)
        #expect(RunnirBuild(infoValue: "beta") == .beta)
        #expect(RunnirBuild(infoValue: "dev") == .dev)
        #expect(RunnirBuild(infoValue: nil) == .dev, "a build that lost the key is not taken for a release")
        #expect(RunnirBuild(infoValue: "$(RUNNIR_BUILD)") == .dev)
        #expect(RunnirBuild(infoValue: "Release") == .dev)
    }

    @Test func eachBuildNamesItself() {
        #expect(RunnirBuild.allCases.map(\.mark) == ["DEV", "ALPHA", "BETA", nil])
        #expect(RunnirBuild.allCases.map(\.spokenName) == ["Runnir Dev", "Runnir Alpha", "Runnir Beta", "Runnir"])
        #expect(RunnirBuild.allCases.map(\.folderName) == ["Runnir Dev", "Runnir", "Runnir", "Runnir"])
        #expect(RunnirBuild.allCases.map(\.keychainPrefix) == ["io.dil8.runnir.dev", "io.dil8.runnir", "io.dil8.runnir", "io.dil8.runnir"])
    }

    @Test func theTestHostIsADevBuild() {
        // The tests run in an app built without a tag: Info.plist carries dev.
        #expect(Bundle.main.object(forInfoDictionaryKey: "RunnirBuild") as? String == "dev")
        #expect(RunnirBuild.current == .dev)
        #expect(Bundle.main.bundleIdentifier == "io.dil8.runnir.dev")
    }
}
```

- [ ] **Step 2: Create the partial Info.plist**

Create `apps/macos/Runnir/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<!-- Merged with the generated Info.plist. RunnirBuild is the build this is
     (B47): dev, alpha, beta or release, from the RUNNIR_BUILD setting. -->
<dict>
	<key>RunnirBuild</key>
	<string>$(RUNNIR_BUILD)</string>
</dict>
</plist>
```

- [ ] **Step 3: Add the build settings and the files to the project**

Run from the repository root:

```bash
python3 - <<'EOF'
p = "apps/macos/Runnir.xcodeproj/project.pbxproj"
s = open(p).read()
def rep(old, new, count):
    global s
    assert s.count(old) == count, (old, s.count(old))
    s = s.replace(old, new)

# The app target, Debug and Release: everything follows RUNNIR_BUILD (B47).
rep("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; ", 'ASSETCATALOG_COMPILER_APPICON_NAME = "$(RUNNIR_APPICON_$(RUNNIR_BUILD))"; ', 2)
rep("INFOPLIST_KEY_CFBundleDisplayName = Runnir; ",
    'INFOPLIST_FILE = Runnir/Info.plist; INFOPLIST_KEY_CFBundleDisplayName = "$(RUNNIR_DISPLAY_NAME_$(RUNNIR_BUILD))"; ', 2)
rep('PRODUCT_BUNDLE_IDENTIFIER = com.dileight.runnir; PRODUCT_NAME = "$(TARGET_NAME)"; SWIFT_EMIT_LOC_STRINGS = YES; ',
    'PRODUCT_BUNDLE_IDENTIFIER = "io.dil8.runnir$(RUNNIR_BUNDLE_SUFFIX_$(RUNNIR_BUILD))"; PRODUCT_NAME = "$(TARGET_NAME)"; '
    'RUNNIR_APPICON_alpha = "AppIcon-Alpha"; RUNNIR_APPICON_beta = "AppIcon-Beta"; RUNNIR_APPICON_dev = "AppIcon-Dev"; RUNNIR_APPICON_release = AppIcon; '
    'RUNNIR_BUILD = dev; RUNNIR_BUNDLE_SUFFIX_dev = .dev; '
    'RUNNIR_DISPLAY_NAME_alpha = Runnir; RUNNIR_DISPLAY_NAME_beta = Runnir; RUNNIR_DISPLAY_NAME_dev = "Runnir Dev"; RUNNIR_DISPLAY_NAME_release = Runnir; '
    'SWIFT_EMIT_LOC_STRINGS = YES; ', 2)
rep("PRODUCT_BUNDLE_IDENTIFIER = com.dileight.runnir.tests;", "PRODUCT_BUNDLE_IDENTIFIER = io.dil8.runnir.tests;", 2)
rep("PRODUCT_BUNDLE_IDENTIFIER = com.dileight.runnir.uitests;", "PRODUCT_BUNDLE_IDENTIFIER = io.dil8.runnir.uitests;", 2)
assert "dileight" not in s

# New files: RunnirBuild.swift (app), RunnirBuildTests.swift (tests), Info.plist (no target).
refs = ('\t\tBB4700000000000000000001 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Runnir/App/RunnirBuild.swift; sourceTree = SOURCE_ROOT; };\n'
        '\t\tBB4700000000000000000002 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RunnirTests/RunnirBuildTests.swift; sourceTree = SOURCE_ROOT; };\n'
        '\t\tBB4700000000000000000003 = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Runnir/Info.plist; sourceTree = SOURCE_ROOT; };\n')
anchor = "\t\tBB3900000000000000000004 = {isa = PBXFileReference;"
i = s.index(anchor); i = s.index("\n", i) + 1
s = s[:i] + refs + s[i:]
builds = ('\t\tBB4700000000000000001001 = {isa = PBXBuildFile; fileRef = BB4700000000000000000001; };\n'
          '\t\tBB4700000000000000001002 = {isa = PBXBuildFile; fileRef = BB4700000000000000000002; };\n')
anchor = "\t\tBB3900000000000000001004 = {isa = PBXBuildFile;"
i = s.index(anchor); i = s.index("\n", i) + 1
s = s[:i] + builds + s[i:]
rep("children = (B00000000000000000000011, ", "children = (BB4700000000000000000001, BB4700000000000000000002, BB4700000000000000000003, B00000000000000000000011, ", 1)
rep("BB3900000000000000001004); runOnlyForDeploymentPostprocessing", "BB3900000000000000001004, BB4700000000000000001001); runOnlyForDeploymentPostprocessing", 1)
rep("BB3900000000000000001003); runOnlyForDeploymentPostprocessing", "BB3900000000000000001003, BB4700000000000000001002); runOnlyForDeploymentPostprocessing", 1)
open(p, "w").write(s)
EOF
```

Expected: no output. The script stops with an `AssertionError` naming the text it did not find if the project has changed; then add the settings to the two `Runnir` target configurations by hand.

- [ ] **Step 4: Run the tests to see them fail**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/RunnirBuildTests 2>&1 | grep -E "error:|TEST (SUCCEEDED|FAILED)"`
Expected: the build fails: `RunnirBuild.swift` does not exist yet (`Build input file cannot be found`), or, once it exists, `cannot find 'RunnirBuild' in scope`.

- [ ] **Step 5: Write `RunnirBuild`**

Create `apps/macos/Runnir/App/RunnirBuild.swift`:

```swift
import Foundation

/// Which build this is (B47): a release, an alpha or beta pre-release from a
/// tag, or a dev build made without one. Xcode writes the RUNNIR_BUILD setting
/// into Info.plist as RunnirBuild. Dev is a separate app, Runnir Dev, with its
/// own data, logs, caches and Keychain items.
enum RunnirBuild: String, CaseIterable, Sendable {
    case dev, alpha, beta, release

    /// This app's build.
    static let current = RunnirBuild(infoValue: Bundle.main.object(forInfoDictionaryKey: "RunnirBuild") as? String)

    /// A missing or unknown value is dev, so a build that lost the key shows
    /// DEV instead of passing for a release.
    init(infoValue: String?) {
        self = infoValue.flatMap(RunnirBuild.init(rawValue:)) ?? .dev
    }

    /// The word on the app icon and in the menu bar; nil for a release.
    var mark: String? { self == .release ? nil : rawValue.uppercased() }

    /// What VoiceOver calls the app: Runnir, Runnir Dev, Runnir Alpha, Runnir Beta.
    var spokenName: String { self == .release ? "Runnir" : "Runnir " + rawValue.capitalized }

    /// The app's folder in Application Support, Logs and Caches.
    var folderName: String { self == .dev ? "Runnir Dev" : "Runnir" }

    /// What the app's Keychain services begin with.
    var keychainPrefix: String { self == .dev ? "io.dil8.runnir.dev" : "io.dil8.runnir" }
}
```

- [ ] **Step 6: Run the tests to see them pass**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/RunnirBuildTests 2>&1 | grep -E "error:|✘|TEST (SUCCEEDED|FAILED)"`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Check what a dev and a beta build carry**

```bash
S=$(mktemp -d)
xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' -derivedDataPath "$S/dev" build >/dev/null
xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' -derivedDataPath "$S/beta" RUNNIR_BUILD=beta build >/dev/null
for b in dev beta; do
  plist="$S/$b/Build/Products/Debug/Runnir.app/Contents/Info.plist"
  for key in CFBundleIdentifier CFBundleDisplayName RunnirBuild CFBundleIconName; do
    printf '%s %s: ' "$b" "$key"; /usr/libexec/PlistBuddy -c "Print :$key" "$plist"
  done
done
```

Expected:
```
dev CFBundleIdentifier: io.dil8.runnir.dev
dev CFBundleDisplayName: Runnir Dev
dev RunnirBuild: dev
dev CFBundleIconName: AppIcon-Dev
beta CFBundleIdentifier: io.dil8.runnir
beta CFBundleDisplayName: Runnir
beta RunnirBuild: beta
beta CFBundleIconName: AppIcon-Beta
```

Also check that only the chosen icon set is in the app: `assetutil --info "$S/beta/Build/Products/Debug/Runnir.app/Contents/Resources/Assets.car" | grep -o '"Name" : "AppIcon[^"]*"' | sort -u` prints only `AppIcon-Beta`.

- [ ] **Step 8: Commit**

```bash
git add apps/macos/Runnir/Info.plist apps/macos/Runnir/App/RunnirBuild.swift apps/macos/RunnirTests/RunnirBuildTests.swift apps/macos/Runnir.xcodeproj/project.pbxproj
git commit -m "App: the build follows RUNNIR_BUILD, dev is Runnir Dev under io.dil8.runnir.dev (B47)"
```

---

### Task 3: The Core's cache folder and container label

**Files:**
- Modify: `core/cmd/runnir/main.go`
- Modify: `core/cmd/runnir/main_test.go`
- Modify: `core/internal/localrun/runner.go:22`
- Modify: `core/internal/localrun/runner_test.go:169,208`
- Modify: `docs/architecture/grpc-api.md:7`

**Interfaces:**
- Produces: `runnir serve --cache-dir PATH` (absolute); act's cache in `PATH/act`. `localrun.Label == "io.dil8.runnir.execution"`.

- [ ] **Step 1: Write the failing tests**

In `core/cmd/runnir/main_test.go`, add a case to the slice in `TestServeUsage`:

```go
	for _, args := range [][]string{{"serve"}, {"serve", "--socket"}, {"serve", "--socket", "/tmp/x", "extra"}, {"serve", "--bogus"}, {"serve", "--socket", "/tmp/x", "--data-dir", "relative/path"}, {"serve", "--socket", "/tmp/x", "--cache-dir", "relative/path"}} {
```

and add after `TestServeStopsWhenStdinCloses`:

```go
func TestServeTakesACacheFolder(t *testing.T) {
	serveUntilStdinCloses(t, nil, "--cache-dir", t.TempDir())
}

func TestActKeepsItsCacheInTheCacheFolder(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "Runnir Dev")
	if got := actCache(dir); filepath.Dir(got) != dir || filepath.Base(got) != "act" {
		t.Fatalf("act cache = %q, want the act folder of %q", got, dir)
	}
	if got := actCache(""); got != "" {
		t.Fatalf("without --cache-dir the server's default is kept, got %q", got)
	}
}
```

In `core/internal/localrun/runner_test.go`, change `dev.runnir.execution` to `io.dil8.runnir.execution` on lines 169 and 208:

```go
		"--container-options=--label=io.dil8.runnir.execution=exec_test --cpus=2 --memory=1073741824",
```
```go
	if len(docker) != 1 || strings.Join(docker[0].Args, " ") != "ps --all --quiet --filter label=io.dil8.runnir.execution=exec_test" {
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd core && go test ./cmd/runnir/ ./internal/localrun/`
Expected: FAIL: `undefined: actCache` in `cmd/runnir`; the label tests in `localrun` fail with the old label.

- [ ] **Step 3: Implement the flag and the label**

In `core/internal/localrun/runner.go`:

```go
// Label marks every job container of a run so it can be removed afterwards.
const Label = "io.dil8.runnir.execution"
```

In `core/cmd/runnir/main.go`, replace the two usage strings in `run` with:

```go
		fmt.Fprintln(diagnostics, "usage: runnir version | rpc | serve --socket PATH [--data-dir PATH] [--cache-dir PATH]")
```
```go
		fmt.Fprintln(diagnostics, "unknown command; usage: runnir version | rpc | serve --socket PATH [--data-dir PATH] [--cache-dir PATH]")
```

In `serve`, extend the comment, the flags, the check and the options:

```go
// --data-dir is the app's support folder, where workspace databases live;
// without it nothing is written to disk. --cache-dir is the app's cache
// folder, where act keeps its clones of actions (B47: Runnir Dev has its own).
func serve(args []string, input io.Reader, diagnostics io.Writer) int {
	flags := flag.NewFlagSet("serve", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	socket := flags.String("socket", "", "Unix domain socket path")
	exitOnEOF := flags.Bool("exit-on-stdin-eof", false, "stop when stdin closes")
	secretOnStdin := flags.Bool("client-secret-stdin", false, "read the client secret from the first stdin line")
	dataDir := flags.String("data-dir", "", "the app's support folder for workspace databases")
	cacheDir := flags.String("cache-dir", "", "the app's cache folder for act's clones of actions")
	relative := func(dir string) bool { return dir != "" && !filepath.IsAbs(dir) }
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 || *socket == "" || relative(*dataDir) || relative(*cacheDir) {
		fmt.Fprintln(diagnostics, "usage: runnir serve --socket PATH [--data-dir PATH] [--cache-dir PATH] [--exit-on-stdin-eof] [--client-secret-stdin]")
		return 2
	}
	reader := bufio.NewReaderSize(input, 512)
	options := server.Options{BundledAct: bundledAct(), DataDir: *dataDir, ActCache: actCache(*cacheDir)}
```

and add after `serve`:

```go
// actCache is where act keeps its clones of actions: the act folder of
// --cache-dir, or empty for the server's default in the user cache folder.
func actCache(cacheDir string) string {
	if cacheDir == "" {
		return ""
	}
	return filepath.Join(cacheDir, "act")
}
```

- [ ] **Step 4: Run the Core checks**

Run: `cd core && go test ./... && go vet ./... && go build ./...`
Expected: every package `ok`, no vet output.

- [ ] **Step 5: Document the flag**

In `docs/architecture/grpc-api.md` line 7, replace the start of the bullet:

```markdown
- One Core per app instance. The app launches the bundled `runnir-core serve --socket PATH --data-dir SUPPORT --cache-dir CACHES --exit-on-stdin-eof` with Foundation `Process`. `--data-dir` is the app's support folder (`~/Library/Application Support/Runnir`, `Runnir Dev` for a dev build, or the UI-test state folder), where each workspace keeps its database in `repositories/<workspaceId>/` ([ADR 0007](../decisions/0007-workspace-sqlite.md)); without it nothing is written to disk. `--cache-dir` is the app's cache folder (`~/Library/Caches/Runnir` or `Runnir Dev`), where act keeps its clones of actions in `act/`; without it they go to the user cache folder's `Runnir/act`. Closing a window never stops it; quitting does.
```

- [ ] **Step 6: Commit**

```bash
git add core/cmd/runnir core/internal/localrun docs/architecture/grpc-api.md
git commit -m "Core: serve --cache-dir for act's cache, containers labelled io.dil8.runnir.execution (B47)"
```

---

### Task 4: The app's folders, Keychain services and notification names

**Files:**
- Modify: `apps/macos/Runnir/App/Desktop/DesktopStateStore.swift:167-179`
- Modify: `apps/macos/Runnir/IPC/CoreProcessSupervisor.swift:118-137`
- Modify: `apps/macos/Runnir/IPC/ProcessCoreLauncher.swift:7-27`
- Modify: `apps/macos/Runnir/Core/Security/KeychainCredentialStore.swift:15-23`
- Modify: `apps/macos/Runnir/Core/Security/LocalRunValueStore.swift:29-54`
- Modify: `apps/macos/Runnir/Features/Desktop/RunNotifications.swift:95-99`
- Modify: `apps/macos/RunnirTests/RunnirBuildTests.swift`, `WorkspaceCacheTests.swift:5-13`, `LocalRunValuesTests.swift:38-39,59-70`

**Interfaces:**
- Consumes: `RunnirBuild` (Task 2); `serve --cache-dir` (Task 3).
- Produces: `RunnirSupportDirectory.url(build: RunnirBuild = .current) throws -> URL`; `CoreProcessSupervisor.logURL(for: RunnirBuild) -> URL?`; `CoreProcessSupervisor.cacheURL(for: RunnirBuild) -> URL?`; `ProcessCoreLauncher.cacheDirectory: URL?`; `ProcessCoreLauncher.arguments(socketPath:dataDirectory:cacheDirectory:)`; `KeychainCredentialStore.service(for: RunnirBuild) -> String`; `KeychainLocalRunValueStore.prefix(for: RunnirBuild) -> String`.

- [ ] **Step 1: Write the failing tests**

Append to `apps/macos/RunnirTests/RunnirBuildTests.swift`:

```swift
@Suite struct BuildFolderTests {
    @Test func devKeepsItsOwnFolders() throws {
        #expect(try RunnirSupportDirectory.url(build: .dev).lastPathComponent == "Runnir Dev")
        #expect(try RunnirSupportDirectory.url(build: .release).lastPathComponent == "Runnir")
        #expect(try RunnirSupportDirectory.url(build: .beta).deletingLastPathComponent().lastPathComponent == "Application Support")
        #expect(CoreProcessSupervisor.logURL(for: .dev)?.path.hasSuffix("/Library/Logs/Runnir Dev/core.log") == true)
        #expect(CoreProcessSupervisor.logURL(for: .alpha)?.path.hasSuffix("/Library/Logs/Runnir/core.log") == true)
        #expect(CoreProcessSupervisor.cacheURL(for: .dev)?.path.hasSuffix("/Library/Caches/Runnir Dev") == true)
        #expect(CoreProcessSupervisor.cacheURL(for: .release)?.path.hasSuffix("/Library/Caches/Runnir") == true)
    }

    @Test func devKeepsItsOwnKeychainItems() {
        #expect(KeychainCredentialStore.service(for: .dev) == "io.dil8.runnir.dev.github")
        #expect(KeychainCredentialStore.service(for: .release) == "io.dil8.runnir.github")
        #expect(KeychainLocalRunValueStore.prefix(for: .dev) == "io.dil8.runnir.dev.local-run")
        #expect(KeychainLocalRunValueStore.prefix(for: .beta) == "io.dil8.runnir.local-run")
    }

    @MainActor
    @Test func notificationNamesAreUnderTheCompanyDomain() {
        #expect(RunNotifier.categoryID == "io.dil8.runnir.run")
        #expect(RunNotifier.failedChecksCategoryID == "io.dil8.runnir.checks.failed")
        #expect(RunNotifier.openRunActionID == "io.dil8.runnir.open-run")
        #expect(Notification.Name.localRunValuesChanged.rawValue == "io.dil8.runnir.localRunValuesChanged")
    }
}
```

In `apps/macos/RunnirTests/WorkspaceCacheTests.swift`, replace `theDataDirectoryIsPassedToTheCore` with:

```swift
    @Test func theDataAndCacheFoldersArePassedToTheCore() {
        let arguments = ProcessCoreLauncher.arguments(socketPath: "/tmp/s.sock",
                                                      dataDirectory: URL(fileURLWithPath: "/Users/me/Library/Application Support/Runnir Dev"),
                                                      cacheDirectory: URL(fileURLWithPath: "/Users/me/Library/Caches/Runnir Dev"))
        #expect(arguments == ["serve", "--socket", "/tmp/s.sock", "--exit-on-stdin-eof", "--client-secret-stdin",
                              "--data-dir", "/Users/me/Library/Application Support/Runnir Dev",
                              "--cache-dir", "/Users/me/Library/Caches/Runnir Dev"])
        let bare = ProcessCoreLauncher.arguments(socketPath: "/tmp/s.sock", dataDirectory: nil, cacheDirectory: nil)
        #expect(!bare.contains("--data-dir") && !bare.contains("--cache-dir"))
    }
```

In `apps/macos/RunnirTests/LocalRunValuesTests.swift`, replace `dev.runnir.local-run` with `io.dil8.runnir.local-run` (lines 38-39) and `dev.runnir.test` with `io.dil8.runnir.test` (lines 59, 67, 70).

- [ ] **Step 2: Run the tests to see them fail**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/BuildFolderTests -only-testing:RunnirTests/CoreLaunchArgumentTests 2>&1 | grep -E "error:|TEST (SUCCEEDED|FAILED)"`
Expected: build fails: `RunnirSupportDirectory.url` has no `build:` argument, `logURL(for:)`, `cacheURL(for:)`, `service(for:)`, `prefix(for:)` and `cacheDirectory:` do not exist.

- [ ] **Step 3: Implement the folders**

`apps/macos/Runnir/App/Desktop/DesktopStateStore.swift`, `RunnirSupportDirectory`:

```swift
enum RunnirSupportDirectory {
    /// The build's folder in Application Support: Runnir, or Runnir Dev for a
    /// dev build (B47).
    static func url(build: RunnirBuild = .current) throws -> URL {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           let path = ProcessInfo.processInfo.environment["RUNNIR_UI_TEST_STATE_DIRECTORY"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false)
        return support.appendingPathComponent(build.folderName, isDirectory: true)
    }
}
```

`apps/macos/Runnir/IPC/CoreProcessSupervisor.swift`, in `bundled()` and below it:

```swift
    /// The app's supervisor: bundled helper, gRPC over a socket in the
    /// per-user temporary directory,
    /// and the Core's diagnostics in `logURL`.
    static func bundled() -> CoreProcessSupervisor {
        let bundle = Bundle.main.bundleURL
        return CoreProcessSupervisor(
            launcher: ProcessCoreLauncher(
                executableURL: bundle.appendingPathComponent("Contents/Helpers/runnir-core"),
                logURL: logURL,
                dataDirectory: try? RunnirSupportDirectory.url(),
                cacheDirectory: cacheURL(for: .current)
            ),
            connector: GRPCCoreConnector(),
            socketPath: socketPath(in: FileManager.default.temporaryDirectory, instance: instanceTag(for: bundle))
        )
    }

    /// Where the Core's standard error goes: ~/Library/Logs/Runnir/core.log,
    /// Runnir Dev for a dev build. The previous launch's log is kept as
    /// core.previous.log.
    static let logURL: URL? = logURL(for: .current)

    static func logURL(for build: RunnirBuild) -> URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/\(build.folderName)/core.log")
    }

    /// The Core's cache folder, where act keeps its clones of actions:
    /// ~/Library/Caches/Runnir, or Runnir Dev for a dev build.
    static func cacheURL(for build: RunnirBuild) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(build.folderName, isDirectory: true)
    }
```

`apps/macos/Runnir/IPC/ProcessCoreLauncher.swift`:

```swift
struct ProcessCoreLauncher: CoreProcessLaunching {
    let executableURL: URL
    var logURL: URL? = nil
    /// The app's support folder, where the Core keeps workspace databases.
    var dataDirectory: URL? = nil
    /// The app's cache folder, where the Core keeps act's clones of actions.
    var cacheDirectory: URL? = nil

    /// The Core's command line.
    static func arguments(socketPath: String, dataDirectory: URL?, cacheDirectory: URL?) -> [String] {
        var arguments = ["serve", "--socket", socketPath, "--exit-on-stdin-eof", "--client-secret-stdin"]
        if let dataDirectory { arguments += ["--data-dir", dataDirectory.path] }
        if let cacheDirectory { arguments += ["--cache-dir", cacheDirectory.path] }
        return arguments
    }
```

and in `launch`:

```swift
        process.arguments = Self.arguments(socketPath: socketPath, dataDirectory: dataDirectory, cacheDirectory: cacheDirectory)
```

- [ ] **Step 4: Implement the Keychain services and names**

`apps/macos/Runnir/Core/Security/KeychainCredentialStore.swift`:

```swift
    /// The sign-in's Keychain item, or, for UI tests of a Debug build, an
    /// item of their own: a test run never reads the user's sign-in, and its
    /// Sign Out never removes it.
    static var defaultService: String {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return "io.dil8.runnir.github.ui-testing" }
        #endif
        return service(for: .current)
    }

    /// The build's sign-in service: Runnir Dev keeps its own (B47).
    static func service(for build: RunnirBuild) -> String { "\(build.keychainPrefix).github" }
```

`apps/macos/Runnir/Core/Security/LocalRunValueStore.swift`:

```swift
    static let localRunValuesChanged = Notification.Name("io.dil8.runnir.localRunValuesChanged")
```
```swift
    /// UI tests of a Debug build keep their own items.
    static var defaultPrefix: String {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return "io.dil8.runnir.local-run.ui-testing" }
        #endif
        return prefix(for: .current)
    }

    /// The build's prefix: Runnir Dev keeps its own values (B47).
    static func prefix(for build: RunnirBuild) -> String { "\(build.keychainPrefix).local-run" }
```

`apps/macos/Runnir/Features/Desktop/RunNotifications.swift`:

```swift
    static let categoryID = "io.dil8.runnir.run"
    /// Failed pull request checks also offer Open Run: the failed run, as a
    /// click on the notification opens it.
    static let failedChecksCategoryID = "io.dil8.runnir.checks.failed"
    static let openRunActionID = "io.dil8.runnir.open-run"
```

- [ ] **Step 5: Check that no earlier name is left in code**

Run: `grep -rn "dev\.runnir\|dileight" apps/macos/Runnir apps/macos/RunnirTests apps/macos/RunnirUITests core --include='*.swift' --include='*.go' | grep -v /Generated/`
Expected: no output.

- [ ] **Step 6: Run the tests to see them pass**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests 2>&1 | grep -E "error:|✘|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: `Test run with … tests … passed`, `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add apps/macos/Runnir apps/macos/RunnirTests
git commit -m "App: Runnir Dev keeps its own folders and Keychain items, names under io.dil8.runnir (B47)"
```

---

### Task 5: The menu bar capsule

**Files:**
- Modify: `apps/macos/Runnir/Features/Desktop/MenuBarIcon.swift`
- Modify: `apps/macos/RunnirTests/PullRequestsTests.swift` (`MenuBarIconTests`, from line 281)
- Modify: `apps/macos/RunnirTests/WatchedRunsTests.swift:141-142`

**Interfaces:**
- Consumes: `RunnirBuild.mark`, `RunnirBuild.spokenName` (Task 2).
- Produces: `MenuBarIcon.image(badge:dimmed:build: RunnirBuild = .current) -> NSImage`; `MenuBarIcon.accessibilityLabel(checks:runs:build: RunnirBuild = .current) -> String`; `MenuBarIcon.markGap: CGFloat`, `MenuBarIcon.markHeight: CGFloat`, `MenuBarIcon.markWidth(_ mark: String) -> CGFloat`.

- [ ] **Step 1: Write the failing tests**

In `MenuBarIconTests` (`apps/macos/RunnirTests/PullRequestsTests.swift`), change the first line of `theGlyphWithADotIsTheRightWayUp` that makes the badged image to a release, since the test measures the dot against the image's right edge:

```swift
        let badged = MenuBarIcon.image(badge: .failed, dimmed: false, build: .release)
```

and add to the suite:

```swift
    @Test func aReleaseKeepsThePlainTemplateGlyph() {
        let plain = MenuBarIcon.image(badge: .none, dimmed: false, build: .release)
        #expect(plain.isTemplate)
        #expect(plain.size == MenuBarIcon.glyph.size)
    }

    @Test func otherBuildsCarryTheirWordInACapsuleAfterTheGlyph() throws {
        for build in [RunnirBuild.dev, .alpha, .beta] {
            let mark = try #require(build.mark)
            let image = MenuBarIcon.image(badge: .none, dimmed: false, build: build)
            #expect(!image.isTemplate)
            #expect(image.size.width == 21 + MenuBarIcon.markGap + MenuBarIcon.markWidth(mark))
            #expect(image.size.height == 18)
            #expect(MenuBarIcon.image(badge: .failed, dimmed: false, build: build).size == image.size, "the dot adds no width")
            // Across the capsule's middle row the word is cut out of the fill.
            let pixels = try mask(image, size: image.size)
            let row = pixels[pixels.count / 2]
            let capsule = row[Int(21 + MenuBarIcon.markGap) + 1 ..< row.count - 1]
            #expect(capsule.contains(true) && capsule.contains(false), "\(build): the capsule is filled and the word is clear")
        }
    }

    @Test func theLabelBeginsWithTheBuildsName() {
        #expect(MenuBarIcon.accessibilityLabel(checks: .passed, runs: .failed, build: .beta) == "Runnir Beta, a run failed")
        #expect(MenuBarIcon.accessibilityLabel(checks: .passed, runs: .none, build: .dev) == "Runnir Dev")
    }
```

In `apps/macos/RunnirTests/WatchedRunsTests.swift` lines 141-142, name the release build:

```swift
        #expect(MenuBarIcon.accessibilityLabel(checks: .running, runs: .failed, build: .release) == "Runnir, a run failed, checks running")
        #expect(MenuBarIcon.accessibilityLabel(checks: .passed, runs: .none, build: .release) == "Runnir")
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/MenuBarIconTests 2>&1 | grep -E "error:|TEST (SUCCEEDED|FAILED)"`
Expected: build fails: extra argument `build`, no `markGap` or `markWidth`.

- [ ] **Step 3: Implement the capsule and the spoken name**

In `apps/macos/Runnir/Features/Desktop/MenuBarIcon.swift`, update the type comment's first sentence and `accessibilityLabel`, and replace `image(badge:dimmed:)`:

```swift
/// The menu bar item's image (S19): the glyph cut from the logo mark, with a
/// colored dot for pull request checks and the user's runs, and the build's
/// word in a capsule after it on a build other than a release (B47). The plain
/// glyph is a template that macOS tints; otherwise the image draws in the menu
/// bar's text color itself, since a template cannot carry a color.
```

```swift
    /// "Runnir Beta, a run failed, checks running": what the icon stands for.
    static func accessibilityLabel(checks ci: CorePullRequestCI?, runs: Badge, build: RunnirBuild = .current) -> String {
        var parts = [build.spokenName]
```

(the rest of `accessibilityLabel` stays as it is)

```swift
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
```

If the capsule test reports that the word is not clear (`capsule.contains(false)` fails), the text ignored the compositing operation: draw the word into the CGContext with `context.setBlendMode(.destinationOut)` through `NSGraphicsContext.current?.cgContext` before `draw(at:)` instead, and run the test again.

- [ ] **Step 4: Run the tests to see them pass**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests 2>&1 | grep -E "error:|✘|Test run with|TEST (SUCCEEDED|FAILED)"`
Expected: all RunnirTests pass, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Runnir/Features/Desktop/MenuBarIcon.swift apps/macos/RunnirTests/PullRequestsTests.swift apps/macos/RunnirTests/WatchedRunsTests.swift
git commit -m "App: the menu bar icon carries the build's word in a capsule (B47)"
```

---

### Task 6: The workflows pass and check the build

**Files:**
- Create: `scripts/check-app-build.sh`
- Modify: `.github/workflows/release.yml`
- Modify: `.github/workflows/app-build.yml`

**Interfaces:**
- Consumes: the `RUNNIR_BUILD` setting and Info.plist keys (Task 2).
- Produces: `scripts/check-app-build.sh APP BUNDLE_ID BUILD ICON_SET`, exit 1 with the mismatch on stderr.

- [ ] **Step 1: Write the check script**

Create `scripts/check-app-build.sh` and make it executable (`chmod +x scripts/check-app-build.sh`):

```sh
#!/bin/sh
set -eu

# Checks that a built Runnir.app is the build it was meant to be (B47): its
# bundle ID, its RunnirBuild and its app icon set.
# Usage: scripts/check-app-build.sh path/to/Runnir.app BUNDLE_ID BUILD ICON_SET
if [ $# -ne 4 ]; then
    echo "usage: $0 APP BUNDLE_ID BUILD ICON_SET" >&2
    exit 2
fi
plist="$1/Contents/Info.plist"

check() {
    actual=$(/usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || echo "(missing)")
    if [ "$actual" != "$2" ]; then
        echo "$1 is $actual, expected $2" >&2
        exit 1
    fi
    echo "$1: $actual"
}

check CFBundleIdentifier "$2"
check RunnirBuild "$3"
check CFBundleIconName "$4"
```

- [ ] **Step 2: Try the script on a local build**

```bash
S=$(mktemp -d)
xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' -derivedDataPath "$S" build >/dev/null
scripts/check-app-build.sh "$S/Build/Products/Debug/Runnir.app" io.dil8.runnir.dev dev AppIcon-Dev
scripts/check-app-build.sh "$S/Build/Products/Debug/Runnir.app" io.dil8.runnir release AppIcon; echo "exit $?"
```

Expected: the first prints three lines and exits 0; the second prints `CFBundleIdentifier is io.dil8.runnir.dev, expected io.dil8.runnir` and `exit 1`.

- [ ] **Step 3: Pass and check the build in `release.yml`**

Add before `- name: Build archive`:

```yaml
      - name: Pick the build
        # v1.2.3 is a release, v1.2.3-alpha.N an alpha and v1.2.3-beta.N a
        # beta (B47); any other tag stops here instead of shipping unmarked.
        run: |
          if [[ "$GITHUB_REF_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            build=release icon=AppIcon
          elif [[ "$GITHUB_REF_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+$ ]]; then
            build=alpha icon=AppIcon-Alpha
          elif [[ "$GITHUB_REF_NAME" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$ ]]; then
            build=beta icon=AppIcon-Beta
          else
            echo "::error::Tag $GITHUB_REF_NAME is not vX.Y.Z, vX.Y.Z-alpha.N or vX.Y.Z-beta.N"
            exit 1
          fi
          echo "RUNNIR_BUILD=$build" >> "$GITHUB_ENV"
          echo "RUNNIR_ICON=$icon" >> "$GITHUB_ENV"
```

In `- name: Build archive`, add the setting to the `xcodebuild archive` command after `MARKETING_VERSION=…`:

```yaml
            MARKETING_VERSION="${GITHUB_REF_NAME#v}" \
            RUNNIR_BUILD="$RUNNIR_BUILD" \
            CODE_SIGNING_ALLOWED=NO
```

Add after `- name: Build archive`:

```yaml
      - name: Check the build
        run: scripts/check-app-build.sh build/Runnir.xcarchive/Products/Applications/Runnir.app io.dil8.runnir "$RUNNIR_BUILD" "$RUNNIR_ICON"
```

- [ ] **Step 4: Check the build in `app-build.yml`**

Add `- "scripts/check-app-build.sh"` to the `paths` list (after `- "scripts/build-core-macos.sh"`), and after `- name: Check architectures`:

```yaml
      - name: Check the build
        # Built without a tag: Runnir Dev (B47).
        run: scripts/check-app-build.sh build/Runnir.xcarchive/Products/Applications/Runnir.app io.dil8.runnir.dev dev AppIcon-Dev
```

- [ ] **Step 5: Lint the workflows**

Run: `cd core && go run github.com/rhysd/actionlint/cmd/actionlint ../.github/workflows/release.yml ../.github/workflows/app-build.yml`
Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
git add scripts/check-app-build.sh .github/workflows/release.yml .github/workflows/app-build.yml
git commit -m "CI: tags pick the build, the archive is checked against it (B47)"
```

---

### Task 7: Docs, checklist and the full check

**Files:**
- Modify: `README.md:102-106`
- Modify: `docs/architecture/github-enterprise.md:16-17`
- Modify: `docs/architecture/workspace-persistence.md:3,74`
- Modify: `docs/security/github-authentication.md:48`
- Modify: `docs/decisions/0005-developer-id-without-app-sandbox.md:21`
- Modify: `docs/product/mvp-implementation-checklist.md` (progress row)
- Modify: `docs/superpowers/specs/2026-11-01-build-marks-design.md:3`

- [ ] **Step 1: Update the names and folders in the docs**

`README.md`, the paragraph before the `codesign` block and the block:

````markdown
A build made without a tag is Runnir Dev (`io.dil8.runnir.dev`, B47): its own app beside an installed release, with its own data, sign-in and Core. A Debug build is signed by the linker with the identifier `Runnir` rather than its bundle identifier, and macOS refuses notifications to it. To try notifications from a Debug build, sign it ad hoc with its bundle identifier first:

```bash
codesign --force --sign - --identifier io.dil8.runnir.dev path/to/Runnir.app
```
````

`docs/architecture/github-enterprise.md` lines 16-17: replace `` `dev.runnir.github` / `oauth-token`, so existing sign-ins keep working `` with `` `io.dil8.runnir.github` / `oauth-token` (`io.dil8.runnir.dev.github` in Runnir Dev) ``, and `` `dev.runnir.github` / `enterprise:<id>` `` with `` `io.dil8.runnir.github` / `enterprise:<id>` ``.

`docs/security/github-authentication.md` line 48: replace `` `dev.runnir.github` / `enterprise:<server id>` `` with `` `io.dil8.runnir.github` / `enterprise:<server id>` (`io.dil8.runnir.dev.github` in Runnir Dev) ``.

`docs/architecture/workspace-persistence.md` line 3: replace `Application Support/Runnir/desktop-state.json` with `Application Support/Runnir/desktop-state.json (Runnir Dev for a dev build)`. Line 74: replace `` (service `dev.runnir.local-run.<workspace>`, `` with `` (service `io.dil8.runnir.local-run.<workspace>`, `io.dil8.runnir.dev.local-run.<workspace>` in Runnir Dev, ``.

`docs/decisions/0005-developer-id-without-app-sandbox.md` line 21: after `` `~/Library/Logs/Runnir` `` add `` (`Runnir Dev` for a build made without a tag, B47) ``.

Then run: `grep -rn "dev\.runnir\.\|dileight" README.md docs/architecture docs/security docs/decisions`
Expected: only records of earlier checks remain (`com.dileight.runnir.alertcheck` in `workspace-persistence.md` and ADR 0007's live checks).

- [ ] **Step 2: Mark B47 built**

In `docs/superpowers/specs/2026-11-01-build-marks-design.md` line 3, change `Status: design approved on 2026-11-01.` to `Status: design approved on 2026-11-01, built on branch dilbarov/build-marks.`

In `docs/product/mvp-implementation-checklist.md`, add after the `| B39 | Runs across repositories …` progress row:

```markdown
| B47 | Builds are told apart ([spec](../superpowers/specs/2026-11-01-build-marks-design.md)): `RUNNIR_BUILD` (dev unless the release workflow passes alpha, beta or release from the tag) sets the bundle ID, display name and app icon set, and lands in Info.plist as `RunnirBuild`; dev is Runnir Dev (`io.dil8.runnir.dev`) with its own Application Support, Logs and Caches folders, Keychain services and Core (`serve --cache-dir`); the app icon of dev, alpha and beta carries a pill, the menu bar glyph a capsule with the word; every reverse-DNS name is under `io.dil8.runnir`; the release workflow refuses other tag suffixes and both app workflows check the archive's bundle ID, build and icon set | A tagged alpha or beta built by the release workflow and opened on a Mac; Runnir Dev beside a release checked by hand |
```

The progress table has three columns: ID, State, Missing for acceptance.

- [ ] **Step 3: Run every check**

```bash
export PATH="$HOME/go/pkg/mod/golang.org/toolchain@v0.0.1-go1.27.3.darwin-arm64/bin:$PATH"
(cd core && go test ./... && go vet ./... && go build ./...)
xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build 2>&1 | grep -E "warning: .*\.swift|error:|BUILD (SUCCEEDED|FAILED)" | sort -u
xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests 2>&1 | grep -E "error:|✘|Test run with|TEST (SUCCEEDED|FAILED)"
```

Expected: Go `ok` for every package and no vet output; `** BUILD SUCCEEDED **` with no warnings beyond the earlier ones (`RunGraphViews.swift:324`, `SettingsOverlay.swift:43`); `** TEST SUCCEEDED **`.

- [ ] **Step 4: Check Runnir Dev by hand**

Build and open the Debug app (`open <DerivedData>/Build/Products/Debug/Runnir.app`), then confirm:
- the Dock shows the DEV pill and the name Runnir Dev;
- the menu bar shows the glyph with a DEV capsule, and the dot of a failed check stays on the glyph;
- the app starts signed out with an empty Workspace Manager, and `~/Library/Application Support/Runnir Dev`, `~/Library/Logs/Runnir Dev/core.log` and, after a local run, `~/Library/Caches/Runnir Dev/act` exist;
- with another Runnir copy running, both run with their own Core.

Write what was checked, and what was not, into the pull request.

- [ ] **Step 5: Commit**

```bash
git add README.md docs
git commit -m "Docs: B47 built, current names and folders"
```
