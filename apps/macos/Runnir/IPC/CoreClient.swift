import Foundation

struct CoreVersion: Codable, Equatable, Sendable {
    let version: String
    let protocolVersion: Int
}

enum CoreIPCError: Error, Equatable, Sendable {
    case helperUnavailable
    case timedOut
    case processFailed
    case invalidResponse
    case incompatibleProtocol(Int)
    case remote(Int)
}

protocol CoreTransport: Sendable {
    func exchange(_ request: Data) async throws -> Data
}

struct CoreClient: Sendable {
    let transport: any CoreTransport

    static var bundled: CoreClient {
        CoreClient(transport: StdioCoreTransport(
            executableURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/runnir-core")
        ))
    }

    func version() async throws -> CoreVersion {
        let id = UUID().uuidString
        let request = VersionRequest(id: id)
        let data = try await transport.exchange(JSONEncoder().encode(request))
        let response: VersionResponse
        do {
            response = try JSONDecoder().decode(VersionResponse.self, from: data)
        } catch {
            throw CoreIPCError.invalidResponse
        }
        guard response.jsonrpc == "2.0", response.id == id,
              (response.result != nil) != (response.error != nil) else {
            throw CoreIPCError.invalidResponse
        }
        if let error = response.error { throw CoreIPCError.remote(error.code) }
        guard let result = response.result, !result.version.isEmpty else {
            throw CoreIPCError.invalidResponse
        }
        guard result.protocolVersion == 1 else {
            throw CoreIPCError.incompatibleProtocol(result.protocolVersion)
        }
        return result
    }
}

private struct VersionRequest: Encodable {
    let jsonrpc = "2.0"
    let id: String
    let method = "core.v1.version"
}

private struct VersionResponse: Decodable {
    let jsonrpc: String
    let id: String
    let result: CoreVersion?
    let error: RemoteError?

    struct RemoteError: Decodable {
        let code: Int
        let message: String
    }
}
