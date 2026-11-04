import Foundation
import Testing
@testable import Runnir

@Suite struct RunnirBuildTests {
    @Test func theInfoValueNamesTheBuildAndAnythingElseIsDev() {
        #expect(RunnirBuild(infoValue: "release") == .release)
        #expect(RunnirBuild(infoValue: "alpha") == .alpha)
        #expect(RunnirBuild(infoValue: "beta") == .beta)
        #expect(RunnirBuild(infoValue: "dev") == .dev)
        #expect(RunnirBuild(infoValue: "local") == .local)
        #expect(RunnirBuild(infoValue: nil) == .dev, "a build that lost the key is not taken for a release")
        #expect(RunnirBuild(infoValue: "$(RUNNIR_BUILD)") == .dev)
        #expect(RunnirBuild(infoValue: "Release") == .dev)
    }

    @Test func eachBuildNamesItself() {
        #expect(RunnirBuild.allCases.map(\.mark) == ["DEV", "LOCAL", "ALPHA", "BETA", nil])
        #expect(RunnirBuild.allCases.map(\.spokenName) == ["Runnir Dev", "Runnir Local", "Runnir Alpha", "Runnir Beta", "Runnir"])
        #expect(RunnirBuild.allCases.map(\.folderName) == ["Runnir Dev", "Runnir Local", "Runnir", "Runnir", "Runnir"])
        #expect(RunnirBuild.allCases.map(\.keychainPrefix) == ["com.runnir.app.dev", "com.runnir.app.local", "com.runnir.app", "com.runnir.app", "com.runnir.app"])
        #expect(RunnirBuild.allCases.map(\.marksWindows) == [true, true, false, false, false], "dev and local say so in their windows")
    }

    @Test func theTestHostIsADevBuild() {
        // The tests run in an app built without a tag: Info.plist carries dev.
        #expect(Bundle.main.object(forInfoDictionaryKey: "RunnirBuild") as? String == "dev")
        #expect(RunnirBuild.current == .dev)
        #expect(Bundle.main.bundleIdentifier == "com.runnir.app.dev")
    }
}

@Suite struct BuildFolderTests {
    @Test func devAndLocalKeepTheirOwnFolders() throws {
        #expect(try RunnirSupportDirectory.url(build: .dev).lastPathComponent == "Runnir Dev")
        #expect(try RunnirSupportDirectory.url(build: .local).lastPathComponent == "Runnir Local")
        #expect(try RunnirSupportDirectory.url(build: .release).lastPathComponent == "Runnir")
        #expect(try RunnirSupportDirectory.url(build: .beta).deletingLastPathComponent().lastPathComponent == "Application Support")
        #expect(CoreProcessSupervisor.logURL(for: .dev)?.path.hasSuffix("/Library/Logs/Runnir Dev/core.log") == true)
        #expect(CoreProcessSupervisor.logURL(for: .alpha)?.path.hasSuffix("/Library/Logs/Runnir/core.log") == true)
        #expect(CoreProcessSupervisor.cacheURL(for: .dev)?.path.hasSuffix("/Library/Caches/Runnir Dev") == true)
        #expect(CoreProcessSupervisor.logURL(for: .local)?.path.hasSuffix("/Library/Logs/Runnir Local/core.log") == true)
        #expect(CoreProcessSupervisor.cacheURL(for: .release)?.path.hasSuffix("/Library/Caches/Runnir") == true)
    }

    @Test func devAndLocalKeepTheirOwnKeychainItems() {
        #expect(KeychainCredentialStore.service(for: .dev) == "com.runnir.app.dev.github")
        #expect(KeychainCredentialStore.service(for: .local) == "com.runnir.app.local.github")
        #expect(KeychainCredentialStore.service(for: .release) == "com.runnir.app.github")
        #expect(KeychainLocalRunValueStore.prefix(for: .dev) == "com.runnir.app.dev.run-values")
        #expect(KeychainLocalRunValueStore.prefix(for: .beta) == "com.runnir.app.run-values")
        #expect(KeychainLocalRunValueStore.prefix(for: .local) == "com.runnir.app.local.run-values")
    }

    @Test func noReleaseServiceBeginsWithTheNameOfAnotherApp() {
        // A search for Runnir Local's items must not find the release's.
        let release = [KeychainCredentialStore.service(for: .release), KeychainLocalRunValueStore.prefix(for: .release)]
        for build in [RunnirBuild.dev, .local] {
            #expect(release.allSatisfy { !$0.hasPrefix(build.keychainPrefix) }, "\(build)")
        }
    }

    @MainActor
    @Test func notificationNamesAreUnderTheCompanyDomain() {
        #expect(RunNotifier.categoryID == "com.runnir.run")
        #expect(RunNotifier.failedChecksCategoryID == "com.runnir.checks.failed")
        #expect(RunNotifier.openRunActionID == "com.runnir.open-run")
        #expect(Notification.Name.localRunValuesChanged.rawValue == "com.runnir.localRunValuesChanged")
    }
}
