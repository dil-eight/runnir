# MVP Screen And State Matrix

Status: design backlog, not implemented. IDs remain stable across Pen frames, fixtures and future previews. FR references point to the [MVP specification](../product/specification.md).

## Surfaces

| ID / surface | Hierarchy and primary action | Required states | Coverage |
| --- | --- | --- | --- |
| S01 Workspace window shell | Native window/sidebar, workspace switcher, account/freshness and independent window context | Opening/restoring shell, cached local UI, signed out, helper failure, offline/refreshing, independent same-workspace windows, active local task; no unconditional Dashboard boot | Shared / FR-08/09 |
| S02 GitHub connection | Optional connection sheet/first-use panel; show device code, destination and authorization status | Not connected, requesting code, waiting/browser reopened, slower polling, success, denied, expired code, cancelled, network/rate limit, auth not configured, Keychain denied | FR-01 |
| S03 Dashboard | Default tab within an opened workspace; favorites and recent/active/failed runs; open workflow/run/local editor | Cached-first, empty/unindexed, refreshing with retained content, partial failure, offline/stale, rate limited; no GitHub wait to show window, repository presets with an unusable file (Run manually) | FR-02/04/09 |
| S04 Repository explorer | Search/filter/favorites, repository list and selected repository's workflow list; open workflow | Loading, populated/selected, no accessible repositories, no search matches, no workflows, refreshing, partial pagination, forbidden/revoked access, unavailable/deleted, offline/stale | FR-02 |
| S05 Workflow detail | Repository/workflow/source, last result, run history, published ref information; open Run form | Dispatch supported, unsupported/not configured, workflow disabled, no runs, loading/error, permission denied, selected ref lacks a usable definition, local changes differ from published workflow | FR-02/03 |
| S06 Manual run sheet | Ref picker, typed inputs, preset selector, concise destination/operation review; submit once | Defaults, changed/valid, required/choice invalid, refs loading/empty/error, unsupported input type/Web fallback, preset invalid after schema change, submitting, accepted awaiting run, correlated, ambiguous, rejected, unknown outcome after disconnect, preset menu with repository and Mac presets | FR-03 |
| S07 Runs browser | Repository/workflow/status/ref filters, runs table and selection; inspect run; `List | By change` switch (List by default, kept per window): each run says its pull request (`#142`, `#142 after merge`) or short commit, completed superseded runs hidden behind a reveal row, an outdated run labelled; By change groups runs by pull request (after merge, latest commit, older commits folded) or commit (repeats folded); the inspector shows the pull request and commit lines, "Superseded by…", and a concurrency suggestion that opens the editor with the block as an unsaved edit | Loading, populated, no runs, no matches, refreshing/backoff, stale/offline, partial page error, permission denied, pull requests unreadable (note with the fix), loading older runs, older runs failed (Retry), 5000 runs kept (older on GitHub); active and terminal status examples | FR-04 |
| S08 Run inspector | Run/attempt/commit summary, jobs and steps, logs pane/search; inspect failure, cancel or rerun | Queued, running, success, failure, cancelled, skipped; jobs loading/empty/error; logs downloading/partial/unavailable/expired/oversized; search no match; follow output on/off; mutation pending/denied/failed | FR-04 |
| S09 Local workspace | Registered root/workflow list, YAML editor, diagnostics/dependencies; validate/save | No workflows, root moved/denied, .runnir absent (normal), invalid optional config (degraded), local vs remote source difference, clean/dirty/save/conflict, valid/invalid/incomplete/tool missing, same-file edit in another window | FR-05/08/09 |
| S10 Local execution review | Workflow/job/event, engine/context, compatibility, mounts/downloads/network/secrets summary; authorize local run | Ready, preflight running, tools absent, daemon stopped, remote/unapproved context, unsupported OS/architecture/job, missing explicit secret input, image download needed, setup declined, policy denies operation | FR-06 |
| S11 Local run output | App-owned workspace execution tab, selected job, bounded output, result/cancel | Preparing/running/stopping/cleanup, success/failure/cancelled, engine lost/truncated, app exit cleanup; restart shows interrupted/unknown historical record with no auto resume | FR-06/08/09 |
| S12 Settings | Native account/tools/appearance/privacy sections, registered folders and cache/storage controls | Valid/stale/revoked grants, tool readiness, consent states, storage usage/clear-cache preview, corrupt/migration recovery; clear cache preserves registry/Keychain/config/user overrides | FR-01/05/07/09 |
| S13 Problem/crash report review | Sanitized environment/diagnostic preview, optional user reproduction text, fixed public Runnir destination; open reviewed issue draft | No report, user-selected import, sanitizing, ready, unknown format/unsafe sharing blocked, edited draft, browser handoff pending/failed/opened, oversized URL copy fallback, local record cleared, security-report redirect | FR-07 |
| S14 Startup splash | Transient native borderless branded window; no navigation or persistent session entry | Immediate bootstrap, reduced-motion, truthful phase, graceful failure -> recovery Manager, quit/cancel; no deliberate minimum delay | FR-08/09 |
| S15 Workspace Manager | Singleton recent local repos with path/availability/open indicator; import/open/locate/focus/new window | First launch/empty, recent/populated, already open/same repo, missing/moved/denied, invalid session warning, destination preparing/failure; closes only after target ready | FR-08/09 |
| S16 Environments and effective values | Workspace inspector/settings subview; select environment, inspect non-secret values and origins, machine overrides | No .runnir/default env, defined/local overrides, missing/denied secret reference (no value), invalid/future schema, changes in another window; selection not execution | FR-08/09 · drawn for the earlier plan; revisited in B28 |
| S17 Portable launch/config review | Workspace subview for optional .runnir config/environments/launches; view preset/target/ref/inputs, explicit edit/create preview | Absent (normal), valid read-only, invalid/version unsupported, portable vs device-private, target unavailable, local unpublished changes, dirty/external conflict, reviewed save/failure | FR-08/09 · drawn for the earlier plan; revisited in B28 |
| S18 Workspace storage/recovery | Inline panel or sheet, not sidebar: relink/access/DB migration/recovery/cache cleanup | Missing/corrupt DB, backup/recovery available, unique local values at risk, cache stale/unindexed, migration failed, clear-cache preview/declined/complete; unrelated windows remain usable | FR-08/09 |

