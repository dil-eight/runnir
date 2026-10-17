# Reusable UI Component Inventory

Status: design-system backlog, updated 2026-10-15. Reusable components now exist in Pen; native code currently shares branding, project link, adaptive theme and local workflow presentation. The inventory below is not a claim that all variants are implemented. IDs are design references, not a requirement to create a Swift type for every entry. Prefer native controls; extract code only when actual reuse or complexity warrants it.

## Tokens First

| Group | Required semantic variables |
| --- | --- |
| Surfaces | Window, sidebar, content, editor/log, overlay, selected row, divider |
| Text | Primary, secondary, disabled, link, on-accent, code and line number |
| Feedback | Information, warning, error, success, queued, active, cancelled/skipped; paired icon/label |
| Controls | Accent, focus ring, border, hover/pressed, disabled; light/dark values |
| Typography | Body/control, secondary/caption, compact heading, monospace; weight/line height |
| Geometry | Spacing steps, content insets, row heights, control/icon slots, divider, corner radius |

Inspect existing colors/fonts before selecting values. Preserve branded assets; avoid hardcoding a subtly different shade in each screen. Use themed variables and explicit roles, not tokens named after the current hex value. Start with light/dark/system semantics; do not invent a third product theme.

## Reuse Candidates

| ID / component | Properties and meaningful states | Reused in | Native/implementation direction |
| --- | --- | --- | --- |
| C01 Navigation shell | Destination, account state, collapsed sidebar, active local task indicator | All main window frames | NavigationSplitView/List and native window toolbar; compose content instead of copying sidebar layers |
| C02 Split region | List/detail/editor/inspector slots; collapsed/resized regions | Repository explorer, inspector, workspace | Native split composition; shared geometry, not a new generalized layout framework |
| C03 Toolbar action group | Context, primary operation, secondary actions, unavailable/pending | Dashboard, workflows, inspector, workspace | Native ToolbarItem groups; stable icon slots and labels/tooltips |
| C04 Search/filter bar | Query, filter selections/count, busy, cleared, no-match context | Repositories, workflows, runs, diagnostics/logs where applicable | Native search and pickers; log-specific options stay in log view |
| C05 Operation control | Label/icon, role, enabled, hover, focus, pressed, submitting; disabled reason supplied by context | Refresh, validate, run, stop, save | Native Button styles; not a custom-drawn button framework |
| C06 Content state | Loading/empty/no-match/error/denied; contextual explanation and recovery | Lists and panels across app | Extend current EmptyStateView only when implemented; no universal full-screen error overlay |
| C07 Inline notice | Severity, message, optional action, stale/rate-limit/compatibility context | Remote sections, forms, editor and setup | Compact banner/inline message; icon + text, focusable recovery action |
| C08 Activity/readout | Indeterminate/determinate when measurable; duration, progress phase, stopped | Downloads, validation, API submission, execution | Native ProgressView plus phase text; do not invent percentage for unknown progress |
| C09 Execution status | Status, conclusion, source (GitHub/local), optional duration; queued/running/success/failure/cancelled/skipped/unknown | Dashboard, workflows, runs, job list/output | One semantic visual vocabulary, distinct underlying remote/local state models |
| C10 Repository row | Name/owner, visibility, favorite, selected, hover, inaccessible | Explorer, favorites, contextual repository picker | Table/List row; favorite icon has accessible state, names truncate with full value available |
| C11 Workflow row | Name/path, dispatch capability, latest run, selected/disabled | Explorer, workflow picker | Shared domain row; latest status optional, absence != success |
| C12 Run row | Workflow, ref, commit, attempt, timestamp/duration, status, selection | Dashboard recent/active, Runs, workflow history | Compact and full column compositions share semantics; do not force one column set everywhere |
| C13 Job/step row | Name, level, expansion, status, duration, selected/error location | Run inspector and local job output | Hierarchical native list; dependency graph remains a separate presentation |
| C14 Ref picker | Branch/tag, search, selected ref, loading/error/missing | Dispatch and workflow context | Native picker/popover; branch/tag distinguishable beyond icon/color |
| C15 Workflow input field | Supported string/number/boolean/choice/environment type, label, required/default/help, invalid/disabled | Dispatch form, preset review | Compose native fields/toggles/pickers; unsupported type gets explicit fallback, no guessed semantics |
| C16 Preset selector | None/selected/modified, save/rename/delete, schema mismatch | Dispatch and preset management | Native menu/popover; non-secret values only; avoid separate full-screen CRUD UI |
| C17 Log/output viewer | Lines, location, query/matches, following, loading/unavailable/truncated, wrap preference | GitHub inspector and local execution output | Shared rendering/search surface; transport/refresh semantics remain separate; monospace, stable gutter |
| C18 YAML editor surface | Source, caret/selection, line numbers, clean/dirty/read-only, diagnostics | Local workspace, conflict comparison if used | Actual editor component choice remains an implementation decision; Pen documents its visual/interaction contract |
| C19 Diagnostic row | Severity, message, relative file/line/column, selected/unlocatable | Validation list and inline diagnostic detail | Select jumps to editor when location exists; safe fallback when it does not |
| C20 Action review | Named operation, exact target/ref/run/attempt, effects and approval button; ready/invalidated/pending | Dispatch, cancel/rerun and local execution review | Reuse summary/approval pattern, not one giant form containing unrelated options |
| C21 Tool readiness row | Tool/engine/version/context, checking/ready/missing/stopped/incompatible/denied; setup/recheck | Settings, workspace, local preflight | No installation success until verified; remote context visibly separate |
| C22 Access/resource summary | Selected root, workspace/mounts, downloads/network, explicit credentials, limits and unsupported items | Folder access management and execution review | Readable labeled list; context-specific fields, no raw tokens or unnecessary home paths |
| C23 Edit state indicator | Clean/dirty/saving/saved/conflict/read-only/failed; current file | Workspace header/editor tabs and save prompts | Shared state semantics; preserve source on failed save; avoid color-only dirty indicator |
| C24 Consent preference | Purpose, payload/destination link, off/on/withdrawn/unconfigured; explicit choice | Optional invitation and Settings Privacy & Diagnostics | Native toggles/buttons; independent analytics and per-report consent, no prechecked sharing |
| C25 Sanitized report preview | Allowlisted fields, omitted-data explanation, fixed public destination, draft edits; ready/blocked/handed off | S13 crash/problem reporting and local sanitized-summary export | Readable preview plus C20 action review; no automatic raw attachments, clipboard access or submission |

