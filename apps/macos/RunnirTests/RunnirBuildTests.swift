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