S06 is a sheet, S08 a detail destination, S10 a sheet/detail review, S11 part of the workspace. S12 uses the native Settings window. S01 is the shared layout, not another navigation item.

FR-07 additions: S13 is a feedback sheet reached from Help/Settings or a non-blocking unexpected-session notice. It is not a navigation destination. S12 gains Privacy & Diagnostics: analytics off/on/withdrawn, destination not yet configured (delivery unavailable), payload inspection and clear local records. A separate optional analytics invitation has Not Now and Enable; no preselection or effect on crash sharing. Define declined/dismissed states without repeated nagging.

S01/C03 gains a trailing GitHub action linking to https://github.com/dil-eight/runnir, with Open Runnir on GitHub tooltip/accessibility label, separate from Run/Stop. At compact width use native toolbar overflow and a Help-menu fallback. No authenticated/star-count widget or background fetch. S13 states must say Draft Opened rather than Report Sent until publication is verified.

## Desktop Lifecycle Amendments (2026-10-14)

S14/S15 govern startup; S03 is not the universal first screen. S16/S17 live within a registered workspace; S18 is contextual recovery. Account-wide GitHub discovery (S04) remains distinct from local registry identity. Decided 2026-10-20: it is a GitHub tab in the Workspace Manager, next to the registered workspaces. A repository with a registered local clone opens as that workspace; one without can be browsed and its workflows started, and Runnir never clones it or reassigns a window.

Draw Reuse Current Window / Open New Window / conditional Focus Existing explicitly. Different windows may select different workflows for the same workspace while sharing DB/sync/freshness. Same-file dirty buffers remain independent and use external-change recovery, not silent overwrite.

Manual close persists removal before the window is considered closed; save failure must offer retry/keep-open recovery rather than false success. Quit saves remaining eligible windows and ignores teardown close events. Last-window close leaves the app running without Manager; Dock activation opens/focuses one Manager. Manager close never quits. Restore geometry clamps to connected displays.

Remote cached data shows origin and last successful sync; background failure does not destroy local UI. Distinguish last attempt/checked unchanged from successful new data. Source labels separate working tree, portable preset, private override and GitHub-published definition. Keychain references never display raw values.

## State Truth Rules

| State family | Representation / allowed action | Avoid |
| --- | --- | --- |
| First load | Stable structure with placeholder rows and a bounded progress indicator | Invented run statuses/data |
| Refresh | Retain visible data, show refresh state and last-updated/stale context; disable duplicate refresh | Replacing a useful table with a full-page spinner |
| Signed out | Connect action in remote areas; Open Repository and offline validation remain reachable | Blocking the whole app behind GitHub login |
| Rate limit | Reset/retry information when known, available local/cached work, no automatic retry for mutations | Endless loading or aggressive polling |
| Offline | Preserve drafts/local work; label stale remote data, provide intentional retry | Labeling cached status as live |
| Partial error | Failure and recovery scoped to the affected section | Losing unaffected data or edits |
| Disabled/forbidden | Explain the unavailable action near its context | Enabled buttons that can only fail |
| Empty vs no match | Setup/open action for empty source; clear filters for no match | One generic empty state for both |
| Error vs warning | Errors block the specific action; warnings expose limitations and next choice | Warning colors used as unrelated decoration |

Full-screen failures are reserved for unusable window-level conditions. A helper failure blocks dependent actions, not safe navigation or a readable local draft.

## Run And Mutation Semantics

Execution status (queued/in progress/completed) is separate from conclusion (success/failure/cancelled/skipped/other unsupported conclusion). Show unknown/new server values safely. A skipped job is not a failed job.

Dispatch: editing -> explicit Run confirmation -> submitting -> submission accepted -> awaiting run identity -> confirmed run OR unresolved/ambiguous. A failed response with uncertain acceptance becomes unknown outcome, with a status check/Web link; never offer an automatic blind resubmit. Only navigate automatically when correlation is sufficiently certain.

