import Foundation
import Testing
@testable import Runnir

/// Answers each request with the next canned response and records the request.
private final class DeviceFlowURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [(status: Int, body: String, headers: [String: String])] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [String] = []
    nonisolated(unsafe) static var failWithNetworkError = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        Self.bodies.append(Self.body(of: request))
        if Self.failWithNetworkError {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let next = Self.responses.isEmpty ? (status: 500, body: "", headers: [:]) : Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: next.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func client(_ responses: [(Int, String)], headers: [String: String] = [:]) -> GitHubDeviceFlowClient {
        self.responses = responses.map { (status: $0.0, body: $0.1, headers: headers) }
        requests = []
        bodies = []
        failWithNetworkError = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeviceFlowURLProtocol.self]
        return GitHubDeviceFlowClient(configuration: .runnirDesktop, urlSession: URLSession(configuration: configuration))
    }
}

@Suite(.serialized)
struct GitHubDeviceFlowClientTests {
    @Test
    func requestsACodeWithOnlyTheClientID() async throws {
        let client = DeviceFlowURLProtocol.client([(200, #"{"device_code":"dc","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":899,"interval":5}"#)])
        let authorization = try await client.requestAuthorization()

        #expect(authorization == DeviceAuthorization(deviceCode: "dc", userCode: "ABCD-1234",
                                                     verificationURL: URL(string: "https://github.com/login/device")!,
                                                     expiresIn: .seconds(899), interval: .seconds(5)))
        let request = try #require(DeviceFlowURLProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://github.com/login/device/code")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(DeviceFlowURLProtocol.bodies.first == "client_id=Iv23liopD8rc8O16F7gK")
    }

    @Test
    func rejectsANonHTTPSVerificationPage() async {
        let client = DeviceFlowURLProtocol.client([(200, #"{"device_code":"dc","user_code":"X","verification_uri":"http://evil.test","expires_in":900,"interval":5}"#)])
        await #expect(throws: DeviceFlowError.invalidResponse) { _ = try await client.requestAuthorization() }
    }

    @Test
    func reportsADisabledDeviceFlowAsNotConfigured() async {
        let client = DeviceFlowURLProtocol.client([(200, #"{"error":"device_flow_disabled"}"#)])
        await #expect(throws: DeviceFlowError.notConfigured) { _ = try await client.requestAuthorization() }
    }

    @Test
    func mapsEveryPollAnswer() async throws {
        let cases: [(String, DeviceTokenPoll)] = [
            (#"{"error":"authorization_pending"}"#, .pending),
            (#"{"error":"slow_down","interval":10}"#, .slowDown(interval: .seconds(10))),
            (#"{"error":"slow_down"}"#, .slowDown(interval: nil)),
            (#"{"error":"expired_token"}"#, .expired),
            (#"{"error":"access_denied"}"#, .denied),
            (#"{"access_token":"ghu_secret","token_type":"bearer"}"#, .authorized(token: "ghu_secret")),
        ]
        for (body, expected) in cases {
            let client = DeviceFlowURLProtocol.client([(200, body)])
            #expect(try await client.poll(deviceCode: "dc") == expected)
        }
        let body = try #require(DeviceFlowURLProtocol.bodies.first)
        #expect(body.contains("device_code=dc"))
        #expect(body.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"))
        #expect(!body.contains("client_secret"))
    }

    @Test
    func mapsTransportFailures() async {
        let limited = DeviceFlowURLProtocol.client([(429, "")])
        await #expect(throws: DeviceFlowError.rateLimited) { _ = try await limited.poll(deviceCode: "dc") }

        let broken = DeviceFlowURLProtocol.client([(502, "<html>")])
        await #expect(throws: DeviceFlowError.network) { _ = try await broken.poll(deviceCode: "dc") }

        let offline = DeviceFlowURLProtocol.client([])
        DeviceFlowURLProtocol.failWithNetworkError = true
        await #expect(throws: DeviceFlowError.network) { _ = try await offline.poll(deviceCode: "dc") }

        let unknown = DeviceFlowURLProtocol.client([(200, #"{"error":"something_new"}"#)])
        await #expect(throws: DeviceFlowError.rejected("something_new")) { _ = try await unknown.poll(deviceCode: "dc") }
    }
}
