import Foundation
import Testing
@testable import Runnir

struct CoreClientTests {
    @Test
    func bundledHelperRoundTrip() async throws {
        let result = try await CoreClient.bundled.version()
        #expect(!result.version.isEmpty)
        #expect(result.protocolVersion == 1)
    }

    @Test
    func rejectsMissingExecutable() async {
        let client = CoreClient(transport: StdioCoreTransport(executableURL: URL(fileURLWithPath: "/nonexistent/runnir-core")))
        await #expect(throws: CoreIPCError.helperUnavailable) { try await client.version() }
    }

    @Test
    func rejectsIncompatibleProtocol() async {
        let client = CoreClient(transport: ReplyTransport(mode: .incompatible))
        await #expect(throws: CoreIPCError.incompatibleProtocol(2)) { try await client.version() }
    }

    @Test
    func rejectsMismatchedID() async {
        let client = CoreClient(transport: ReplyTransport(mode: .wrongID))
        await #expect(throws: CoreIPCError.invalidResponse) { try await client.version() }
    }

    @Test
    func mapsRemoteErrors() async {
        let client = CoreClient(transport: ReplyTransport(mode: .remoteError))
        await #expect(throws: CoreIPCError.remote(-32601)) { try await client.version() }
    }
}

private struct ReplyTransport: CoreTransport {
    enum Mode: Sendable { case incompatible, wrongID, remoteError }
    let mode: Mode

    func exchange(_ request: Data) async throws -> Data {
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": object["id"]!]
        switch mode {
        case .incompatible:
            reply["result"] = ["version": "test", "protocolVersion": 2]
        case .wrongID:
            reply["id"] = "different"
            reply["result"] = ["version": "test", "protocolVersion": 1]
        case .remoteError:
            reply["error"] = ["code": -32601, "message": "Method not found"]
        }
        return try JSONSerialization.data(withJSONObject: reply)
    }
}
