# Optional Analytics And Crash Reporting

Status: proposed requirements/design, 2026-10-13. No analytics SDK, endpoint, consent UI, crash collector or automatic issue publisher is implemented. The issue template is repository infrastructure only. Implemented 2026-10-22: the toolbar GitHub link (an icon button with the GitHub mark) and a manual Report a Bug sheet in the sidebar that previews the environment lines (app, Core and macOS versions, architecture) and opens a prefilled new-issue page built with URLComponents; no crash import, no diagnostic summary, no Copy Link fallback yet.

## Independent User Choices

Analytics is off by default. Offer a non-blocking, dismissible invitation after the user has reached useful work, not a required onboarding step. Example title: Help improve Runnir. Explain the actual data categories/destination and offer Enable Usage Analytics and Not Now with equal clarity. Russian title: "Помогите нам улучшать приложение"; choices: "Разрешить аналитику" / "Не сейчас". Final localized copy belongs in design review.

Settings > Privacy & Diagnostics exposes analytics consent, payload information, local diagnostic history/clear controls and Report a Problem. Analytics consent never authorizes crash publication, repository upload or an external AI call. Reporting a problem never enables analytics. Decline persists; no repeated nagging. Withdrawal stops collection/transmission and discards unsent analytics immediately. No pre-consent event buffering for later upload, including consent-prompt impressions.

Do not enable delivery until the endpoint/operator, hosting region, exact schema, retention, deletion/contact route and consent version are documented. The app works fully offline/without consent; no mandatory backend/account. Analytics transport is optional infrastructure, not a dependency of CI operations. Automatic crash upload is not part of this first design.

## Analytics Allowlist

Start with coarse local aggregate counts and fixed enums, not free-form tracking:

| Allowed category | Example | Excluded context |
| --- | --- | --- |
| Application environment | App version/build, OS major/minor, arm64/amd64 | Username, machine name, serial, exact host paths |
| Feature completion | Local validation succeeded/failed, run inspector opened, dispatch submission outcome | Repository/workflow/job/ref/input identifiers or contents |
| Reliability | Fixed internal error category, duration bucket, app/Core availability result | Error messages, exception text, subprocess stderr or response bodies |

Use explicit typed constructors/schema validation and reject unknown fields before queuing/sending. No autocollection SDK defaults, session replay, screenshots, editor/log capture, clipboard access, dynamic URL capture, device fingerprint, GitHub identity or persistent cross-session identifier. Do not hash repository names/paths/SHAs and call them anonymous. No fine-grained activity timelines.

Never send code, YAML, diffs, repository URLs/names, commits/branches, workflow inputs/presets, action/job names, logs, credentials, environment variables, shell arguments, local paths or user-entered text as analytics. Collecting a counter must not inspect those values. Coarse usage counts cannot establish exact unique/weekly active users; do not promise that measurement.

Proposed bounds: batches of daily counters, no exact event timestamps, at most seven days of unsent aggregates and a small fixed queue (256 KiB maximum), oldest dropped when full. Endpoint retention must be approved before delivery. HTTPS operators may observe network IP/request metadata; do not claim complete anonymity or zero personal-data processing. Never join analytics with GitHub issue authors or affiliate activity.

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
4. Select/document an optional analytics destination and review dependency license/autocollection behavior; implement consent and strict allowlist before enabling transmission.

Tests must establish zero app analytics transmission/queuing before consent and after withdrawal, independent crash approval, queue/retention bounds, schema rejection/redaction, destination pinning, Unicode/encoding/long-URL handling, no token reuse, no duplicate publication and truthful handoff states. Compare actual outbound payloads with UI previews using synthetic secrets and repositories.

This is an explicit extension to the MVP plan, not evidence of working telemetry/crash reporting. Automatic backend-to-GitHub issue creation is later work requiring private intake, redaction, deduplication, abuse/rate limits and maintainer-controlled publication. It is not a requirement to run Runnir.
