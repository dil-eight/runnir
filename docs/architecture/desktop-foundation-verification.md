# Desktop Foundation Verification

Date: 2026-10-15. First native implementation against the current Pen document; not a complete MVP release.

## Implemented

- AppKit-managed startup splash, singleton Workspace Manager and independent workspace windows; existing Settings and Swift GitHub services preserved.
- Explicit local Git working-tree import with read-only security-scoped bookmarks, canonical path deduplication, stable workspace/window IDs and Locate recovery.
- Native shell using Pen branding and adaptive light/dark tokens. Public Runnir GitHub link in Manager/workspace toolbar and Help.
- Real local workflow discovery and bounded read-only UTF-8 YAML display; no seeded repositories, fake runs, remote upload or automatic .runnir creation.
- Open new/reuse/focus window actions, per-window navigation, geometry clamping and session restoration.
- Combined versioned desktop-state.json under native Application Support. Registry and eligibility change in one validated snapshot; private temporary write, fsync, atomic rename and directory fsync. Manual close commits removal before closure; quit retains remaining entries. Invalid data is not silently reset or restored from backups.
- Named empty-Manager and splash SwiftUI previews without live startup.

## Checks

- Required macOS xcodebuild build: passed.
- build-for-testing: passed for the shared scheme, including unit and UI test targets after the UI test's MainActor correction.
- Required RunnirTests run: 20 passed, including eight new registry/session and repository-reader tests. Existing bundled Go helper round trip still passes.
- Native smoke on macOS 27.0.1 arm64: empty Manager, folder picker/import, three actual repository workflows, YAML selection and public-link presence.
- Created multiple windows for one workspace with distinct IDs and independent Dashboard/Workspace navigation. Manually closed one, quit and relaunched: remaining window IDs restored, closed ID absent. Closed a restored window and observed the other restored ID remain.
- Screenshots inspected at the minimum workspace size 980 x 640; corrected the file-list background to match the Pen palette. Manager empty state and branding also inspected.
- Core source/contracts were not changed. This does not establish native coverage on all Go platforms.

The first test run exposed URL equality differing by directory representation; the test now compares canonical filesystem paths. UI launch tests use a unique temporary state directory via a debug-only override, never the user's saved registry/session.

The shared scheme now includes the previously unlisted UI-test target. An automated UI run stalled during runner startup and was cancelled without a test result; it is not counted as a pass. Native smoke evidence above is separate from XCTest UI automation.

## Design Alignment Follow-Up

The initial implementation did not faithfully reproduce Pen's shell. A follow-up on 2026-10-15 corrected the four-item navigation, 220-point sidebar, 52-point toolbar, selector labels, button sizes, explicit logo dimensions and splash wordmark/progress treatment. Workspace now places numbered YAML on the left and preview/check states on the right. The Manager uses 900 x 600 instead of shrinking to its minimum when its hosting controller is installed; workspace hosting preserves saved/default geometry. Repositories and Artifacts remain reachable from the workspace menu.

Native screenshots confirm the minimum-width workspace shell and populated 900 x 600 Manager, including logo placement and selectors. Pipeline data, validator diagnostics and local execution remain unavailable, so the populated design is not claimed as feature-complete or pixel-identical. System fonts and SF Symbols are retained. No changes were made to the Pen document.

Alignment build passed and the follow-up unit run passed all 21 tests, including a new sidebar-order/legacy-destination regression test. The mechanical UI detector reported no findings.

## Outstanding Verification

YAML-viewer follow-up: removed horizontal scrolling in favor of soft wrapping. One number remains attached to each logical line; wrapped rows grow without adding line numbers, and the gutter accommodates large line counts. Added local lexical syntax styling through semantic tokens, without modifying source or claiming parser/validation completeness. Native inspection at a 300-point YAML pane confirmed wrapping, numbering, visible syntax colors and a vertical-only scroll area. Build and the updated unit suite passed, including source-preservation, quoted-comment and large-gutter coverage. Icons were unchanged.

Color-token follow-up: introduced a typed primitive palette, exhaustive semantic light/dark mappings and adaptive SwiftUI accessors, following Fintropy's layering while preserving Runnir's Pen colors. Components no longer contain direct RGB/status-color values. Added debug-only Light/Dark token catalogs and three mapping/contrast tests. Native build and all 24 unit tests passed; the dark Manager was visually checked after restart. Light appearance is covered by deterministic color-resolution/contrast tests, not a new full-app screenshot review.

Signed sandbox and helper permissions; hostile concurrent symlink replacement; crash/power-loss injection; failed-write/cancelled-quit integration tests; missing monitors and stale-bookmark/relink scenarios; shared account propagation; full populated preview catalog and light-mode visual review.

No workflow editing, actionlint, execution, SQLite, remote sync, Device Flow, AI, MCP, analytics, crash collection, signing/notarization or updater was implemented in this slice. Local file readers are presentation bridges, not a duplicate workflow domain engine. The next bounded feature is offline validation, following lifecycle hardening.
