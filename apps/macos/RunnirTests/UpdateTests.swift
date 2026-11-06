import Foundation
import Security
import Testing
@testable import Runnir

@Suite struct UpdateVersionTests {
    @Test func parsesTagsAndBundleVersions() {
        #expect(UpdateVersion("v0.2.0")?.description == "0.2.0")
        #expect(UpdateVersion("0.2.0-alpha.3")?.prerelease == .init(stage: .alpha, number: 3))
        #expect(UpdateVersion("v1.10.2-beta.12")?.description == "1.10.2-beta.12")
        for bad in ["", "v1", "1.2", "1.2.3.4", "1.2.x", "1.2.3-rc.1", "1.2.3-beta", "1.2.3-beta.x", "-1.0.0", "1.2.3-"] {
            #expect(UpdateVersion(bad) == nil, "\(bad)")
        }
    }

    @Test func ordersBySemanticVersionPrecedence() {
        let ordered = ["0.1.0", "0.2.0-alpha.1", "0.2.0-alpha.3", "0.2.0-alpha.10", "0.2.0-beta.1", "0.2.0", "0.2.1-alpha.1", "0.10.0", "1.0.0"]
            .map { UpdateVersion($0)! }
        #expect(ordered == ordered.shuffled().sorted())
        #expect(!(UpdateVersion("0.2.0")! < UpdateVersion("0.2.0")!))
    }
}

@Suite struct UpdatePolicyTests {
    private func allows(_ candidate: String, from current: String, _ build: RunnirBuild, betas: Bool = false) -> Bool {
        UpdatePolicy.allows(UpdateVersion(candidate)!, current: UpdateVersion(current)!, build: build, betas: betas)
    }

    @Test func anAlphaTakesAnyNewerVersion() {
        #expect(allows("0.2.0-alpha.2", from: "0.2.0-alpha.1", .alpha))
        #expect(allows("0.2.0-beta.1", from: "0.2.0-alpha.1", .alpha))
        #expect(allows("0.2.0", from: "0.2.0-alpha.1", .alpha))
        #expect(allows("0.3.0-alpha.1", from: "0.2.0-alpha.1", .alpha))
        #expect(!allows("0.2.0-alpha.1", from: "0.2.0-alpha.1", .alpha))
        #expect(!allows("0.1.9", from: "0.2.0-alpha.1", .alpha))
    }

    @Test func aBetaTakesBetasOfItsVersionAndReleases() {
        #expect(allows("0.2.0-beta.2", from: "0.2.0-beta.1", .beta))
        #expect(allows("0.2.0", from: "0.2.0-beta.1", .beta))
        #expect(allows("0.3.0", from: "0.2.0-beta.1", .beta))
        #expect(!allows("0.3.0-beta.1", from: "0.2.0-beta.1", .beta))
        #expect(!allows("0.3.0-alpha.1", from: "0.2.0-beta.1", .beta))
        #expect(!allows("0.2.0-alpha.9", from: "0.2.0-beta.1", .beta))
    }

    @Test func aReleaseTakesReleasesAndBetasOnlyFromOneZeroWhenAsked() {
        #expect(allows("0.2.1", from: "0.2.0", .release))
        #expect(!allows("0.3.0-beta.1", from: "0.2.0", .release, betas: true)) // no beta setting before 1.0.0
        #expect(!allows("0.3.0-alpha.1", from: "0.2.0", .release, betas: true))
        #expect(!allows("1.1.0-beta.1", from: "1.0.0", .release))
        #expect(allows("1.1.0-beta.1", from: "1.0.0", .release, betas: true))
        #expect(!allows("1.1.0-alpha.1", from: "1.0.0", .release, betas: true))
        #expect(!UpdatePolicy.showsBetaSetting(build: .release, current: UpdateVersion("0.9.9")!))
        #expect(UpdatePolicy.showsBetaSetting(build: .release, current: UpdateVersion("1.0.0")!))
        #expect(!UpdatePolicy.showsBetaSetting(build: .beta, current: UpdateVersion("1.0.0-beta.1")!))
    }

    @Test func devAndLocalNeverUpdate() {
        #expect(!allows("9.0.0", from: "0.1.0", .dev))
        #expect(!allows("9.0.0", from: "0.1.0", .local))
        #expect(!UpdatePolicy.updates(.dev) && !UpdatePolicy.updates(.local) && UpdatePolicy.updates(.release))
    }

    @Test func picksTheNewestAllowed() {
        let releases = ["0.2.0-alpha.2", "0.2.0-beta.1", "0.1.1", "0.2.0-beta.2"].map(UpdateTestData.release)
        #expect(UpdatePolicy.pick(releases, current: UpdateVersion("0.2.0-alpha.1")!, build: .alpha, betas: false)?.tag == "v0.2.0-beta.2")
        #expect(UpdatePolicy.pick(releases, current: UpdateVersion("0.1.0")!, build: .release, betas: false)?.tag == "v0.1.1")
        #expect(UpdatePolicy.pick(releases, current: UpdateVersion("0.1.1")!, build: .release, betas: true) == nil)
    }
}

