# Offline Workflow Validation Slice

Status: proposed follow-on slice after the window/registry foundation, updated 2026-10-14. Use the shared workspace identity and storage/access boundaries from ADR 0003. This document does not implement the slice.

## User Outcome

Open an existing local repository, choose a workflow and see its YAML/job summary and actionlint diagnostics without login, network access, commits or pushes. This delivers B01-B03 and a useful subset of FR-05. Editing/save and local execution are subsequent slices; this alone does not complete FR-05 or v0.1.

## Why Start Here

The SwiftUI/Go version bridge already exists. Offline validation exercises a real domain operation, repository scope, the native UI and a bounded process adapter without waiting for OAuth registration. It also establishes the inspection boundary needed by editing, typed workflow inputs and later local execution.

## Implementation Boundary

Swift owns the folder picker, security-scoped access, selected-workflow presentation and loading/error state. Keep current Xcode/source paths and GitHub services.

Prefer reading bounded workflow bytes through the native scoped-file service and passing them to a typed Go validation/inspection service. That avoids granting a version-only helper arbitrary repository access. Preserve a relative display path in diagnostics; reject client paths that attempt filesystem access. If validator context requires reading related repository files, design explicit capabilities before broadening the scope.

Go owns deterministic workflow inspection, actionlint invocation and diagnostic mapping. Add small protocol-backed services at the actual boundary; no speculative provider framework. The validator executable must come from an approved, versioned source rather than a repo-controlled path. Prefer a reviewed bundled validator for repeatable startup; verify license/distribution/signed launch before choosing this packaging.

Validation uses documented structured output/stdin support and a fixed argument policy, with time/output limits and no uncontrolled external checks. Never invoke local actions, workflow commands or executable configuration to inspect a workflow. Missing tools or unavailable checks are explicit states.

## Proposed Contract Work

Keep core.v1.version intact. Define and test a new versioned validation method only when implementing it; do not advertise it as supported now.

Input should contain request identity, bounded workflow source and a relative diagnostic label. Output should contain validator/version, valid/invalid/incomplete state and structured severity/message/file/line/column findings. Distinguish an invalid workflow from tool absence, unsupported context, transport failure and validator failure. Do not add a general command-string parameter.

The existing stdio transport is a small one-shot proof of concept. Extend its payload/time/output policy for validation based on measured requirements; execution streaming is not part of this slice. Add compatibility tests before changing the contract.

## Reviewable Implementation Steps

1. Add native selected-folder access and bounded .github/workflows discovery with scope tests; verify signed entitlement behavior.
2. Add valid/invalid workflow fixtures, Go validator adapter and diagnostics mapping with injected process failures.
3. Define validation IPC envelopes/schema and add a real Swift-to-Go validation integration test.
4. Add a compact native Local Workspace view for selection, read-only YAML/job inspection and diagnostics; retain existing operational sections.
5. Verify the end-to-end offline flow and record limitations; then propose editing/save as the next vertical slice.

## Acceptance Evidence

- [ ] Select/cancel/revoke a repository; no access to unrelated files or secrets.
- [ ] Discover both YAML extensions with limits, no-files state and safe handling of symlinks/worktree markers.
- [ ] Valid fixture passes; invalid fixture yields file/line/column when available; unsupported analysis is not called success.
- [ ] Missing actionlint, denial, nonzero exit, timeout and oversized output yield actionable states.
- [ ] Validation never executes repository hooks/scripts or accesses GitHub/network.
- [ ] A real selected fixture validates through Swift and the bundled Go helper with GitHub disconnected.
- [ ] Build, unit/Core checks and signed-scope verification pass for the affected boundaries.

No OAuth, presets, run inspector, Docker/act execution, AI, MCP, cloud setup or licensing change in this slice. It is a proposal for the next implementation iteration, not authorization to begin a broad refactor.
