# Runs Linked To Commits And Pull Requests (B30)

Status: design approved on 2026-10-23; not implemented. Backlog: B30 (new) in the [MVP checklist](../../product/mvp-implementation-checklist.md). Builds on the workspace cache and sync of [B26 and B27](2026-10-22-workspace-cache-design.md) and changes two of their decisions: the run budget (200 → 5000) and the GitHub App permissions. Context: [gRPC API](../../architecture/grpc-api.md), [GitHub authentication](../../security/github-authentication.md), roadmap v0.4 (duplicate execution, CI minutes).

## Goal

The Runs section and the Overview show what happened to a change, not only a flat list of runs. Each run says which pull request it belongs to (on the pull request, or after its merge) and which commit it ran on. Runs on older commits of a pull request that a newer push replaced are hidden by default. An optional "By change" view groups runs by pull request and by commit. When superseded runs of a workflow keep running after newer pushes, Runnir suggests a `concurrency` block for the workflow file, which the user reviews in the editor, saves and commits.

Example: pull request #142 runs CI on three pushes, is merged, CI runs on the merge commit on `main`, and someone starts Deploy by hand on that commit. The flat list shows CI on the PR's last commit, CI after merge and Deploy after merge, each labelled `#142`; the two runs on older commits are hidden. "By change" shows one group for #142 with an "After merge" section (CI, Deploy), an "On the PR" section (CI on the last commit) and "2 earlier runs on 2 older commits".

## Decisions Made