enum UpdateTestData {
    static func release(_ version: String) -> UpdateRelease {
        UpdateRelease(version: UpdateVersion(version)!, tag: "v\(version)",
                      zip: URL(string: "https://github.com/dil-eight/runnir/releases/download/v\(version)/Runnir-v\(version).zip")!,
                      page: URL(string: "https://github.com/dil-eight/runnir/releases/tag/v\(version)")!, size: 20_000_000)
    }
}

@Suite struct UpdateFeedTests {
    @Test func readsPublishedReleasesWithTheAppZip() throws {
        let json = """
        [{"tag_name": "v0.2.0-alpha.1", "draft": false, "html_url": "https://github.com/dil-eight/runnir/releases/tag/v0.2.0-alpha.1",
          "assets": [{"name": "runnir-v0.2.0-alpha.1-darwin-arm64", "browser_download_url": "https://x/core", "size": 1},
                     {"name": "Runnir-v0.2.0-alpha.1.zip", "browser_download_url": "https://x/app.zip", "size": 19000000}]},
         {"tag_name": "v0.2.0", "draft": true, "html_url": "https://x", "assets": [{"name": "Runnir-v0.2.0.zip", "browser_download_url": "https://x/d.zip"}]},
         {"tag_name": "nightly", "draft": false, "html_url": "https://x", "assets": [{"name": "Runnir-nightly.zip", "browser_download_url": "https://x/n.zip"}]},
         {"tag_name": "v0.1.0", "draft": false, "html_url": "https://x", "assets": []}]
        """
        let releases = try GitHubUpdateFeed.decode(Data(json.utf8))
        #expect(releases.map(\.tag) == ["v0.2.0-alpha.1"])
        #expect(releases.first?.zip.absoluteString == "https://x/app.zip" && releases.first?.size == 19_000_000)
        #expect(throws: UpdateError.self) { try GitHubUpdateFeed.decode(Data("{}".utf8)) }
    }
}

@Suite struct UpdateSignatureTests {
    @Test func theRequirementNamesTheAppTheTeamAndNotarization() {
        let requirement = UpdateSignature.requirement(for: .init(identifier: "com.runnir.app", team: "TEAM123456"))
        #expect(requirement == "anchor apple generic and identifier \"com.runnir.app\" and certificate leaf[subject.OU] = \"TEAM123456\" and notarized")
        var compiled: SecRequirement?
        #expect(SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess)
    }

    @Test func anUnsignedAppIsRefused() throws {
        let app = FileManager.default.temporaryDirectory.appending(path: "Unsigned-\(UUID().uuidString).app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        #expect(throws: UpdateError.self) {
            try UpdateSignature.check(app.deletingLastPathComponent(), against: .init(identifier: "com.runnir.app", team: "TEAM123456"))
        }
    }

    @Test func aTranslocatedOrUnwritableAppIsBlocked() throws {
        #expect(BundleUpdateInstaller.block(for: URL(fileURLWithPath: "/private/var/folders/x/T/AppTranslocation/ABC/d/Runnir.app")) == .outsideApplications)
        #expect(BundleUpdateInstaller.block(for: URL(fileURLWithPath: "/System/Applications/Calculator.app")) == .notWritable)
        let folder = FileManager.default.temporaryDirectory.appending(path: "Apps-\(UUID().uuidString)", directoryHint: .isDirectory)
        let app = folder.appending(path: "Runnir.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(BundleUpdateInstaller.block(for: app) == nil)
    }
}

/// A feed that answers what the test set, or fails.
final class FakeUpdateFeed: UpdateFeed, @unchecked Sendable {
    var result: Result<[UpdateRelease], UpdateError> = .success([])
    private(set) var calls = 0
    func releases() async throws -> [UpdateRelease] {
        calls += 1
        return try result.get()
    }
}

/// Records the installer's steps; each step can fail.
final class FakeUpdateInstaller: UpdateInstalling, @unchecked Sendable {
    var downloadError: UpdateError?
    var prepareError: UpdateError?
    var holdDownload = false
    private(set) var steps: [String] = []
    private let lock = NSLock()

    private func note(_ step: String) { lock.withLock { steps.append(step) } }

    func download(_ release: UpdateRelease, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        note("download")
        progress(8_100_000, 19_200_000)
        if holdDownload { try await Task.sleep(for: .seconds(30)) }
        if let downloadError { throw downloadError }
        return URL(fileURLWithPath: "/tmp/staging/Runnir-\(release.tag).zip")
    }

    func prepare(_ zip: URL, for release: UpdateRelease) async throws -> URL {
        note("prepare")
        if let prepareError { throw prepareError }
        return URL(fileURLWithPath: "/tmp/staging/unpacked/Runnir.app")
    }

