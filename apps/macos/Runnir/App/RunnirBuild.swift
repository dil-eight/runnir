import Foundation

/// Which build this is (B47): a release, an alpha or beta pre-release from a
/// tag, a dev build made without one, or a local build signed on a Mac (B48).
/// Xcode writes the RUNNIR_BUILD setting into Info.plist as RunnirBuild. Dev
/// and local are separate apps, Runnir Dev and Runnir Local, each with its own
/// data, logs, caches and Keychain items.
enum RunnirBuild: String, CaseIterable, Sendable {
    case dev, local, alpha, beta, release

    /// This app's build.
    static let current = RunnirBuild(infoValue: Bundle.main.object(forInfoDictionaryKey: "RunnirBuild") as? String)

    /// A missing or unknown value is dev, so a build that lost the key shows
    /// DEV instead of passing for a release.
    init(infoValue: String?) {
        self = infoValue.flatMap(RunnirBuild.init(rawValue:)) ?? .dev
    }

    /// The word on the app icon and in the menu bar; nil for a release.
    var mark: String? { self == .release ? nil : rawValue.uppercased() }

    /// Dev and local are apps of their own; alpha, beta and release are one app.
    private var isOwnApp: Bool { self == .dev || self == .local }

    /// The windows of dev and local say so too; alpha and beta look like a release there.
    var marksWindows: Bool { isOwnApp }

    /// What VoiceOver calls the app: Runnir, Runnir Dev, Runnir Local, Runnir Alpha, Runnir Beta.
    var spokenName: String { self == .release ? "Runnir" : "Runnir " + rawValue.capitalized }

    /// The app's folder in Application Support, Logs and Caches.
    var folderName: String { isOwnApp ? spokenName : "Runnir" }

    /// What the app's Keychain services begin with: its bundle ID.
    var keychainPrefix: String { isOwnApp ? "com.runnir.app." + rawValue : "com.runnir.app" }
}
