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

    /// The app's windows say DEV too; alpha and beta look like a release there.
    var marksWindows: Bool { self == .dev }

    /// What VoiceOver calls the app: Runnir, Runnir Dev, Runnir Alpha, Runnir Beta.
    var spokenName: String { self == .release ? "Runnir" : "Runnir " + rawValue.capitalized }

    /// The app's folder in Application Support, Logs and Caches.
    var folderName: String { self == .dev ? "Runnir Dev" : "Runnir" }

    /// What the app's Keychain services begin with: its bundle ID.
    var keychainPrefix: String { self == .dev ? "com.runnir.app.dev" : "com.runnir.app" }
}