Cancel/rerun: review exact run/attempt -> authorize -> request pending -> accepted or failed -> refreshed actual run state. Disable duplicate submission and distinguish request acceptance from completion. Permission/stale-target changes must invalidate an old confirmation.

Local execution: review -> authorized -> preparing -> running -> stop requested -> cleanup -> terminal result. Cancellation cannot display completion while cleanup is pending. A run may continue while navigating inside the app; closing the app requires a clear stop/cleanup path, not an implied permanent daemon.

## Overlays And Native Dialogs

| ID | Trigger / content | Choices and recovery |
| --- | --- | --- |
| O01 Consequential action review | Dispatch, cancel or rerun; exact repository/ref/workflow or run/attempt and relevant effects | Explicit named action and Cancel; one confirmation per unchanged intent, not two redundant dialogs |
| O02 Unsaved changes | Change workflow/repository, close editor/window | Save, Discard, Keep Editing; save failure retains draft |
| O03 External edit conflict | Disk changed while local draft dirty | Compare/Reload Disk or keep editing; explicit reviewed overwrite, never silent replacement |
| O04 Preset management | Save/rename/delete preset, incompatible saved values | Scoped non-secret values; review/reset missing fields; delete confirmation only if needed |
| O05 Tool setup | Missing actionlint/act/Docker engine | Official setup path, version/license context, explicit user action, re-check, Not Now |
| O06 Folder picker / grant | Open repository or repair permission | Native macOS dialog; cancellation leaves current selection intact |
| O07 Disconnect account | Local logout and remote revocation explanation | Disconnect clears local credentials; separate supported GitHub revocation link/path |
| O08 Leave active local run | Quit app/close owning window while execution active | Keep Running in app / Stop and Close; show cleanup failures and retry, no hidden daemon |
| O09 Local execution approval | S10 review, including actual destination/runtime and data access | Run Locally / Cancel; no GitHub token auto-injection or assertion of secure isolation |
| O11 Workspace switch | Choose another registered local root from a workspace window | Reuse Current Window / Open New Window / Focus Existing; source preserved on failure; honor unsaved/active work |
| O12 Registry/cache management | Remove registration or clear disposable cache with explicit effects | Separate operations; neither deletes .runnir/repository/Keychain/unique overrides implicitly |
| O13 Restoration/persistence recovery | Invalid session, failed critical close write, missing monitor/root or corrupt DB | Non-blocking scoped recovery, retry/locate/keep open; never resurrect committed closed windows |
| O10 Optional analytics invitation | Non-blocking Help improve Runnir prompt after useful work, plus data categories/destination link | Enable Usage Analytics / Not Now; decline persists, no crash consent, no buffering before opt-in |

Do not create custom replicas of native file pickers/alerts just to make a new design surface. Show their placement/transition and annotate expected system behavior outside the app viewport.

## First Frame Set

Each surface gets one canonical populated/default frame; additional full-window variants are risk-based:

| Family | Must draw in Pen beyond canonical |
| --- | --- |
| Shell/account | Signed out with offline path; waiting device code; expired/denied auth |
| Dashboard/repositories | New user empty; no matches; stale/rate-limited data |
| Dispatch | Typed-input invalid; accepted awaiting run; ambiguous/unknown outcome |
| Run inspector | Failed job with log line; active run with cancel; logs unavailable; long/truncated logs |
| Workspace | Invalid YAML with selected diagnostic; dirty editor + external conflict; no folder/grant denied; missing actionlint |
| Local runner | Missing tool/engine; unsupported job; execution review; running; stopping/cleanup failure; nonzero exit |
| Settings | Missing tools; disconnected/revoked account |
| Feedback/diagnostics | Analytics declined/enabled/unconfigured; sanitized report preview with public-destination warning; blocked raw/unknown report; browser-open/copy fallback |

These full-window frames are in addition to component/state samples; reuse a component sample for remaining errors rather than duplicating every surface. Do not treat a finite frame count as coverage of all state combinations.

## Lifecycle And Persistence Frames

Beyond canonical S14-S18, draw: no-session Manager, Manager with missing + already-open roots; splash degraded route; A+B restored offline; A closed/B restored; same A twice with different selections and one sync; switch reuse/new/focus + failed destination; invalid .runnir while workspace usable; effective environment origins with missing secret reference; local vs published YAML; cache-clear preview preserving private values; corrupt DB recovery without destructive reset.

Prototype system close/quit/Dock behavior with annotated before/after frame pairs. No app UI implementation or functional system prototype is implied.

## Layout And Content Stress Cases

Verify 980 x 640, 1280 x 800 and 1440 x 900 point windows. Include one and many repositories/workflows, 60+ character names, long branch paths, 0/1/many jobs, multiple attempts, multiline inputs, 0/1/100+ diagnostics and long log lines. Main interaction remains readable; horizontal scrolling is acceptable in code/logs but not as a substitute for a broken form.

Preserve editor/selection/filter state on navigation where appropriate. Focus after a diagnostic jumps to the corresponding editor location; a search result jumps to a log line. Window-level dialogs restore focus to their trigger. Keyboard and VoiceOver order follow the visible task hierarchy.
