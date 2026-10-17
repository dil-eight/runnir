# AI-First DevOps Assistant

Status: future v0.3 product direction, not implemented. The accepted architecture is SwiftUI + Go Core; native provider orchestration would call typed portable Core tools. The current v0.1 is developer-experience-first and has no AI requirement. See [AI architecture](../architecture/ai.md), [roadmap](roadmap.md), and [local offer matching](startup-integrations.md).

Runnir should feel like a local DevOps teammate for GitHub Actions rather than a dashboard with a chat bolted on. The primary surface is a chat that can inspect CI state, explain failures, prepare actions, and hand the user explicit confirmation steps before anything remote or destructive happens.

## Product Principles

- Local-first by default. Repository contents, logs, workflow YAML, branch names, and personal data stay on device unless the user explicitly chooses an external integration.
- Deterministic engines do the facts. Parsing, cost math, workflow graph checks, and permission checks are normal code. The language model explains results and maps natural language into structured proposals.
- Actions are proposals first. Workflow dispatch, cancel, rerun, release, tag, and token operations require a visible confirmation step.
- Every failure explanation cites evidence. AI output for failed runs must link to exact log lines or structured check results.
- The app must degrade gracefully when local AI is unavailable.

## Future Assistant Capabilities

### AI Failure Analysis

The user opens a failed run and asks Runnir to explain it. Runnir fetches logs through GitHub, extracts failing spans locally, and produces an explanation with citations to log lines.

### Natural Language Workflow Launcher

The user can type a request such as "Run staging deployment for the latest successful build". Runnir resolves the repository, workflow, ref, inputs, and artifact references, then displays a dispatch proposal for confirmation.

### AI Workflow Inspector

Runnir parses workflow YAML locally and explains dependencies, skipped jobs, conditions, cache behavior, permissions, and reusable workflow opportunities.

### CI Cost Optimization

Runnir computes job durations, rerun frequency, queue time, cache misses, and redundant work from run history. AI turns the deterministic analysis into prioritized recommendations.

### Workflow Setup Assistant

The user describes a goal, such as building a React Native iOS app on a Mac mini runner. Runnir gathers missing parameters and generates a draft from reviewed templates.

## Apple Foundation Models Direction

On macOS 27 and newer, Runnir should prefer Apple's Foundation Models framework for compatible devices. The framework is presented by Apple as a Swift API for local and cloud-backed models with structured generation, tool calling, image understanding, dynamic profiles, and the `fm` command-line tool. Runnir should wrap this behind an internal assistant runtime protocol so the app can keep a stable privacy contract and offer a non-AI fallback.

## UX Shape

- The intended first screen is Chat/Assistant; the existing dashboard remains until chat ships.
- Sidebar sections remain available for repositories, workflows, runs, artifacts, and settings.
- Chat messages can include structured action cards.
- Action cards show the planned operation, required GitHub scope, affected repository, and whether confirmation is required.
- Read-only analysis can run immediately; remote mutation cannot.