| Question | Decision |
| --- | --- |
| "Without a pile of extra runs" | Both: hide superseded runs in Runnir, and suggest `concurrency` with `cancel-in-progress` so GitHub stops them |
| Default Runs view | Flat list. A segmented switch `List \| By change` above it, remembered per window. The default may change after user feedback (no telemetry is added for this) |
| Superseded runs in the flat list and Overview | Completed ones are hidden; a footer row shows how many and reveals them, dimmed. A superseded run still in progress is always shown, labelled "outdated" |
| Who links and groups | The Go Core, in a pure package, from the cache; the app only renders. One implementation for the app, the future CLI and MCP |
| Source of pull request data | The repository's pull request list, read each pass with an ETag, plus bounded lookups for what is missing. The run's own `pull_requests` field is used but not trusted alone: GitHub leaves it empty for forks and reportedly for closed pull requests ([github/docs#22501](https://github.com/github/docs/issues/22501)), and in a fork it lists the upstream's pull requests |
| GitHub App permission | "Pull requests: read" is required (`github.RequiredPermissions`). The app's settings on github.com gained it, and "Commit statuses: read", on 2026-10-23. Installations that have not accepted it are shown as waiting for an owner, as today; until then links work only from the runs' own data. Commit statuses are not used by this design and stay out of `RequiredPermissions` until a feature reads them |
| Cache size | Up to 5000 runs per workspace (was 200). Older runs load from GitHub as the user scrolls; the oldest beyond 5000 are deleted after each write |
| Applying the concurrency suggestion | Inserted into the open file in the Workspace editor as an unsaved edit. Runnir never saves, commits or pushes it by itself |
| Fetching all runs of one pull request | Not done: with 5000 runs cached, the earlier runs of an active pull request are normally cached, and older ones load by scrolling |
| Out of scope | The menu bar pull request list (keeps its live reads; it only benefits from the new permission) and the Manager's GitHub tab (no cache, no links) |

## Terms

- **Link** of a run: `PULL_REQUEST` (ran on a commit of the pull request, before merge), `AFTER_MERGE` (ran on the commit the pull request's merge created) or `NONE`.
- **Change**: a pull request with every run linked to it, or a commit (`head_sha`) with the runs that have no link.
- **Superseded** run: a run linked `PULL_REQUEST` to pull request P, with event `pull_request` or `push`, when a later run of the same workflow and event, linked to P, ran on a different commit. Runs on the same commit (re-runs, repeats) and runs after merge are never superseded.
- **Outdated**: superseded and not completed.
- **Overlap** of a superseded run: how long it kept going after the next run of its workflow and event on a newer commit of P was created. Wall-clock time, not runner minutes.

## GitHub Reads

### Sync Pass

A pass (B27) reads, in order:

1. Runs: `GET /actions/runs?per_page=50` with `If-None-Match`, as today. The parser also keeps each run's `pull_requests` (number and the base repository's API URL), `head_repository.full_name` and the first line of `head_commit.message` (at most 300 characters).
2. Workflows, as today.
3. Pull requests: `GET /repos/{owner}/{name}/pulls?state=all&sort=updated&direction=desc&per_page=50` with `If-None-Match`; ETag scope `pulls`. Kept per pull request: number, title (at most 300 characters), `state`, `draft`, `user.login`, `html_url`, `head.ref`, `head.sha`, `head.repo.full_name` (empty when the fork was deleted), `base.ref`, `merge_commit_sha` (only when `merged_at` is set), `created_at`, `updated_at`, `closed_at`, `merged_at`.
4. Lookups (below).

The default branch is read with `GET /repos/{owner}/{name}` (Metadata read, always granted) in the first pass of a runtime and when the target changes, and kept in `cache_source`. A pass that cannot read it fails like any other read.

**Filling a gap.** When the newest page of runs does not reach the cached runs (the oldest run of the page is newer than the newest cached run and no id is shared), the pass reads further pages of 100 with `created=<=T`, where T is the oldest run read so far, until they meet the cache, at most 10 pages. If they still do not meet, cached runs older than the oldest run read are deleted, and the history is marked incomplete. So the cache always holds one unbroken stretch of history, from now back to its oldest run.

**Permissions.** `github.RequiredPermissions` gains `pull_requests: read`. A 403 or 404 on the pull request list or a lookup does not fail the pass: runs and workflows are stored, the outcome is kept as `pull_requests_access` (`PERMISSION_MISSING` or `NOT_VISIBLE`) in `sync_state` scope `pulls`, and pull requests are not read again until the credential changes or the user refreshes. Other errors (unreachable, rate limit, rejected token) fail the pass as today.

### Lookups

After the pull request list, a pass makes at most 10 lookup requests, for the newest runs first:

| What is missing | Request | Remembered as |
| --- | --- | --- |
| A number from a run's `pull_requests` that is not in `pull_requests` | `GET /pulls/{number}` | the pull request row; a 404 as an empty lookup `pr:<number>` |
| The pull request merged into a commit: a run on the default branch with an event other than `pull_request` or `pull_request_target`, no link, and no lookup for its commit | `GET /commits/{sha}/pulls`; only pull requests whose `merge_commit_sha` is that commit are kept | lookup `commit:<sha>` with those numbers, possibly none |
| The pull request of a run from a fork: event `pull_request`, no link, `head_repository` not this repository | `GET /pulls?head=<fork owner>:<branch>&state=all` | lookup `head:<owner/name>:<branch>` with the numbers found |

A lookup answered once is not asked again while its run is cached. Lookups are made only in passes that reached GitHub and while `pull_requests_access` is not a refusal. A network error stops the lookups for this pass; they continue in the next.

### Older Runs

`LoadOlderRuns` reads `GET /actions/runs?per_page=100&created=<=T`, where T is the `created_at` of the oldest cached run, drops runs already cached, and stores the rest. Cached runs between the oldest run of the answer and T that the answer lacks were deleted on GitHub and are removed. Fewer than 100 runs in the answer means the history is complete. When the cache already holds 5000 runs, nothing is requested and the answer says the budget is reached. Concurrent calls for one workspace share one request.

## Store

The schema changes in place; no migration (AGENTS.md: no backward compatibility before the first release tag). Databases from earlier development builds are discarded and filled again.

| Table | Class | Change |
| --- | --- | --- |
| `cache_source` | cache | Adds `default_branch` and `history_complete` (GitHub has no run older than the oldest cached) |
| `runs` | cache | Adds `head_repository` (`owner/name`, lowercased) and `commit_title` |
| `run_pull_requests` | cache, new | `run_id` (foreign key, cascade), `number`; primary key both. Only pull requests whose base is this repository (the API URL ends with `/repos/<owner>/<name>`, compared without case) |
| `pull_requests` | cache, new | The fields listed under Sync Pass; primary key `number`; indexed by `updated_at`, `merge_commit_sha`, `(head_repository, head_ref)` and `head_sha` |
| `link_lookups` | cache, new | `key` (`pr:`, `commit:`, `head:`), `numbers` (JSON array), `fetched_at` |
| `sync_state` | cache | New scope `pulls`: ETag and the last access outcome of pull request reads |

- Links in `run_pull_requests` only accumulate: a run that later comes back with an empty `pull_requests` field keeps its links. They go when the run goes.
- Budgets after every write: runs beyond the newest 5000 by `created_at` are deleted (jobs and steps cascade, kept logs as today); pull requests are kept when a cached run links to them (through `run_pull_requests` or `link_lookups`) or they are among the 500 most recently updated; lookups whose commit or branch no cached run has are deleted.
- Clear Cache empties the new tables too.
- A change to pull requests, links or lookups counts as a change: the pass publishes `ACTIVITY_CHANGED`.

## Package `internal/changes`

Pure functions, no I/O. Input: runs (newest first) with their `run_pull_requests` numbers, pull requests, lookups and the default branch. Output: each run's link and `superseded_by`, the changes, and the overlap statistics per workflow. Links and superseded marks are computed over every cached run; changes over the runs the caller asks for.

### Linking

For each run, the first rule that matches decides:

1. **After merge.** The event is not `pull_request` or `pull_request_target`, and a merged pull request (from the table or a `commit:` lookup) has `merge_commit_sha` equal to the run's `head_sha`. `pull_request_target` runs can carry the base branch's commit, so they never take this rule.
2. **The run's own list.** A number in `run_pull_requests` (or in its `head:` lookup).
3. **Pull request head.** A pull request whose `head_sha` and `head_repository` equal the run's.
4. **Pull request branch.** A pull request whose `head_ref` and `head_repository` equal the run's branch and `head_repository`, and the run was created between the pull request's `created_at` and its `closed_at` (or now while open). Events `pull_request` and `push` only.

Runs on the default branch with an event other than `pull_request` or `pull_request_target` take only rule 1, so a push to `main` is never linked to a pull request from `main` (a release pull request, for example). When several pull requests match one rule, the most recently updated one wins.

### Superseded And Overlap

For each run R linked `PULL_REQUEST` to P with event `pull_request` or `push`, the later runs of the same workflow and event linked to P on another commit are its successors.

- `superseded_by`: the newest successor; 0 when there is none.
- Overlap: with N the earliest successor, when R's conclusion is not `cancelled` and R's `run_attempt` is 1 (a deliberate re-run of an old commit is not counted), overlap = (R's `updated_at` when completed, else now) − N's `created_at`, when positive.
- Statistics per workflow: the runs with an overlap, their total in minutes (rounded up) and the pull requests involved.

### Changes

- A run linked to P belongs to change `pr:<P>`; a run without a link belongs to `commit:<head_sha>`.
- Sections of a pull request change: "After merge" (its `AFTER_MERGE` runs, on the merge commit), then "Latest commit": the pull request's `head_sha` when a run is on it, else the commit of its newest linked run. Runs on other commits are `older_run_ids`, newest first, with the number of distinct commits.
- A commit change has one section.
- In a section, `run_ids` hold the newest run per workflow and event; the other runs of that workflow and event on the same commit are `repeat_run_ids`.
- Status of a change: the first section with runs, summed up by the rule the menu bar already uses (`summarizeCI` in `internal/github/pulls.go`, refactored into a shared function that both use): any failure fails, then anything still going (or waiting for approval) is running, then all cancelled is cancelled, else passed.
- Order: by the newest `created_at` among the change's runs, newest first.
- A pull request not in the table (lookup pending or failed) still forms a change: its number, `html_url` built from the server's web URL, its title from the `display_title` of one of its `pull_request` runs, and an empty state.

## Concurrency Suggestion

The scanner (`internal/scanner`) reports whether a workflow file has a `concurrency` key at the top level or in any job (`Workflow.concurrency`).

The Core adds a `ConcurrencyHint` for a workflow to the activity when all of these hold:

- at least 2 cached runs of it have an overlap;
- the file with the workflow's path exists in the working tree, parsed without error, has no `concurrency`, and is triggered by `pull_request` or `push` (not only `workflow_call`).

The working tree may be on another branch than the runs; the hint reflects the file the user can edit now.

The block:

```yaml
# Newer commits on a pull request or branch cancel its older runs; runs on the default branch, scheduled and manual runs are never cancelled.
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || (github.event_name == 'push' && github.ref != format('refs/heads/{0}', github.event.repository.default_branch) && github.ref) || github.run_id }}
  cancel-in-progress: true
```

| Event | Group | Effect |
| --- | --- | --- |
| `pull_request`, `pull_request_target` | workflow and pull request number | A newer run cancels the older one in progress |
| `push` to a branch other than the default | workflow and ref | A newer push cancels the older run in progress |
| `push` to the default branch, `schedule`, `workflow_dispatch`, others | workflow and `run_id`, unique | Never cancelled, never queued |

`InsertWorkflowConcurrency` (in `internal/scanner`, no file access) takes the editor's text and returns it with the block:

- Parsed with `yaml.v3`. Refused: not parseable (`PARSE_ERROR`); more than one document or a flow-style top-level mapping (`NOT_BLOCK_MAPPING`); a `concurrency` key at the top level or in a job (`ALREADY_PRESENT`); no top-level `jobs` (`NO_JOBS`); over 1 MiB (`TOO_LARGE`).
- The block goes before the top-level `jobs:` line, or before the comment lines directly above it, followed by one blank line, with a blank line before it when the line above is not blank.
- The file's line ending (`\r\n` when the text has one) is used for the new lines.
- The answer gives the first and last inserted line (1-based).

## gRPC Contract (`runnir.core.v1`, changed in place)

```proto
rpc LoadOlderRuns(LoadOlderRunsRequest) returns (LoadOlderRunsResponse);
rpc InsertWorkflowConcurrency(InsertWorkflowConcurrencyRequest) returns (InsertWorkflowConcurrencyResponse);

message GetWorkspaceActivityRequest { string repository_id = 1; uint32 limit = 2; }  // 0 → 200, at most 5000
message RefreshWorkspaceActivityRequest { string repository_id = 1; bool wait = 2; uint32 limit = 3; }

message WorkspaceActivity {
  repeated WorkflowRun runs = 1;                    // newest first
  repeated GitHubWorkflow workflows = 2;
  ActivityFreshness freshness = 3;
  repeated RunChange changes = 4;                   // from the runs above, newest first
  repeated ConcurrencyHint concurrency_hints = 5;
  uint32 cached_runs = 6;                           // every run in the cache
  bool history_complete = 7;                        // GitHub has no run older than the oldest cached
}

message ActivityFreshness {
  // fields 1–6 unchanged
  // Reading pull requests: UNSPECIFIED before a read, else OK,
  // PERMISSION_MISSING or NOT_VISIBLE.
  GithubAccess pull_requests_access = 7;
}

message WorkflowRun {
  // fields 1–15 unchanged
  string head_repository = 16;   // "owner/name" the commit came from; a fork's differs
  string commit_title = 17;      // first line of the head commit's message
  RunLink link = 18;             // set in workspace activity only
  int64 superseded_by = 19;      // 0 when not superseded; workspace activity only
}

enum RunLinkKind {
  RUN_LINK_KIND_UNSPECIFIED = 0;
  RUN_LINK_KIND_NONE = 1;
  RUN_LINK_KIND_PULL_REQUEST = 2;
  RUN_LINK_KIND_AFTER_MERGE = 3;
}
message RunLink { RunLinkKind kind = 1; int64 pull_request = 2; }

message RunChange {
  string id = 1;                             // "pr:142" or "commit:<sha>"
  ChangePullRequest pull_request = 2;        // set for a pull request
  PullRequestCi status = 3;
  google.protobuf.Timestamp latest_at = 4;
  repeated RunChangeSection sections = 5;    // after merge, then latest commit; a commit has one
  repeated int64 older_run_ids = 6;          // older commits of the pull request, newest first
  uint32 older_commits = 7;
}
message ChangePullRequest {
  int64 number = 1;
  string title = 2;
  string state = 3;                          // "open", "closed", "merged"; empty when not read yet
  bool draft = 4;
  string author = 5;
  string html_url = 6;
  string head_branch = 7;
  string base_branch = 8;
  google.protobuf.Timestamp merged_at = 9;
}
enum RunChangeSectionKind {
  RUN_CHANGE_SECTION_KIND_UNSPECIFIED = 0;
  RUN_CHANGE_SECTION_KIND_AFTER_MERGE = 1;
  RUN_CHANGE_SECTION_KIND_LATEST_COMMIT = 2;
  RUN_CHANGE_SECTION_KIND_COMMIT = 3;
}
message RunChangeSection {
  RunChangeSectionKind kind = 1;
  string head_sha = 2;
  string branch = 3;
  string commit_title = 4;
  repeated int64 run_ids = 5;                // newest per workflow and event
  repeated int64 repeat_run_ids = 6;         // older runs of the same workflow and event here
}

message ConcurrencyHint {
  int64 workflow_id = 1;
  string path = 2;
  uint32 runs = 3;                           // runs with an overlap
  uint32 overlap_minutes = 4;                // wall-clock, rounded up
  repeated int64 run_ids = 5;                // may include runs outside WorkspaceActivity.runs
  repeated int64 pull_requests = 6;
}

message LoadOlderRunsRequest { string repository_id = 1; }
message LoadOlderRunsResponse {
  GitHubStatus status = 1;
  uint32 added = 2;
  bool history_complete = 3;
  bool budget_reached = 4;                   // 5000 runs cached; older ones stay on GitHub
}

message InsertWorkflowConcurrencyRequest {
  string repository_id = 1;
  string content = 2;                        // the editor's text, at most 1 MiB
}
enum ConcurrencyRefusal {
  CONCURRENCY_REFUSAL_UNSPECIFIED = 0;
  CONCURRENCY_REFUSAL_NONE = 1;
  CONCURRENCY_REFUSAL_ALREADY_PRESENT = 2;
  CONCURRENCY_REFUSAL_NO_JOBS = 3;
  CONCURRENCY_REFUSAL_NOT_BLOCK_MAPPING = 4;
  CONCURRENCY_REFUSAL_PARSE_ERROR = 5;
  CONCURRENCY_REFUSAL_TOO_LARGE = 6;
}
message InsertWorkflowConcurrencyResponse {
  string content = 1;                        // empty when refused
  uint32 first_line = 2;
  uint32 last_line = 3;
  ConcurrencyRefusal refusal = 4;
}

message Workflow {
  // fields 1–6 unchanged
  bool concurrency = 7;                      // a concurrency key at the top level or in a job
}
```

Errors: unknown repository `NOT_FOUND`; activity or `LoadOlderRuns` for a repository opened without `workspace_id` `FAILED_PRECONDITION`; limit over 5000 `INVALID_ARGUMENT`. `ListWorkflowRuns` (live, also for repositories without a clone) leaves fields 18 and 19 unset.

## App (Swift)

**Runs section.**

- Header: segmented `List | By change` (`@SceneStorage`, default List), the current-branch checkbox (both modes; in By change it keeps changes with a run on that branch), Reload.
- Row detail: `CI #881 · main · push · #142 after merge`, `… · #142`, or the short commit when there is no link. Help: the pull request's title and the commit title.
- List: completed superseded runs are hidden; a footer row "6 superseded runs hidden · Show" reveals them dimmed with "older commit" (not remembered). An outdated run shows an "outdated" label, with help naming the newer run.
- By change: one block per change. A pull request header shows status, `#142 Title`, state (open, draft, merged, closed) and branch; a commit header shows status, short sha, commit title and branch. Sections show their runs as rows; "N earlier runs on M older commits" and "N earlier runs on this commit" expand in place.
- Selecting a run opens the inspector as today. The selection stays when its run becomes hidden.
- Lazy loading: the session's activity limit starts at 200 (was 50, `CoreHub.activityLimit`). When the last row appears, the limit grows by 200 and the activity is read again from the cache. When the cache has no more runs and the history is not complete, the app calls `LoadOlderRuns` and shows "Loading older runs…", then the runs or "Couldn't load older runs" with Retry. With `budget_reached` the last row says older runs are on GitHub and opens the repository's Actions page.
- When `pull_requests_access` is a refusal, a note under the freshness line: "Pull requests can't be read, so runs after a merge and from forks are not linked", with the existing access help (an installation waiting for an owner to accept "Pull requests: read", or what a token needs).

**Run inspector.** Under the title: "Pull request #142 Add retry to deploy · merged" (opens the pull request) and "Commit a1b2c3d Bump retry count". A superseded run adds "Superseded by CI #883 on a newer commit", which selects that run; an outdated run keeps the existing Cancel action (B13) next to it.

**Concurrency suggestion.** A banner in the inspector of a superseded run of a workflow with a hint, and under the pull request in By change when the hint names it: "3 runs of CI on older commits kept running after a newer push (about 18 min)." Buttons: "Add concurrency…" and "Don't suggest for this workflow" (kept on this Mac per workspace and workflow path, in a JSON file next to the favorites). "Add concurrency…" switches to the Workspace section and opens the file with the usual unsaved-edits handling, sends the editor's text to `InsertWorkflowConcurrency`, replaces the text as one undoable edit and scrolls to the inserted lines. A refusal is shown as a message and the text stays as it was. Saving, validation and conflicts follow B04.

**Overview.** Recent Runs follows the list rules (labels, completed superseded runs hidden, no grouping). The selected workflow's latest run summary adds `#142` or `#142 after merge`.

**Tokens.** The fine-grained token help adds "Pull requests: Read-only".

## Design

Before code: frames in `docs/design/runnir.pen`, row D (Runs): the List mode with labels, the hidden-runs footer and an outdated run; the By change mode with a merged pull request, an open one and a commit; the inspector's link and superseded lines; the concurrency banner; the pull-request-permission note; the loading and end-of-history rows.

## Error Handling Summary

| Case | Behavior |
| --- | --- |
| No "Pull requests: read" | Runs and workflows sync; links only from the runs' own `pull_requests`; the note says what is missing |
| A pull request referenced but not read yet | Change with number, link and a title from its runs; filled by a later lookup |
| A deleted fork (`head_repository` empty) | Rules 3 and 4 skip the run |
| A merge older than everything read | Found by the `commit:` lookup when its run is cached; otherwise the run stays a commit change |
| More than 50 new runs between passes | The pass reads up to 10 more pages; beyond that the older cache is dropped and loads again by scrolling |
| `LoadOlderRuns` fails | Inline message with Retry; cached runs stay |
| Insertion refused | Message with the reason; the editor's text is unchanged |

## Tests

Go (table-driven, `httptest` GitHub, injected clock):

- changes: the example in Goal (three pushes, merge, push run and a manual run on the merge commit); squash and rebase merges; a fork pull request through a `head:` lookup; a release pull request from `main` that never takes `main` pushes; `pull_request_target` never after-merge; repeats on one commit collapse but are not superseded; superseded only across commits; overlap with a cancelled run, a re-run, a running run; status of a change; order; an unknown pull request.
- github: parsing of runs with `pull_requests`, `head_repository` and `head_commit` (null, fork, upstream pull request in a fork) and of pull requests (merged, squash, deleted head repository); the three lookups; `created=<=T` paging.
- store: link accumulation; the 5000 budget with cascade; pull request and lookup budgets; Clear Cache; `ACTIVITY_CHANGED` on link changes.
- workspace sync: pull request list 304; 403 keeps the pass OK and stops pull request reads until a credential change; at most 10 lookups per pass; gap filling and dropping; `LoadOlderRuns` (complete, budget reached, deletion inside the range, shared request).
- scanner: `concurrency` detection; insertion before `jobs:`, before its comments, with CRLF, and every refusal; the result passes the Core's actionlint check.
- server: activity with links, changes and hints over gRPC; `LoadOlderRuns`; `InsertWorkflowConcurrency`; limit validation.
- `go test ./...`, `go vet ./...`, `go build ./...` with `CGO_ENABLED=0`.

Swift (RunnirTests with the fake `CoreServicing`): row detail text; the hidden count and reveal; the mode switch; the limit growing and `LoadOlderRuns` at the end; the dismissal store; the inserted text applied as one edit. The app builds with `xcodebuild`.

## Documentation

- `grpc-api.md`; `github-authentication.md` (the new permission); the B26/B27 spec and `workspace-persistence.md` (5000 runs); `screens-and-states.md`; the MVP checklist (B30 row, B26 budget).
- The GitHub App on github.com has "Pull requests: read" since 2026-10-23; an owner of each installation accepts it. GitHub Enterprise users sign in with tokens, so the token help covers them.

## Not Verified By This Work (stated in the docs)

- A live check against a real repository: a pull request with several pushes, a merge, a push run and a manual run on the merge commit, unless it is done and recorded.
- That GitHub keeps or clears a run's `pull_requests` after its pull request closes: Runnir does not depend on it either way.
- The concurrency block's effect on GitHub, beyond actionlint accepting it, unless a run on a real repository shows the cancellation.