## Workspace Lifecycle Additions

Preserve C01-C25 IDs. These new candidates serve FR-08/09; do not make a separate full app shell per workspace.

| ID / component | Properties/states | Reuse |
| --- | --- | --- |
| C26 Workspace registry row | Stable local identity, display path, last opened, availability and open-window count; selected/missing/denied | Manager, switcher and settings; paths excluded from analytics/report payload |
| C27 Workspace switcher | Current workspace/window context; recent targets and reuse/new/focus choices; preparing/failed transition | Workspace toolbar and Manager open actions; New Window preserves source |
| C28 Source/freshness indicator | Local/remote origin, cached/refreshing/offline/up-to-date/error, last successful sync versus last attempt/check | Dashboard, run/workflow lists, editor source and restored shells; never show cache as live |
| C29 Environment selector | Selected env, defaults/private override/portable source; unavailable/missing-reference/config-error | Launch review, workspace context and environment inspector; selecting never executes |
| C30 Effective value row | Non-secret key/value, source layer, overridden/invalid; secret reference shows status only | S16 and launch/config review; no raw secret, no implicit Keychain lookup |
| C31 Workspace recovery panel | Context and safe recovery actions for root/session/DB/persistence errors; blocked/retry/recovery success | Manager, restored shell and storage settings; scopes errors without destroying other windows |

C01 gains independent window identity/composition; C08 supplies truthful splash/bootstrap activity; C16 gains portable/device-private origin and readonly/explicit-save states; C18/C19 serve optional config YAML/diagnostics. Reuse existing review/message primitives rather than inventing another splash progress or config editor framework.

## Native Primitives To Specify, Not Rebuild

For FR-07, C03 also includes the fixed Runnir GitHub external-link action with tooltip, focus, browser-open failure/Copy Link and native overflow behavior. Reuse the toolbar action primitive instead of adding a separate widget for GitHub stars or account data.

Document variants of native text/number fields, checkbox/toggle, picker/menu/segmented control, table selection/sort, disclosure row, scroll region, alert/sheet/popover and Settings sections. Use platform-consistent sizes and focus/disabled states. Native file picker is a system interaction, not a new custom component.

Do not extract every divider, text label, one-off dashboard section or screen-sized layout into a named reusable component. If an item is repeated only once in a prototype, keep it a composition until another real use appears. A whole YAML editor or log viewer is a genuinely framed tool; other page sections stay unframed or separated by dividers.

## Component Variant Board

For interactive controls, show enabled/default, hover, keyboard focus, pressed, disabled and busy when the control supports them. Show error on inputs/containers that can actually fail; a static label does not need an artificial loading/error variant. Selected state is separate from hover and focus.

For domain rows, show populated/long-name, selected and permission/status examples. For messages, show information/warning/error and short/long text. For log/editor surfaces, include long lines, multiple lines and unavailable/truncated content. Compare light/dark variants; expand variants by observed usage rather than generating a Cartesian product.

## Pen Component Rules

Use reusable components and ref instances for repeated patterns. Keep master definitions above MVP screen rows, and name them Cxx / Name / Variant. Override instance data/labels and supported slots; avoid detaching copies just to change content. Record any required structural variant instead of changing the master silently for one screen.

Use shared semantic variables; inspect existing variables first and merge without replacing unrelated future concepts. Every node gets a readable name. Keep master examples compact enough to inspect without screenshotting an enormous canvas. Native primitives may be documented on the board without turning them into product abstractions.

## Extraction Order And Handoff

1. Establish tokens and native primitive examples; map the shared navigation/toolbar structure.
2. Build message/status, rows, inputs and diagnostics needed by the first workspace/remote flows.
3. Establish editor/log/review composites only after testing them in representative screen frames.
4. Confirm actual reuse; map component and state IDs to SwiftUI preview fixtures and future catalog scenarios.

Pen design components do not automatically create SwiftUI components. Handoff specifies properties, states, layout constraints, accessibility labels and interactions; implementation follows the existing native codebase. No new dependency is selected by this inventory.
