import Foundation

/// A published Runnir release with the app's zip (B50).
struct UpdateRelease: Equatable, Sendable {
    let version: UpdateVersion
    let tag: String
    /// `Runnir-<tag>.zip`, the notarized app the release workflow publishes.
    let zip: URL
    /// The release on GitHub: What's New and Download open it.
    let page: URL
    let size: Int64?
}

/// Where Runnir learns about releases.
protocol UpdateFeed: Sendable {
    func releases() async throws -> [UpdateRelease]
}

/// GitHub Releases of dil-eight/runnir, asked without a token: GitHub sees
/// only an anonymous request with Runnir's user agent.
struct GitHubUpdateFeed: UpdateFeed {
    static let endpoint = URL(string: "https://api.github.com/repos/dil-eight/runnir/releases?per_page=30")!
    var session: URLSession = .shared
    var appVersion: String

    func releases() async throws -> [UpdateRelease] {
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Runnir/\(appVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.feed("GitHub answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return try Self.decode(data)
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int64?
        }
        let tag_name: String
        let draft: Bool
        let html_url: URL
        let assets: [Asset]
    }

    /// Published releases whose tag parses and that carry `Runnir-<tag>.zip`.
    static func decode(_ data: Data) throws -> [UpdateRelease] {
        let releases: [Release]
        do { releases = try JSONDecoder().decode([Release].self, from: data) } catch { throw UpdateError.feed("GitHub's answer could not be read") }
        return releases.compactMap { r in
            guard !r.draft, let version = UpdateVersion(r.tag_name),
                  let zip = r.assets.first(where: { $0.name == "Runnir-\(r.tag_name).zip" }) else { return nil }
            return UpdateRelease(version: version, tag: r.tag_name, zip: zip.browser_download_url, page: r.html_url, size: zip.size)
        }
    }
}

/// Why an update stopped; the message is shown as it is.
enum UpdateError: Error, Equatable {
    case feed(String)
    case download(String)
    case refused(String)
    case install(String)

    var message: String {
        switch self {
        case let .feed(m), let .download(m), let .refused(m), let .install(m): m
        }
    }
}
