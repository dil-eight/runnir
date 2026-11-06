import Foundation
import Security

/// The steps of installing an update (B50), behind a protocol so the
/// state machine is tested without the network or the app bundle.
protocol UpdateInstalling: Sendable {
    /// Downloads the release's zip next to the app; reports bytes received
    /// and expected (0 when unknown).
    func download(_ release: UpdateRelease, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL
    /// Unpacks the zip and checks the app in it; returns the checked app.
    func prepare(_ zip: URL, for release: UpdateRelease) async throws -> URL
    /// Puts the checked app in place of the running one.
    func install(_ app: URL) throws
    /// Opens the app again once this process has ended.
    func relaunchAfterExit() throws
    /// Deletes what a step left behind.
    func discard(_ url: URL)
}

/// Why this copy of Runnir cannot replace itself, checked before
/// downloading.
enum UpdateBlock: Equatable, Sendable {
    /// macOS runs the app from a temporary folder (App Translocation).
    case outsideApplications
    case notWritable
}

/// The code signature an update must have: the running app's identifier, its
/// Developer ID team and a notarization ticket. The team comes from the
/// running app's own signature, never from the repository.
enum UpdateSignature {
    struct Signer: Equatable, Sendable {
        let identifier: String
        let team: String
    }

    static func requirement(for signer: Signer) -> String {
        "anchor apple generic and identifier \"\(signer.identifier)\" and certificate leaf[subject.OU] = \"\(signer.team)\" and notarized"
    }

    /// The running app's signer; nil for an unsigned or ad hoc build.
    static func running() -> Signer? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return signer(of: staticCode)
    }

    static func signer(of code: SecStaticCode) -> Signer? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any],
              let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
        return Signer(identifier: identifier, team: team)
    }

    /// Checks the whole app, nested code included, against the requirement.
    static func check(_ app: URL, against signer: Signer) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.refused("The downloaded app has no code signature.")
        }
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement(for: signer) as CFString, [], &compiled) == errSecSuccess else {
            throw UpdateError.refused("Runnir could not build the signature check.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, compiled) == errSecSuccess else {
            throw UpdateError.refused("The downloaded app is not signed and notarized by Runnir's developer.")
        }
    }
}

/// Installs updates into the running app's bundle.
struct BundleUpdateInstaller: UpdateInstalling {
    let bundleURL: URL
    let signer: UpdateSignature.Signer?

    static func block(for bundleURL: URL, fileManager: FileManager = .default) -> UpdateBlock? {
        if bundleURL.path.contains("/AppTranslocation/") { return .outsideApplications }
        let folder = bundleURL.deletingLastPathComponent().path
        guard fileManager.isWritableFile(atPath: folder), fileManager.isWritableFile(atPath: bundleURL.path) else { return .notWritable }
        return nil
    }

    func download(_ release: UpdateRelease, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundleURL, create: true)
        let delegate = DownloadProgress(report: progress)
        let (file, response): (URL, URLResponse)
        do {
            (file, response) = try await URLSession.shared.download(from: release.zip, delegate: delegate)
        } catch is CancellationError {
            discard(staging)
            throw CancellationError()
        } catch {
            discard(staging)
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw UpdateError.download("The download of \(release.version) was interrupted.")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            discard(staging)
            throw UpdateError.download("GitHub did not send the download of \(release.version).")
        }
        let zip = staging.appending(path: "Runnir-\(release.tag).zip")
        try FileManager.default.moveItem(at: file, to: zip)
        return zip
    }

    func prepare(_ zip: URL, for release: UpdateRelease) async throws -> URL {
        let folder = zip.deletingLastPathComponent().appending(path: "unpacked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        try ditto.run()
        await Task.detached { ditto.waitUntilExit() }.value
        guard ditto.terminationStatus == 0 else { throw UpdateError.install("The download of \(release.version) could not be unpacked.") }
        let apps = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard apps.count == 1, let app = apps.first else { throw UpdateError.install("The download of \(release.version) does not hold one app.") }
        guard let signer else { throw UpdateError.refused("This copy of Runnir is not signed, so it cannot check an update.") }
        try UpdateSignature.check(app, against: signer)
        let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard version.flatMap(UpdateVersion.init) == release.version else {
            throw UpdateError.refused("The downloaded app is not version \(release.version).")
        }
        return app
    }

    func install(_ app: URL) throws {
        do {
            _ = try FileManager.default.replaceItemAt(bundleURL, withItemAt: app)
        } catch {
            throw UpdateError.install("Runnir could not replace itself: \(error.localizedDescription)")
        }
    }

    func relaunchAfterExit() throws {
        let wait = Process()
        wait.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits for this process to end, then opens the app at the same path.
        wait.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                          "runnir-relaunch", String(ProcessInfo.processInfo.processIdentifier), bundleURL.path]
        try wait.run()
    }

    func discard(_ url: URL) {
        // The staging folder, whichever step's file is passed: the zip is in
        // it, the app in its unpacked folder.
        let staging = switch url.pathExtension {
        case "zip": url.deletingLastPathComponent()
        case "app": url.deletingLastPathComponent().deletingLastPathComponent()
        default: url
        }
        try? FileManager.default.removeItem(at: staging)
    }
}

/// Reports a download's progress from its task.
private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?

    init(report: @escaping @Sendable (Int64, Int64) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let report = self.report
        let observation = task.observe(\.countOfBytesReceived) { task, _ in
            report(task.countOfBytesReceived, max(task.countOfBytesExpectedToReceive, 0))
        }
        lock.withLock { self.observation = observation }
    }
}
