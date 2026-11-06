import Foundation
import Observation

/// Updates by a click (B50): checks GitHub Releases at launch and once a
/// day, offers the newest version the build may take (`UpdatePolicy`), and on
/// Update downloads, checks, installs and restarts. Nothing installs by itself.
@MainActor @Observable
final class UpdateCenter {
    enum State: Equatable {
        case idle
        case available(UpdateRelease)
        case downloading(UpdateRelease, received: Int64, total: Int64)
        case installing(UpdateRelease)
        /// The app was replaced but quitting was cancelled (unsaved edits, a
        /// local run): it restarts into the new version when it quits.
        case restartPending(UpdateRelease)
        case failed(UpdateRelease, String)
        case outsideApplications(UpdateRelease)

        /// The release the state is about, nil when there is none.
        var release: UpdateRelease? {
            switch self {
            case .idle: nil
            case let .available(r), let .downloading(r, _, _), let .installing(r), let .restartPending(r),
                 let .failed(r, _), let .outsideApplications(r): r
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var isChecking = false
    private(set) var lastChecked: Date?
    /// Why the last Check for Updates failed; automatic checks stay silent.
    private(set) var checkError: String?

    var checksAutomatically: Bool {
        didSet {
            defaults.set(checksAutomatically, forKey: Keys.automatic)
            checksAutomatically ? startAutomaticChecks() : stopAutomaticChecks()
        }
    }

    var getsBetas: Bool {
        didSet { defaults.set(getsBetas, forKey: Keys.betas) }
    }

    let build: RunnirBuild
    let current: UpdateVersion?
    /// Quits the app; the installer's waiting process opens the new one.
    var quit: @MainActor () -> Void = {}

    private let feed: any UpdateFeed
    private let installer: any UpdateInstalling
    private let block: @MainActor () -> UpdateBlock?
    private let defaults: UserDefaults
    private let now: () -> Date
    private var work: Task<Void, Never>?
    private var automatic: Task<Void, Never>?

    private enum Keys {
        static let automatic = "updates.checksAutomatically"
        static let betas = "updates.getsBetas"
        static let lastChecked = "updates.lastChecked"
    }

    init(build: RunnirBuild, current: UpdateVersion?, feed: any UpdateFeed, installer: any UpdateInstalling,
         block: @escaping @MainActor () -> UpdateBlock?, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.build = build
        self.current = current
        self.feed = feed
        self.installer = installer
        self.block = block
        self.defaults = defaults
        self.now = now
        checksAutomatically = defaults.object(forKey: Keys.automatic) as? Bool ?? true
        getsBetas = defaults.bool(forKey: Keys.betas)
        lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date
    }

    /// Dev and local builds, and a build without a readable version, never update.
    var isEnabled: Bool { UpdatePolicy.updates(build) && current != nil }

    var showsBetaSetting: Bool { current.map { UpdatePolicy.showsBetaSetting(build: build, current: $0) } ?? false }

    private var isBusy: Bool {
        switch state {
        case .downloading, .installing: true
        default: false
        }
    }

    /// Checks now, then once a day, while automatic checks are on.
    func startAutomaticChecks() {
        guard isEnabled, checksAutomatically, automatic == nil else { return }
        automatic = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check(userInitiated: false)
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    func stopAutomaticChecks() {
        automatic?.cancel()
        automatic = nil
    }

    /// Asks GitHub for releases. A failed automatic check says nothing; a
    /// failed Check for Updates keeps its reason for About.
    func check(userInitiated: Bool) async {
        guard isEnabled, let current, !isChecking, !isBusy else { return }
        if case .restartPending = state { return }
        isChecking = true
        if userInitiated { checkError = nil }
        defer { isChecking = false }
        do {
            let releases = try await feed.releases()
            lastChecked = now()
            defaults.set(lastChecked, forKey: Keys.lastChecked)
            checkError = nil
            guard !isBusy else { return }
            if let release = UpdatePolicy.pick(releases, current: current, build: build, betas: getsBetas && showsBetaSetting) {
                // A failure for the same version stays until Try Again.
                if case let .failed(failed, _) = state, failed == release { return }
                state = .available(release)
            } else {
                state = .idle
            }
        } catch {
            if userInitiated { checkError = (error as? UpdateError)?.message ?? "GitHub could not be reached." }
        }
    }

    /// Downloads, checks and installs the offered version, then restarts.
    func update() {
        guard work == nil, let release = state.release else { return }
        switch state {
        case .available, .failed, .outsideApplications: break
        case .restartPending: quit(); return
        default: return
        }
        switch block() {
        case .outsideApplications?:
            state = .outsideApplications(release)
            return
        case .notWritable?:
            state = .failed(release, "Runnir can't write to the folder it is in. Download the new version and move it to Applications.")
            return
        case nil: break
        }
        state = .downloading(release, received: 0, total: release.size ?? 0)
        work = Task { [weak self, installer] in
            var leftover: URL?
            do {
                let zip = try await installer.download(release) { received, total in
                    Task { @MainActor in self?.downloaded(release, received: received, total: total) }
                }
                leftover = zip
                try Task.checkCancellation()
                self?.state = .installing(release)
                let app = try await installer.prepare(zip, for: release)
                try Task.checkCancellation()
                try installer.install(app)
                installer.discard(zip)
                leftover = nil
                // The new app is in place now; without the waiting process
                // the user opens it after quitting.
                try? installer.relaunchAfterExit()
                self?.work = nil
                self?.state = .restartPending(release)
                self?.quit()
            } catch {
                if let leftover { installer.discard(leftover) }
                self?.work = nil
                if error is CancellationError {
                    self?.state = .available(release)
                } else {
                    let message = (error as? UpdateError)?.message ?? error.localizedDescription
                    self?.state = .failed(release, "\(message) Nothing was changed.")
                }
            }
        }
    }

    /// Stops a download; checking and installing finish once started.
    func cancel() {
        guard case .downloading = state else { return }
        work?.cancel()
    }

    private func downloaded(_ release: UpdateRelease, received: Int64, total: Int64) {
        guard case let .downloading(current, _, known) = state, current == release else { return }
        state = .downloading(release, received: received, total: total > 0 ? total : known)
    }
}
