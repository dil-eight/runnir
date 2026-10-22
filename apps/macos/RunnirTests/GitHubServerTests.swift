import Foundation
import Testing
@testable import Runnir

struct GitHubServerTests {
    @Test func repositoryKeysStayCompatibleForGitHubDotCom() {
        #expect(GitHubRepositoryRef(serverID: "", fullName: "o/r").key == "o/r")
        let id = "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"
        let enterprise = GitHubRepositoryRef(serverID: id, fullName: "o/r")
        #expect(enterprise.key == "\(id):o/r")
        #expect(GitHubRepositoryRef(key: enterprise.key) == enterprise)
        #expect(GitHubRepositoryRef(key: "o/r") == GitHubRepositoryRef(serverID: "", fullName: "o/r"))
        #expect(GitHubRepositoryRef(key: "nope") == nil)
        #expect(GitHubRepositoryRef(key: "\(id):nope") == nil)
    }

    @Test func gitHubDotComHasNoID() {
        #expect(GitHubServerRef.dotCom.id.isEmpty && GitHubServerRef.dotCom.webHost == "github.com" && GitHubServerRef.dotCom.isDotCom)
    }

    @Test func onlyWebLinksFromGitHubAreKept() {
        #expect(GRPCCoreService.webURL("https://ghe.test/org/app/pull/3")?.host() == "ghe.test")
        #expect(GRPCCoreService.webURL("http://127.0.0.1:8080/org/app") != nil)
        #expect(GRPCCoreService.webURL("") == nil)
        #expect(GRPCCoreService.webURL("file:///Applications/Calculator.app") == nil)
        #expect(GRPCCoreService.webURL("x-apple.systempreferences:com.apple.Notifications-Settings.extension") == nil)
        #expect(GRPCCoreService.webURL("javascript:alert(1)") == nil)
        #expect(GRPCCoreService.webURL("https:///no-host") == nil)
    }
}
