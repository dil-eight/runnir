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
    /// A macOS runner on a Mac: the job runs on this Mac in the macOS
    /// sandbox, not in a container. Never ticked by default.
    case host
}

struct CoreLocalRunJob: Equatable, Identifiable, Sendable {
    let id: String
    var name = ""
    var runsOn: [String] = []
    var image = ""
    var support: CoreLocalJobSupport
    /// Why it cannot run here, or what decides it.
    var reason = ""
    /// The jobs it needs, by id.
    var needs: [String] = []
    /// Ticked: it runs.
    var selected = false
    /// Why the scenario skips it on GitHub; empty when it runs there.
    var skipped = ""
}

/// Why a workflow is in a local run's scenario.
enum CoreLocalRunLaneKind: Equatable, Sendable {
    /// The scenario's event starts it.
    case direct
    /// workflow_run starts it after another lane.
    case chained
    /// It starts only by hand.
    case manual
    /// The scenario does not start it.
    case outside
}

/// One workflow of a local run: act runs it on its own, after the lanes
/// before it, with only its ticked jobs and the jobs they need.
struct CoreLocalRunLane: Equatable, Identifiable, Sendable {
    /// The workflow's path, as in `Workflow.id`.
    let workflowID: String
    var workflowName = ""
    var kind: CoreLocalRunLaneKind = .direct
    /// The event act gets for it.
    var event = ""
    /// What starts it in the scenario: "pull_request · paths ✓".
    var why = ""
    /// Why the scenario does not start it, for an outside lane.
    var skipped = ""
    /// The workflow path of the lane a chained lane follows.
    var after = ""
    var selected = false
    /// Why the file does not parse; such a lane cannot be ticked.
    var parseError = ""
    var jobs: [CoreLocalRunJob] = []

    var id: String { workflowID }
    /// The name GitHub shows: the workflow's name, else its file.
    var title: String { workflowName.isEmpty ? URL(fileURLWithPath: workflowID).lastPathComponent : workflowName }
}

struct CoreLocalRunImage: Equatable, Sendable {
    let reference: String
    /// Already in the engine; otherwise act downloads it.
    let present: Bool
}

struct CoreLocalRunPlan: Equatable, Sendable {
    /// The branch's scenarios, the default first, and the one planned.
    var scenarios: [CoreScenario] = []
    var scenario: CoreScenario?
    /// Every workflow: the scenario's in run order, then those it leaves out.
    var lanes: [CoreLocalRunLane] = []
    var images: [CoreLocalRunImage] = []
    var secrets: [String] = []
    var variables: [String] = []
    /// A workflow reads secrets it does not name; only listed ones are passed.
    var unnamedSecrets = false
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
    /// The most a run gets here: the engine's CPUs and memory (0 when it did
    /// not say) and 6 hours.
    var maxCPUs = 0
    var maxMemoryBytes: UInt64 = 0
    var maxTimeoutSeconds = 0
    /// The limits are the workspace's own, not the defaults.
    var ownLimits = false
    /// What the limits risk on this engine; they never block the run.
    var limitWarnings: [String] = []
    /// A line about the engine worth reading without opening the limits.
    var limitNote = ""
    /// The environment whose values the run takes before the Repository's;
    /// empty for the Repository's alone or when the user chooses.
    var environment = ""
    /// Why the user chooses whose values the run takes (act gives every job
    /// of a run the same values); empty when the workflow settles it.
    var environmentChoice = ""
    /// The environments to choose from when `environmentChoice` is set.
    var environments: [String] = []
    /// Ticked jobs that run on this Mac, not in a container ("CI › build").
    var hostJobs: [String] = []
    /// They run without the macOS sandbox, as asked for this run.
    var hostUnsandboxed = false

    var limits: CoreLocalRunLimits { CoreLocalRunLimits(cpus: cpus, memoryBytes: memoryBytes, timeoutSeconds: timeoutSeconds) }

    /// The lanes that run, in run order.
    var selectedLanes: [CoreLocalRunLane] { lanes.filter(\.selected) }
}

/// The jobs ticked in a local run, by workflow path. An empty selection
/// ticks nothing, which the Core refuses with a blocker.
struct CoreLocalRunSelection: Equatable, Sendable {
    var jobs: [String: Set<String>] = [:]

    /// What goes on the wire: every workflow with its ticked jobs, sorted; a
    /// selection of nothing still says so with an empty entry.
    var wire: [(String, [String])] {
        let ticked = jobs.filter { !$0.value.isEmpty }.map { ($0.key, $0.value.sorted()) }.sorted { $0.0 < $1.0 }
        if ticked.isEmpty, let first = jobs.keys.sorted().first { return [(first, [])] }
        return ticked
    }
}

/// CPUs, memory and timeout of a local run, as the Core plans them.
struct CoreLocalRunLimits: Equatable, Sendable {
    var cpus: Int
    var memoryBytes: UInt64
    var timeoutSeconds: Int
}

/// One NAME=value of a .env file, as the Core read it.
struct CoreEnvEntry: Equatable, Sendable {
    /// Upper-cased.
    let name: String
    let value: String
    /// Encrypted by dotenvx; `value` is empty.
    let encrypted: Bool
    let line: Int
}

struct CoreEnvProblem: Equatable, Sendable {
    let line: Int
    let message: String
}

struct CoreEnvFile: Equatable, Sendable {
    let entries: [CoreEnvEntry]
    let problems: [CoreEnvProblem]
}

/// A .env file of a repository's working tree, as the Core found it.
struct CoreRepositoryEnvFile: Equatable, Sendable {
    /// A slash path from the repository's root.
    let path: String
    /// Git ignores it, as it does .env.local.
    let ignored: Bool
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
    /// The workflow the job is in.
    var workflowID = ""
    let jobID: String
    var name = ""
    var state: CoreLocalJobState
    var reason = ""
    var startedAt: Date?
    var finishedAt: Date?

    /// Unique in a run: jobs of two workflows may share an id.
    var id: String { workflowID + "\u{0}" + jobID }

    init(workflowID: String = "", id: String, name: String = "", state: CoreLocalJobState, reason: String = "",
         startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.workflowID = workflowID
        self.jobID = id
        self.name = name
        self.state = state
        self.reason = reason
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

struct CoreLocalRunLine: Equatable, Identifiable, Sendable {
    let sequence: UInt64
    /// The workflow that was running; empty before the first.
    var workflowID = ""
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
    /// The MCP client that started the run; nil for the user.
    var startedBy: String? = nil
}
