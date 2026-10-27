# Runnir Design Plan

Status: native implementation started, updated 2026-10-15. Target canvas: [runnir.pen](runnir.pen). Product authority: [MVP specification](../product/specification.md). Manager/splash/workspace shell and read-only browsing now have native counterparts; CI/editor/execution states are not implemented merely because they are drawn.

## Audience And Direction

Developers repeatedly inspecting GitHub Actions, launching published workflows and editing/testing local workflows. Operate mode: native macOS navigation, compact scannable data, direct actions and explicit status. Cold launch shows splash, then eligible restored workspace windows or a singleton Workspace Manager. Dashboard is the default tab within a workspace. No landing page, chat-first MVP, cloud marketplace or decorative analytics dashboard.

Existing brand assets and charcoal/neutral operational styling are visual references. Preserve the brand; establish semantic light/dark tokens before expanding screens. Status colors need distinct symbols/labels, not color-only meaning. Native title bars, menus, tables, split views, sheets and focus behavior take precedence over web conventions.

## Current Canvas Inventory

Reinspected through Pen tools on 2026-10-15. Collaborative content may change; re-read before editing. The earlier inventory was incomplete: MVP frames and reusable components now exist alongside these concepts.

| Existing frame | Observed role | Treatment |
| --- | --- | --- |
| Brand - horizontal logos (m8Pfr) | Light/dark horizontal logo references | Preserve assets and proportions |
| Runnir - Pipeline (v3) (yEidH) | Pipeline/run concept with an assistant dock | Future reference; adapt useful data hierarchy, not AI/artifact-reuse claims, into MVP |
| Runnir - Assistant Home (v2) (p3LtH2) | Earlier AI-first direction | Preserve as future concept; not MVP's home |
| Runnir - Assistant Chat (v4) (ndlJA) | Earlier chat direction | Preserve as future concept; not an implementation requirement |
| S14 splash (QBbtP), degraded (rkx2x) | Startup | Native branding/loading implemented; degraded detail remains backlog |
| S15 Manager populated (a14hzE), empty (wYFz2), opening (u4Noa) | Import/recents | Native import, recents and window actions implemented; broader recovery verification pending |
| S09 workspace (q3DBNS) | Files/editor/pipeline | Native shell/read-only YAML only; no editing/validation/execution yet |
| S03 overview (r8R24), S08 inspector (Xifrq) | Remote data | References only; no fabricated GitHub runs added |

Reusable components exist in the current canvas; map their states during each feature handoff. Native code shares BrandLogo, ProjectLink, adaptive theme tokens and local workflow presentation. Frames are visual specifications, not proof of operational features. This implementation did not modify the Pen document.

## Deliverables

- [Color tokens](color-tokens.md): primitive palette, semantic light/dark roles and native SwiftUI use.
- [Screen and state matrix](screens-and-states.md): 18 design surfaces including report review, shared states, overlays and acceptance frames.
- [Reusable component inventory](reusable-components.md): component boundaries, properties, variants and SwiftUI mapping.
- [Pen production plan](pen-production-plan.md): frame naming, work packages, prototype paths and handoff criteria.

Primary navigation follows the current Pen sidebar: Overview, Workflows, Runs and Workspace. Existing Repositories and Artifacts destinations remain available through the workspace menu during migration. The 18 surfaces include the app shell, detail views and sheets; they are not 18 sidebar entries. Draw a canonical screen per surface and selected meaningful states. Reuse components for cross-cutting states rather than making a full-screen copy for every combination.

FR-07 adds the fixed Runnir GitHub toolbar link, optional analytics invitation, Privacy & Diagnostics settings and sanitized crash/issue preview. See [data/consent requirements](../product/analytics-and-crash-reporting.md). These designs must not show collection enabled by default or public reports sent without explicit review.

## Workspace Lifecycle Scope

