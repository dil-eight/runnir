import Foundation

/// A version of Runnir as its tags name it (B47): `v0.2.0`, `v0.2.0-alpha.3`,
/// `v0.2.0-beta.1`. Ordered by semantic version precedence, so
/// 0.2.0-alpha.3 < 0.2.0-beta.1 < 0.2.0 < 0.2.1-alpha.1 (B50).
struct UpdateVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    enum Stage: Int, Comparable, Sendable {
        case alpha, beta
        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    struct Prerelease: Comparable, Hashable, Sendable {
        let stage: Stage
        let number: Int
        static func < (a: Prerelease, b: Prerelease) -> Bool { (a.stage, a.number) < (b.stage, b.number) }
    }

    let major: Int
    let minor: Int
    let patch: Int
    /// nil for a release.
    let prerelease: Prerelease?

    init(major: Int, minor: Int, patch: Int, prerelease: Prerelease? = nil) {
        (self.major, self.minor, self.patch, self.prerelease) = (major, minor, patch, prerelease)
    }

    /// Parses a tag or a bundle version, with or without the leading v. Any
    /// other suffix than -alpha.N or -beta.N does not parse.
    init?(_ text: String) {
        var text = Substring(text.trimmingCharacters(in: .whitespaces))
        if text.first == "v" { text = text.dropFirst() }
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard numbers.count == 3, let major = numbers[0], let minor = numbers[1], let patch = numbers[2],
              major >= 0, minor >= 0, patch >= 0 else { return nil }
        var prerelease: Prerelease?
        if parts.count == 2 {
            let pre = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard pre.count == 2, let number = Int(pre[1]), number >= 0 else { return nil }
            switch pre[0] {
            case "alpha": prerelease = Prerelease(stage: .alpha, number: number)
            case "beta": prerelease = Prerelease(stage: .beta, number: number)
            default: return nil
            }
        }
        self.init(major: major, minor: minor, patch: patch, prerelease: prerelease)
    }

    var isRelease: Bool { prerelease == nil }

    /// The same major, minor and patch: 0.2.0-beta.1 and 0.2.0-beta.2.
    func sameCore(as other: UpdateVersion) -> Bool { (major, minor, patch) == (other.major, other.minor, other.patch) }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        guard let prerelease else { return core }
        return "\(core)-\(prerelease.stage == .alpha ? "alpha" : "beta").\(prerelease.number)"
    }

    static func < (a: UpdateVersion, b: UpdateVersion) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) { return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil), (nil, _): return false // a release ranks above its pre-releases
        case (_, nil): return true
        case let (x?, y?): return x < y
        }
    }
}

/// Which versions a build is offered (B50).
enum UpdatePolicy {
    static let betaSettingFrom = UpdateVersion(major: 1, minor: 0, patch: 0)

    /// Dev and local builds are apps of their own and never update.
    static func updates(_ build: RunnirBuild) -> Bool { build == .alpha || build == .beta || build == .release }

    /// "Get beta versions" is shown only in a release build of 1.0.0 or later.
    static func showsBetaSetting(build: RunnirBuild, current: UpdateVersion) -> Bool {
        build == .release && current >= betaSettingFrom
    }

    /// Alpha: any newer version. Beta: a newer beta of the same version, or a
    /// newer release. Release: newer releases, and newer betas when the user
    /// asked for them. Never an equal or lower version.
    static func allows(_ candidate: UpdateVersion, current: UpdateVersion, build: RunnirBuild, betas: Bool) -> Bool {
        guard candidate > current else { return false }
        switch build {
        case .dev, .local: return false
        case .alpha: return true
        case .beta: return candidate.isRelease || (candidate.prerelease?.stage == .beta && candidate.sameCore(as: current))
        case .release:
            return candidate.isRelease
                || (betas && showsBetaSetting(build: build, current: current) && candidate.prerelease?.stage == .beta)
        }
    }

    /// The newest release the build may take, if any.
    static func pick(_ releases: [UpdateRelease], current: UpdateVersion, build: RunnirBuild, betas: Bool) -> UpdateRelease? {
        releases.filter { allows($0.version, current: current, build: build, betas: betas) }.max { $0.version < $1.version }
    }
}
