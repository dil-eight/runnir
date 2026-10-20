# Pen Design Production Plan

Status: design/handoff work packages, updated 2026-10-15. Current Pen includes MVP frames and reusable components; the native implementation has started with S14/S15 and a read-only S09 subset. The packages below remain acceptance work, not proof that every state is drawn or implemented. Scope: MVP v0.1 plus FR-08/09 lifecycle/offline foundations; existing AI/Pipeline concepts remain separate.

## Canvas Organization

Treat the following as named canvas zones, not assumptions that Pen has a particular page/tab feature:

| Zone | Content |
| --- | --- |
| 00 Brief and flow index | MVP scope, screen IDs, journey/state index and links to these documents |
| 01 Foundations | Existing brand reference, semantic tokens, light/dark and native primitive examples |
| 02 Components | C01-C31 masters/variants as justified by actual reuse |
| 03 MVP workspace | S09 and S14-S18: splash/Manager, local editor, environments/portable presets and recovery |
| 04 MVP GitHub | S02-S08, auth/dashboard/discovery/dispatch/inspector journeys |
| 05 MVP local execution | S10-S11, readiness/approval/output/cleanup states |
| 06 MVP settings | S12 and account/tool/folder/data-management states |
| 07 Review and handoff | Compact/standard/wide and light/dark comparisons, unresolved questions and approved snapshots |
| Future concepts | Existing Assistant Home/Chat and Pipeline; retained outside the MVP acceptance set |

Before each edit re-read the live document, confirm frame IDs and find empty space. Do not rename/move/delete collaborative content merely to make this organization literal. Add a new MVP area without overlapping existing concepts; any later reorganization should preserve references/assets.

Name screen frames Sxx / Surface / State / Theme / Window, for example S09 / Local Workspace / Invalid YAML / Dark / 1280x800. Use Cxx for component masters and Oxx for overlay samples. Keep annotations outside app viewports and distinguish design notes from user-facing copy.

Create screens as top-level frames with clipping, meaningful child names and layout-driven sizing. Keep a root placeholder flag while a frame is being built, then remove it when complete. Model document-visible overflow with an explicit continuation/scroll annotation; Pen canvas content itself must not depend on scrolling an oversized undocumented frame.

## Work Packages

| Package | Deliverable | Dependencies | Completion evidence |
| --- | --- | --- | --- |
| D01 Inventory and journeys | Confirm current brand/concepts, four primary navigation destinations, screen/state/overlay IDs and offline path | Product scope and existing canvas | Matrix covers FR-01 through FR-09; future concepts explicitly separate |
| D02 Foundations | Native shell geometry, type/spacing scale, light/dark semantic tokens and control examples | D01 | Readable dense tables, code/log text and focus/status examples at minimum window |
| D03 Workspace wireframes | Open repo -> choose workflow -> inspect -> validate -> select diagnostic; subsequent edit/save/conflict path | D01; draft D02 | S09 states and O02/O03/O05/O06 flows; works without GitHub login |
| D04 Reuse extraction | Build masters from actual repeated patterns, including messages/status, rows, inputs/diagnostics | D02/D03 and initial remote sketches | Master change propagates; no duplicated sidebars or disconnected status styles |
| D05 Remote workflow wireframes | Device Flow -> repositories -> workflow -> typed run form -> accepted/identified run | D01/D02; reusable primitives | S02-S07, O01/O04/O07; ambiguous dispatch and revoked permission recovery covered |
| D06 Inspector and logs | Failed job/step -> relevant log line; active run -> cancel; rerun review | D05; shared C09/C12/C13/C17/C20 | S08 shows status truth, available-log limits, search and long-output behavior |
| D07 Local execution | Tools readiness -> supported job -> access/compatibility review -> output -> stop/cleanup/result | D03/D04; product execution policy | S10/S11 plus O05/O08/O09; engine missing, unsupported and cleanup failure included |
| D08 Settings and recovery | Account/folders/tools/data sections and scoped error/recovery messages | D05/D07 | S12 consistent with inline setup; no fictional connected/installed/signed states |
| D09 High-fidelity assembly | Apply tokens/components to approved flow frames; keep native conventions | D02-D08/D12/D13 wireframes | Coherent light/dark; component reuse; no unnecessary card nesting or marketing layout |
| D10 QA and handoff | Minimum/wide windows, interaction/a11y notes, component/preview mapping and completion checklist | D09/D11/D14 | Review criteria below passed; remaining behavior decisions visible |
| D11 Feedback and diagnostics | GitHub toolbar link, optional analytics invitation, Privacy & Diagnostics, S13 sanitized issue preview | D02/D08; FR-07 data/consent policy | Off/declined consent, blocked report, public-destination warning and draft-open/copy fallback states |

Work packages are an order/dependency plan, not calendar estimates. Start with D01/D12 and draft D02 for the lifecycle slice, then D03/D13 for offline validation and persistence; sketch remote flows before locking components that must serve both paths. Do not perfect every master before trying a screen, or draw all states before validating the primary journey.

## Added Foundation Work Packages

