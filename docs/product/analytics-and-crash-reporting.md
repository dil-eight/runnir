# Analytics And Crash Reporting

Status: analytics design approved on 2026-10-25 ([spec](../superpowers/specs/2026-10-25-anonymous-analytics-design.md)), not implemented; it replaces the off-by-default consent model of 2026-10-13. AGENTS.md, README, SECURITY.md, FR-07, the privacy policy and the app's Settings texts still say "no telemetry by default" and change with the implementation. Crash reporting below is still the proposed design of 2026-10-13. No analytics endpoint, consent UI, crash collector or automatic issue publisher is implemented. The issue template is repository infrastructure only. Implemented 2026-10-22: the toolbar GitHub link (an icon button with the GitHub mark) and a manual Report a Bug sheet in the sidebar that previews the environment lines (app, Core and macOS versions, architecture) and opens a prefilled new-issue page built with URLComponents; no crash import, no diagnostic summary, no Copy Link fallback yet.

## Analytics Levels

| Level | Sent | Set by |
| --- | --- | --- |
| Basic (default) | `first_launch` once per install; daily saved-minute counts; no id | First launch; "Basic Counts Only" in the prompt; Settings |
| Usage analytics | Basic, plus daily counts of sections and actions, with a random analytics id | "Share Usage Analytics" in the prompt; Settings |
| Off | Nothing; nothing is counted | Settings › Privacy only |

The consent prompt (O10) is shown once, when the first workspace window opens, without blocking work. It states what Basic sends without consent, what Usage analytics adds, what is never sent and that PostHog stores the data in the United States. Both choices have equal weight. Settings › Privacy has the three levels, the counters waiting to be sent, and the analytics id with Copy for a deletion request. Leaving Usage analytics deletes the id and unsent section and action counts; each new consent gets a new id. Off empties everything unsent. Analytics consent never authorizes crash publication, repository upload or an external AI call; reporting a problem never changes the level. The app works fully offline and without analytics.

Destination: PostHog Cloud US over HTTPS from the Go Core, no SDK, no person profiles, GeoIP off, client IP discarded by the project. Only Release builds have the key. HTTPS operators may still observe network IP and request metadata; do not claim complete anonymity. Never join analytics with GitHub issue authors or affiliate activity.

Deduplication: one ledger per Mac; daily counts are sealed into immutable batches with a random `batch_id`, a retry resends the same batch, and every read takes one event per `batch_id`. Counts come only from what this Mac did, so two Macs of a team never count the same GitHub run. Bounds: batches of daily counters, no event time finer than the UTC day, at most seven days and 256 KiB unsent, oldest dropped first.

## Analytics Metrics

Saved-minute counts (Basic and Usage analytics). Raw parts; which of them make "saved minutes" is decided when reading.

