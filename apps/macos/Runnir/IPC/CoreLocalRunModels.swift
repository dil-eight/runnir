import Foundation

/// App-facing models of local runs: the tools they need, the reviewed plan
/// and a run's bounded output. Mapped from the wire types in `GRPCCoreService`.

enum CoreToolState: Equatable, Sendable {
    /// Present, answering and new enough.
    case found
    /// Not installed, or no engine is configured.
    case missing
    /// An engine is configured but does not answer.
    case stopped
    /// Too old, or an engine on another computer.
    case unsupported
    case failed
    case unknown
}

struct CoreToolStatus: Equatable, Sendable {
    var state: CoreToolState
    var version = ""
    var path = ""
    var detail = ""
    /// Newer than the act version local runs were verified with.
    var untested = false
}

struct CoreContainerEngine: Equatable, Sendable {
    var state: CoreToolState
    /// OrbStack, Docker Desktop, Colima, Rancher Desktop, Podman or Docker Engine.
    var name = ""
    var context = ""
    var endpoint = ""
    var local = true
    var version = ""
    var architecture = ""
    var cpus = 0
    var memoryBytes: UInt64 = 0
    var detail = ""
}

struct CoreToolReadiness: Equatable, Sendable {
    var bundledAct: CoreToolStatus
    var installedAct: CoreToolStatus
    var dockerCLI: CoreToolStatus
    var engine: CoreContainerEngine
    var checkedAt: Date?
    /// The act version Runnir bundles and verified local runs with.
    var testedActVersion = ""
    var minimumActVersion = ""

    /// The act a run uses: the installed one when the user opted in and it
    /// is usable, the bundled one otherwise. Mirrors the Core's choice.
    func act(useInstalled: Bool) -> (status: CoreToolStatus, installed: Bool) {
        if useInstalled, installedAct.state == .found { return (installedAct, true) }
        return (bundledAct, false)
    }
}

enum CoreLocalJobSupport: Equatable, Sendable {
    case supported
    /// act skips the job or it cannot work locally.
    case unsupported
    /// act decides when the job starts.
    case unknown
}

struct CoreLocalRunJob: Equatable, Identifiable, Sendable {
    let id: String
    var name = ""
    var runsOn: [String] = []
    var image = ""
    var support: CoreLocalJobSupport
    var reason = ""
}

struct CoreLocalRunImage: Equatable, Sendable {
    let reference: String
    /// Already in the engine; otherwise act downloads it.
    let present: Bool
}

struct CoreLocalRunPlan: Equatable, Sendable {
    var workflowID: String
    var workflowName = ""
    var events: [String] = []
    var event = ""
    /// The chosen job; empty runs every job.
    var jobID = ""
    var jobs: [CoreLocalRunJob] = []
    var images: [CoreLocalRunImage] = []
    var secrets: [String] = []
    var notes: [String] = []
    /// Why the run cannot start now.
    var blockers: [String] = []
    var cpus = 0
    var memoryBytes: UInt64 = 0
    var timeoutSeconds = 0
    var actVersion = ""
    var installedAct = false
    var engineName = ""
    var engineContext = ""
}

struct CorePreparedLocalRun: Equatable, Sendable {
    let readiness: CoreToolReadiness
    let plan: CoreLocalRunPlan
    /// nil when the plan has blockers.
    let confirmationID: String?
    let expiresAt: Date?
}

enum CoreLocalRunPhase: Equatable, Sendable {
    case queued, running, stopping, cleaningUp, finished, unknown
}

enum CoreLocalJobState: Equatable, Sendable {
    case waiting, running, succeeded, failed, skipped, unsupported, cancelled, notRun, unknown
}

struct CoreLocalRunJobStatus: Equatable, Identifiable, Sendable {
    let id: String
    var name = ""
    var state: CoreLocalJobState
    var reason = ""
    var startedAt: Date?
    var finishedAt: Date?
}

struct CoreLocalRunLine: Equatable, Identifiable, Sendable {
    let sequence: UInt64
    /// Empty for act's own messages.
    let jobID: String
    let text: String
    let isError: Bool

    var id: UInt64 { sequence }
}

struct CoreLocalRunOutput: Equatable, Sendable {
    let executionID: String
    let repositoryID: String
    let state: CoreExecutionState
    let phase: CoreLocalRunPhase
    let lines: [CoreLocalRunLine]
    /// Lines after the requested sequence were dropped to stay in the bound.
    let discarded: Bool
    let lastSequence: UInt64
    let jobs: [CoreLocalRunJobStatus]
    let plan: CoreLocalRunPlan
    let startedAt: Date?
    let finishedAt: Date?
    /// act's exit code; nil until it exits, or when it was killed.
    let exitCode: Int?
    let message: String?
    let cleanupProblem: String?
}