| Package | Deliverable | Dependencies | Completion evidence |
| --- | --- | --- | --- |
| D12 Native startup/windows | S14/S15, C26/C27, switch/new/focus, manual-close/quit/Dock before-after sequences | D01; ADR 0003 lifecycle | L01-L10 journeys and independent-window state; source window intact on failure |
| D13 Offline config/environments | S16-S18, C28-C31, portable/private presets, cache/source/freshness and safe recovery | D12 + workspace/remote sketches | W01-W09 visual states; cache before sync; .runnir absent normal; effective origins with no secrets |
| D14 Lifecycle/recovery review | Multiple monitors/windows, invalid session/config/DB, close-write failure and interrupted local history | D12/D13 representative frames | No resurrection/duplicate manager/sync promises unsupported by handoff; recovery preserves unique local values |

D12 belongs early, immediately after D01; D13 develops with D03/D05. D09 high fidelity includes these approved wireframes before D10. Numeric package IDs preserve references, not a serial calendar.

## Prototype Paths

| Path | Required transitions and exit/recovery |
| --- | --- |
| P01 Offline validation | Splash -> Manager or restored shell -> explicit local import/grant -> cached/local workspace -> workflow -> Validate -> diagnostics; no GitHub login; missing tool -> setup/recheck |
| P02 Safe editing | Open YAML -> edit -> validate -> save; external disk change -> compare/review; navigation with dirty buffer -> Save/Discard/Keep Editing |
| P03 Connect and discover | Connect -> device code/browser -> waiting -> account -> repositories -> workflow; denial/expiry -> retry; cancel returns to usable local app |
| P04 Manual workflow run | Published workflow -> ref/typed inputs -> optional preset -> explicit Run -> submitting -> accepted -> correlated run; invalid fields/ambiguous result stay truthful |
| P05 Failed-run diagnosis | Dashboard failed run -> job -> failed step -> logs -> search/line; unavailable log -> explanation/Web fallback |
| P06 Cancel/rerun | Selected exact run/attempt -> review -> submit -> refresh real status; permission or stale-target error retains context |
| P07 Local execution | Repo/workflow -> engine/act readiness -> supported job review -> approve -> live output -> cancel -> cleanup -> result; decline setup/approval returns without execution |
| P08 Recovery and exit | Offline/auth errors preserve drafts; manual close removes only focused window durably; Cmd+Q snapshots eligible windows, resolves dirty/active work and stops/cleans execution; restart never resumes processes |
| P09 Optional feedback | Decline/enable analytics independently; report problem -> explicit import/sanitization -> preview/public warning -> approved browser draft -> user publishes; unknown report blocks transfer, long draft offers explicit copy fallback |
| P10 Startup restoration | First launch -> splash -> Manager; quit with A+B -> restore both; manually close A -> only B restores; close all -> no-window state -> Dock twice -> one Manager |
| P11 Workspace switching | A -> B via reuse (same windowId) or new (A intact) or focus existing; failed target leaves source intact; A twice has independent UI/shared sync |
| P12 Offline/source/config | Cached workspace opens before sync; malformed .runnir -> usable degraded view; local unpublished YAML clearly differs from GitHub; missing root -> Locate/relink retains identity |
| P13 Environments/storage | Select env/preset -> inspect effective origins/target -> approve specific launch; missing secret reference blocks relevant action; cache clear/corrupt DB repair preserves private unique values |

Represent these as linked frame/state diagrams and annotated click paths using the editor's available facilities. Do not claim a functional interactive prototype unless the transitions can actually be exercised. Avoid inventing unavailable Pen interaction APIs.

## Design Review Checklist

- [ ] Every FR has canonical layout, meaningful state samples and a complete user path.
- [ ] Remote and local execution, draft and published YAML, submission and actual run are visually distinguishable.
- [ ] Offline workspace remains reachable when signed out; local data/errors survive unrelated remote failures.
- [ ] Defaults, choices, required-field validation and preset drift are represented without plaintext secrets.
- [ ] Permission/tool/unsupported states include a useful next action and never show fake success.
- [ ] Unsaved edits, external conflicts, mutation uncertainty and cancellation cleanup have explicit choices.
- [ ] Shared components use instances and semantic variables; component inventory matches actual use.
- [ ] Minimum 980x640, standard 1280x800 and wide 1440x900 windows remain coherent; editor/log scrolling is intentional.
- [ ] Light/dark contrast, keyboard focus/order, labels/tooltips and non-color status meaning are recorded.
- [ ] Long labels, many rows/diagnostics and bounded/truncated output do not overlap controls.
- [ ] No real secrets, private source/logs or personal profile data are present in canvas fixtures.
- [ ] Existing brand/future concepts are preserved; docs/design/runnir.pen remains committable.
- [ ] Project link targets Runnir, analytics starts off, report sharing requires separate approval, no code/secrets/raw report is shown as safe to transmit, and browser handoff is not labeled issue creation.

- [ ] S14-S18 and C26-C31 cover startup/identity/window switching, cache/source/freshness, optional config and safe recovery without treating the runtime as a resumable process.

## Handoff Contract

For each approved surface provide frame ID/name, FR and state IDs, primary/secondary actions, target transitions, data fields, disabled/error behavior, resize rules and component IDs. For each reusable component provide supported properties/variants, slots, accessibility semantics and equivalent native controls.

Map screen/component state IDs to deterministic #Preview/catalog scenarios during implementation. Record a discrepancy when an existing screen cannot accept injected fixtures; do not claim preview readiness from a Pen component. Screenshots support visual review, while real Keychain/IPC/process/folder-access behavior needs native integration checks.

Do not choose a YAML editor dependency, infer an OAuth scope, promise live GitHub logs or label containers secure based on a mockup. Carry unresolved product/engineering decisions into handoff instead of drawing unsupported functionality.
