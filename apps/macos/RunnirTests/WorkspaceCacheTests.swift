import Foundation
import Testing
@testable import Runnir

@Suite struct CoreLaunchArgumentTests {
    @Test func theDataDirectoryIsPassedToTheCore() {
        let arguments = ProcessCoreLauncher.arguments(socketPath: "/tmp/s.sock",
                                                      dataDirectory: URL(fileURLWithPath: "/Users/me/Library/Application Support/Runnir"))
        #expect(arguments == ["serve", "--socket", "/tmp/s.sock", "--exit-on-stdin-eof", "--client-secret-stdin",
                              "--data-dir", "/Users/me/Library/Application Support/Runnir"])
        #expect(!ProcessCoreLauncher.arguments(socketPath: "/tmp/s.sock", dataDirectory: nil).contains("--data-dir"))
    }
}