    func install(_ app: URL) throws { note("install") }
    func relaunchAfterExit() throws { note("relaunch") }
    func discard(_ url: URL) { note("discard \(url.lastPathComponent)") }
}

@MainActor
@Suite struct UpdateCenterTests {
    private func center(_ build: RunnirBuild = .alpha, current: String = "0.2.0-alpha.1", block: UpdateBlock? = nil)
        -> (UpdateCenter, FakeUpdateFeed, FakeUpdateInstaller, UserDefaults)
    {
        let defaults = UserDefaults(suiteName: "UpdateCenterTests-\(UUID().uuidString)")!
        let feed = FakeUpdateFeed()
        let installer = FakeUpdateInstaller()
        let center = UpdateCenter(build: build, current: UpdateVersion(current), feed: feed, installer: installer,
                                  block: { block }, defaults: defaults, now: { Date(timeIntervalSince1970: 1_000) })
        return (center, feed, installer, defaults)
    }

    @Test func aCheckOffersTheNewestAllowedVersion() async {
        let (center, feed, _, defaults) = center()
        feed.result = .success(["0.2.0-alpha.2", "0.1.0"].map(UpdateTestData.release))
        await center.check(userInitiated: false)
        #expect(center.state == .available(UpdateTestData.release("0.2.0-alpha.2")))
        #expect(center.lastChecked == Date(timeIntervalSince1970: 1_000))
        #expect(defaults.object(forKey: "updates.lastChecked") as? Date == Date(timeIntervalSince1970: 1_000))
        feed.result = .success([])
        await center.check(userInitiated: false)
        #expect(center.state == .idle)
    }

    @Test func onlyAManualCheckReportsAFailure() async {
        let (center, feed, _, _) = center()
        feed.result = .failure(.feed("GitHub answered 503"))
        await center.check(userInitiated: false)
        #expect(center.checkError == nil && center.state == .idle)
        await center.check(userInitiated: true)
        #expect(center.checkError == "GitHub answered 503")
    }

    @Test func devAndLocalBuildsNeverAsk() async {
        for build in [RunnirBuild.dev, .local] {
            let (center, feed, _, _) = center(build)
            await center.check(userInitiated: true)
            #expect(feed.calls == 0 && !center.isEnabled)
        }
    }

    @Test func updateDownloadsChecksInstallsAndRestarts() async {
        let (center, feed, installer, _) = center()
        feed.result = .success([UpdateTestData.release("0.2.0-alpha.2")])
        await center.check(userInitiated: false)
        var quit = false
        center.quit = { quit = true }
        center.update()
        #expect(await eventually { quit })
        #expect(installer.steps == ["download", "prepare", "install", "discard Runnir-v0.2.0-alpha.2.zip", "relaunch"])
        #expect(center.state == .restartPending(UpdateTestData.release("0.2.0-alpha.2")))
    }

    @Test func aFailedStepChangesNothingAndOffersTryAgain() async {
        let (center, feed, installer, _) = center()
        let release = UpdateTestData.release("0.2.0-alpha.2")
        feed.result = .success([release])
        await center.check(userInitiated: false)
        installer.prepareError = .refused("The downloaded app is not signed and notarized by Runnir's developer.")
        center.update()
        #expect(await eventually { if case .failed = center.state { true } else { false } })
        #expect(center.state == .failed(release, "The downloaded app is not signed and notarized by Runnir's developer. Nothing was changed."))
        #expect(!installer.steps.contains("install"))
        #expect(installer.steps.last == "discard Runnir-v0.2.0-alpha.2.zip")
        // The same version stays failed through an automatic check, until Try Again.
        await center.check(userInitiated: false)
        #expect(center.state == .failed(release, "The downloaded app is not signed and notarized by Runnir's developer. Nothing was changed."))
        installer.prepareError = nil
        var quit = false
        center.quit = { quit = true }
        center.update()
        #expect(await eventually { quit })
    }

    @Test func cancelStopsTheDownload() async {
        let (center, feed, installer, _) = center()
        let release = UpdateTestData.release("0.2.0-alpha.2")
        feed.result = .success([release])
        await center.check(userInitiated: false)
        installer.holdDownload = true
        center.update()
        #expect(await eventually { if case let .downloading(_, received, total) = center.state { received == 8_100_000 && total == 19_200_000 } else { false } })
        center.cancel()
        #expect(await eventually { center.state == .available(release) })
        #expect(!installer.steps.contains("prepare"))
    }

    @Test func aBlockedCopyDoesNotDownload() async {
        let release = UpdateTestData.release("0.2.0-alpha.2")
        for (block, expected) in [(UpdateBlock.outsideApplications, UpdateCenter.State.outsideApplications(release)),
                                  (.notWritable, .failed(release, "Runnir can't write to the folder it is in. Download the new version and move it to Applications."))] {
            let (center, feed, installer, _) = center(block: block)
            feed.result = .success([release])
            await center.check(userInitiated: false)
            center.update()
            #expect(center.state == expected)
            #expect(installer.steps.isEmpty)
        }
    }

    @Test func settingsAreKept() {
        let (center, _, _, defaults) = center(.release, current: "1.0.0")
        #expect(center.checksAutomatically && !center.getsBetas && center.showsBetaSetting)
        center.getsBetas = true
        center.checksAutomatically = false
        #expect(defaults.bool(forKey: "updates.getsBetas") && defaults.object(forKey: "updates.checksAutomatically") as? Bool == false)
    }
}