[ADR 0003](../decisions/0003-workspaces-sessions-offline-storage.md) adds independent same-workspace windows, durable manual-close versus quit, current/new/focus switching, optional .runnir presets/environments, per-workspace SQLite and shared cache-first sync. New screens S14-S18 and components C26-C31 extend prior IDs. Preserve existing Pen concepts and brand; product name stays Runnir pending an explicit rename decision, and .runnir spelling is exact.

Manager/Splash are separate native windows, not new sidebar entries. Config/environment/cache views are workspace subviews or recovery sheets. Prototype window lifecycle and offline freshness before polishing full screen variants. No DB, restoration or config functionality is implied by the mockup.

## Native Layout Baseline

The 2026-10-15 alignment pass uses explicit logo containers: Manager 140 x 51, splash mark 76 x 74 and separate wordmark 124 x 31 points. Sidebar is 220 points, navigation rows 30 and toolbar 52; it carries no logo (the logo lives on the splash and in the Manager), so the repository switcher sits right under the window controls. Workspace places numbered read-only YAML on the left (380 points at 1280 x 800, constrained at minimum width), preview/checks on the right and file selection in the toolbar. Native title-bar controls overlay a full-size content view; no second full-width title strip. Manager defaults to 900 x 600 and new workspace windows to 1280 x 800; saved workspace geometry takes precedence. Native system fonts/SF Symbols remain intentional platform adaptations rather than exact Inter/JetBrains/Material font reproduction. Unimplemented analysis/validation/execution uses explicit unavailable states, not mock results.

Design full-window states at 1280 x 800 points, verify the current app minimum 980 x 640, and inspect wide-window expansion at 1440 x 900. These are design viewports, not new fixed window requirements. Explore Manager around 900 x 600 and Splash around 480 x 280 separately; their constraints are proposed, not the current main-window minimum. Test two workspace windows with independent selection and different monitor positions. Sidebar starts around 220-240 points; secondary lists/inspectors must collapse or resize without squeezing core content. Keep primary actions visible at the supported minimum.

Use system-like typography: approximately 13-14 pt body/controls, 12 pt secondary metadata, 20-24 pt compact page titles and 13 pt monospaced code/log text. Verify final sizes against actual macOS rendering; avoid hero typography and viewport-scaled text. Table rows, icons, counters and toolbar slots need stable dimensions. Avoid nested cards and decorative containers around whole sections.

Use native SF Symbols in SwiftUI. Canvas icons can use supported library equivalents with an explicit mapping; do not hand-draw interface icons or imply icon availability is identical. Icon-only tools need a label for accessibility and a tooltip. Numeric, binary and choice inputs use the appropriate native field/toggle/picker.

## Content And Review

Workspace uses a native horizontal split view: drag the divider between YAML and preview/checks to resize both panes. The YAML pane has a 240-point minimum and 380-point preferred width; the checks pane has a 360-point minimum. Width is no longer fixed to a percentage of the window. Split-position persistence across app restarts is not implemented.

The YAML viewport scrolls vertically only. Long lines soft-wrap within the pane without changing source text. Each logical source line has one top-aligned number; continuation rows have no extra numbers. The gutter expands for large line counts. Keys, quoted strings, basic numeric/boolean/null literals and comments use semantic syntax-color tokens. This is lightweight lexical styling, not a complete YAML parser, validation result or block-scalar semantic analysis.

Use synthetic repository names, commit SHAs, workflow YAML and log lines. Include long names, many rows, no rows, broken data and mixed permissions. Never paste actual repository secrets or personal data into the design. English is the initial UI-copy assumption; verify longer translated labels without claiming localization is implemented.

Review each work package for task completion, state truth, focus/keyboard paths, readable contrast, window resizing, empty/error recovery and component reuse. Prototype key flows before high-fidelity duplication. Previews/catalog scenarios should later reuse screen/component state IDs; see [macOS UI workflow](../development/macos-ui-workflow.md).
