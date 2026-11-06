import Foundation
import Observation

/// Updates by a click (B50): checks GitHub Releases at launch and once a
/// day and offers the newest version the build may take (`UpdatePolicy`).
/// Download fetches it and checks its signature while Runnir keeps working;
/// Update quits, and the app is replaced only once quitting goes ahead, then
/// opens again. Nothing installs by itself.
@MainActor @Observable
final class UpdateCenter {
    enum State: Equatable {
        case idle
        case available(UpdateRelease)
        case downloading(UpdateRelease, received: Int64, total: Int64)
        /// Unpacking the download and checking its signature.
        case verifying(UpdateRelease)
        /// Downloaded and checked; the app on disk is unchanged until Update.
        case ready(UpdateRelease)
        case failed(UpdateRelease, String)
        case outsideApplications(UpdateRelease)

        /// The release the state is about, nil when there is none.
        var release: UpdateRelease? {
            switch self {
            case .idle: nil
            case let .available(r), let .downloading(r, _, _), let .verifying(r), let .ready(r),
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
    /// Quits the app through its usual path; `finishOnQuit` installs.
    var quit: @MainActor () -> Void = {}
    /// Update was clicked: the checked app replaces this one when it quits.
    private(set) var installsOnQuit = false

    private let feed: any UpdateFeed
    private let installer: any UpdateInstalling
    private let block: @MainActor () -> UpdateBlock?
    private let defaults: UserDefaults
    private let now: () -> Date
    private var work: Task<Void, Never>?
    private var automatic: Task<Void, Never>?
    /// The checked app of the `ready` release.
    private var staged: URL?
    /// Why replacing the app failed while Runnir quit, for the version it
    /// was: shown when that version is offered again.
    private var installFailure: [String: String]?

    private enum Keys {
        static let automatic = "updates.checksAutomatically"
        static let betas = "updates.getsBetas"
        static let lastChecked = "updates.lastChecked"
        static let installFailure = "updates.installFailure"
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
        installFailure = defaults.dictionary(forKey: Keys.installFailure) as? [String: String]
    }

    /// Dev and local builds, and a build without a readable version, never update.
    var isEnabled: Bool { UpdatePolicy.updates(build) && current != nil }

    var showsBetaSetting: Bool { current.map { UpdatePolicy.showsBetaSetting(build: build, current: $0) } ?? false }

    private var isBusy: Bool {
        switch state {
        case .downloading, .verifying, .ready: true
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
                if let failure = installFailure, failure["tag"] == release.tag, let message = failure["message"] {
                    state = .failed(release, message)
                } else {
                    state = .available(release)
                }
            } else {
                state = .idle
            }
        } catch {
            if userInitiated { checkError = (error as? UpdateError)?.message ?? "GitHub could not be reached." }
        }
    }

    /// Downloads the offered version and checks it; the app is unchanged
    /// until Update.
    func download() {
        guard work == nil, let release = state.release else { return }
        switch state {
        case .available, .failed, .outsideApplications: break
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
        installFailure = nil
        defaults.removeObject(forKey: Keys.installFailure)
        state = .downloading(release, received: 0, total: release.size ?? 0)
        work = Task { [weak self, installer] in
            var leftover: URL?
            do {
                let zip = try await installer.download(release) { received, total in
                    Task { @MainActor in self?.downloaded(release, received: received, total: total) }
                }
                leftover = zip
                try Task.checkCancellation()
                self?.state = .verifying(release)
                let app = try await installer.prepare(zip, for: release)
                guard let self else { installer.discard(app); return }
                work = nil
                staged = app
                state = .ready(release)
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

    /// Quits Runnir to install the checked version; `finishOnQuit` replaces
    /// the app once quitting goes ahead.
    func update() {
        guard case .ready = state, staged != nil else { return }
        installsOnQuit = true
        quit()
    }

    /// Quitting was cancelled (unsaved edits, a local run): nothing changes
    /// and Update stays offered.
    func quitCancelled() {
        installsOnQuit = false
    }

    /// Runnir is quitting: after Update, puts the checked app in place of
    /// this one and opens it once this process has ended; otherwise drops the
    /// download. A failure is shown when the version is offered again.
    func finishOnQuit() {
        work?.cancel()
        guard let app = staged else { return }
        staged = nil
        defer { installer.discard(app) }
        guard installsOnQuit, let release = state.release else { return }
        do {
            try installer.install(app)
        } catch {
            let message = (error as? UpdateError)?.message ?? error.localizedDescription
            defaults.set(["tag": release.tag, "message": "\(message) Nothing was changed."], forKey: Keys.installFailure)
        }
        // Without the waiting process the user opens Runnir again.
        try? installer.relaunchAfterExit()
    }

    /// Stops a download; checking the signature finishes once started.
    func cancel() {
        guard case .downloading = state else { return }
        work?.cancel()
    }

    private func downloaded(_ release: UpdateRelease, received: Int64, total: Int64) {
        guard case let .downloading(current, _, known) = state, current == release else { return }
        state = .downloading(release, received: received, total: total > 0 ? total : known)
    }
}
