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
        #expect(RunnirBuild.allCases.map(\.marksWindows) == [true, false, false, false], "only dev says so in its windows")
    }

    @Test func theTestHostIsADevBuild() {
        // The tests run in an app built without a tag: Info.plist carries dev.
        #expect(Bundle.main.object(forInfoDictionaryKey: "RunnirBuild") as? String == "dev")
        #expect(RunnirBuild.current == .dev)
        #expect(Bundle.main.bundleIdentifier == "io.dil8.runnir.dev")
    }
}

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