| Counter | Meaning |
| --- | --- |
| `local_runs` | Local runs on this Mac that ended succeeded or failed (B31's `LOCAL_RUNS` count) |
| `local_billed_minutes` | Their jobs' time, each job rounded up to a whole minute, as GitHub bills: the number on the Saved tile |
| `local_jobs_succeeded`, `local_jobs_failed`, `local_jobs_cancelled` | Jobs run by act on this Mac, by result |
| `local_job_seconds` | Those jobs' total local time |
| `gh_ref_jobs_matched` | Succeeded or failed local jobs with a reference on GitHub: the latest completed run of a job with the same name in the same workflow file, in the workspace cache |
| `gh_ref_billed_minutes` | The references' GitHub durations, each rounded up to a whole minute |
| `local_billed_minutes_matched` | The local billed minutes of those same matched jobs |
| `local_runs_completed`, `local_run_wall_seconds` | Local runs of a whole workflow (or scenario) from start to end |
| `gh_ref_runs_matched`, `gh_ref_run_wall_seconds` | For those, the latest completed GitHub run of the same workflow (or scenario), queue plus execution; the difference from local wall time is the developer's wait |
| `superseded_cancels`, `superseded_cancel_minutes_est` | Superseded runs cancelled with Runnir's Cancel on this Mac; estimate: the workflow's median successful duration minus the time the run had run, at least 0 |
| `concurrency_inserted` | Workflow files saved on this Mac with the concurrency block inserted by B30's suggestion |
| `concurrency_cancels`, `concurrency_minutes_est` | Runs of such a workflow that GitHub later cancelled while superseded; counted only by the Mac that saved the block, each run once |

Section and action counts (Usage analytics only): `screen_*` when a sidebar section, Workspace tab, Manager tab, Settings section or the menu bar list opens; `action_*` when a local run, dispatch, cancel, rerun, workflow save/create/rename, validation, log open/save, preset save/apply, concurrency insertion, favorite, Open on GitHub or Report a Bug happens. Names are the values of the `UsageEvent` proto enum; the spec lists them.

Never sent: code, YAML, diffs, repository URLs or names, owners, commits, branches, tags, workflow, job, action or preset names and inputs, run, job or pull request numbers, hashes of any of these, logs, credentials, environment variables, shell arguments, local paths, error messages or user-entered text. No autocollection, session replay, screenshots, clipboard access, URL capture, device fingerprint or GitHub identity. Collecting a counter must not inspect those values; names outside the allowlist are rejected before sealing. Exact unique or weekly active users exist only among installs at the Usage analytics level.

## Local Diagnostics And Crash Sources

Prefer OS-generated crash information plus app/Core version and an allowlisted summary. Apple documents .ips crash data and its fields; a raw report is not an automatically safe public attachment. See [Apple crash report format](https://developer.apple.com/documentation/xcode/interpreting-the-json-format-of-a-crash-report) and [diagnostic logs](https://developer.apple.com/documentation/xcode/diagnosing-issues-using-crash-reports-and-device-logs).

Keep Swift/macOS crash and Go helper failure distinct. A helper nonzero exit is not proof of a desktop crash; an interrupted-session marker is not proof of a crash either. No broad scanning of ~/Library/Logs/DiagnosticReports or reading unrelated app reports. Start with explicit user-selected import of a Runnir .ips report through the native file picker, or app-owned bounded diagnostic records. Automatic crash acquisition requires a separate design and verification.

Build a new allowlisted summary, rather than sending the raw report after regex replacement. Candidate fields: app/Core version/build, coarse OS/architecture, known component, exception/signal category, build UUID and Runnir-only symbolic frame/module offsets when safely extracted. Omit registers, memory dumps, exception messages, user paths, command lines, environment, workflow/source/log contents and unrelated process/module details. Keep build symbol/dSYM association for useful diagnostics without private source paths.

Unknown formats/fields must be omitted or block sharing; never fall back to raw data. Redaction checks must cover nested JSON, Unicode/encoded paths, URLs, tokens, email and control characters. User-entered reproduction text is optional and reviewed; do not promise to detect every secret in arbitrary prose. No automatic screenshots or log attachments.

Proposed app-managed retention: sanitized records only, max 10 records / 10 MiB / seven days, clearable immediately. Raw imported reports are processed transiently without app-created persistent copies. Clear controls affect Runnir-owned data, not Apple's original OS reports or already-public GitHub issues. No custom crash handler that performs network or unsafe work inside a fatal-signal context.

## GitHub Reporting Flow

Destination: the public [Runnir repository](https://github.com/dil-eight/runnir), verified against origin and the public page on 2026-10-13. Reporting never derives its target from the current user's repository.

Review Problem -> inspect/edit sanitized summary -> explicit Open Prepared GitHub Issue -> browser draft -> user submits on GitHub. No background issue creation per crash, no bundled bot token and no extra issue-write scope on the user's CI credential for the initial browser route.

GitHub supports issue templates and title/body query parameters: [official issue-creation documentation](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/creating-an-issue). Use the checked-in .github/ISSUE_TEMPLATE/bug_report.md once published. It is not live until that file reaches the repository's default branch.

Prefill only the exact bounded title/body approved in the preview. Construct URLs with URLComponents/URLQueryItem, not string concatenation. The UI must explain that opening a prefilled URL transfers its contents to GitHub even before issue submission, and browser history may retain that URL. Never put raw crash data, credentials or hidden extra fields into it.

If the draft exceeds tested URL bounds or the user prefers not to include diagnostic text in a URL, offer explicit Copy Sanitized Summary and open the plain template for pasting. Do not silently truncate, upload attachments elsewhere or modify the clipboard without user action. Browser handoff means Draft Opened, not Issue Created; only a verified published issue URL can establish creation. Failed/uncertain handoff retains the local draft without blind duplicate submission.

Public issue warning: the report and GitHub author identity will be public after submission. Show destination and contents before transfer; publishing cannot be undone by switching analytics off. Dedupe using a local sanitized crash signature; let the user decide whether to add to an existing issue. Suspected security vulnerabilities use the SECURITY.md route rather than a public crash issue.

## Public GitHub Link

Add a small GitHub/external-link action at the trailing edge of the main window toolbar, beside secondary Help/feedback actions and separated from Run/Stop. Tooltip/accessibility label: Open Runnir on GitHub. Target: https://github.com/dil-eight/runnir. It remains available when signed out/offline; failed browser handoff offers Copy Link, with no background request on render/hover.

At minimum width it may enter the native toolbar overflow, with a Help-menu fallback. Settings > About also contains the project link and Report a Problem. No changing star counts, authenticated GitHub widget, tracking redirect or repository identifiers in the link.

## Implementation And Verification Gates

1. Design the toolbar action, optional consent invitation, settings controls and diagnostic preview/recovery states; preserve core MVP flows.
2. Implement static link + manual issue draft/preview before choosing analytics/crash dependencies. Issue template alone does not constitute crash collection.
3. Implement explicit local report import/summarization and redaction tests; verify access in a signed build and bounded retention.
4. Analytics as in the [2026-10-25 spec](../superpowers/specs/2026-10-25-anonymous-analytics-design.md): ledger, levels and allowlist before the first Release build that sends; PostHog project set to discard client IP data and its retention written into the privacy policy.

Tests must establish that only Basic counts are sent before consent, nothing is counted or sent at Off, section and action counts and the id leave with withdrawal, every count is sent in exactly one batch, independent crash approval, queue/retention bounds, schema rejection/redaction, destination pinning, Unicode/encoding/long-URL handling, no token reuse, no duplicate publication and truthful handoff states. Compare actual outbound payloads with UI previews using synthetic secrets and repositories.

This is an explicit extension to the MVP plan, not evidence of working telemetry/crash reporting. Automatic backend-to-GitHub issue creation is later work requiring private intake, redaction, deduplication, abuse/rate limits and maintainer-controlled publication. It is not a requirement to run Runnir.
