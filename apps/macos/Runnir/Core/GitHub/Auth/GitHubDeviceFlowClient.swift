import Foundation

/// A device authorization the user completes in the browser.
struct DeviceAuthorization: Equatable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let expiresIn: Duration
    let interval: Duration
}

/// One answer while polling for the token.
enum DeviceTokenPoll: Equatable, Sendable {
    case authorized(token: String)
    case pending
    /// GitHub asks to poll less often; `interval` is the new minimum when given.
    case slowDown(interval: Duration?)
    case expired
    case denied
}

enum DeviceFlowError: Error, Equatable, Sendable {
    /// The app registration does not allow the Device Flow, or the client id is wrong.
    case notConfigured
    case network
    case rateLimited
    case invalidResponse
    case rejected(String)
}

protocol DeviceFlowServicing: Sendable {
    func requestAuthorization() async throws -> DeviceAuthorization
    func poll(deviceCode: String) async throws -> DeviceTokenPoll
}

/// GitHub's OAuth Device Flow for the registered GitHub App. Uses only the
/// public client id; no client secret exists in the app. Never logs tokens.
struct GitHubDeviceFlowClient: DeviceFlowServicing {
    let configuration: GitHubAppConfiguration
    var urlSession: URLSession = .shared

    func requestAuthorization() async throws -> DeviceAuthorization {
        let response: CodeResponse = try await post(configuration.deviceCodeURL, form: [
            "client_id": configuration.clientID,
        ])
        if let error = response.error { throw Self.map(error) }
        guard let deviceCode = response.device_code, let userCode = response.user_code,
              let uri = response.verification_uri, let url = URL(string: uri), url.scheme == "https",
              let expiresIn = response.expires_in, expiresIn > 0 else {
            throw DeviceFlowError.invalidResponse
        }
        return DeviceAuthorization(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: url,
            expiresIn: .seconds(expiresIn),
            interval: .seconds(max(response.interval ?? 5, 1))
        )
    }

    func poll(deviceCode: String) async throws -> DeviceTokenPoll {
        let response: TokenResponse = try await post(configuration.accessTokenURL, form: [
            "client_id": configuration.clientID,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ])
        if let token = response.access_token, !token.isEmpty { return .authorized(token: token) }
        switch response.error {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown(interval: response.interval.map { .seconds($0) })
        case "expired_token": return .expired
        case "access_denied": return .denied
        case let error?: throw Self.map(error)
        case nil: throw DeviceFlowError.invalidResponse
        }
    }

    // MARK: Transport

    private func post<Response: Decodable>(_ url: URL, form: [String: String]) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.encode(form)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw DeviceFlowError.network
        }
        guard let http = response as? HTTPURLResponse else { throw DeviceFlowError.invalidResponse }
        if http.statusCode == 429 || (http.statusCode == 403 && http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0") {
            throw DeviceFlowError.rateLimited
        }
        // GitHub reports flow errors as 200 with an "error" field; other
        // statuses carry the same JSON shape, so decode before judging.
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw http.statusCode >= 500 ? DeviceFlowError.network : DeviceFlowError.invalidResponse
        }
        return decoded
    }

    static func encode(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = form.keys.sorted().map { key in
            let value = form[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(key)=\(value)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    static func map(_ error: String) -> DeviceFlowError {
        switch error {
        case "device_flow_disabled", "incorrect_client_credentials", "unsupported_grant_type": .notConfigured
        default: .rejected(error)
        }
    }

    // Field names follow GitHub's JSON.
    private struct CodeResponse: Decodable {
        let device_code: String?
        let user_code: String?
        let verification_uri: String?
        let expires_in: Int?
        let interval: Int?
        let error: String?
    }

    private struct TokenResponse: Decodable {
        let access_token: String?
        let error: String?
        let interval: Int?
    }
}
