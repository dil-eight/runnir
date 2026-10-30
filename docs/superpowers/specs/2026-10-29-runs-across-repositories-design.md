# Runs across repositories (B39)

Status: design approved on 2026-10-29, built on branch dilbarov/runs-across-repositories. Drawn in `runnir.pen` (journey F, Row — Runs across repositories (B39)). Builds on the pull requests menu (S19), the workspace runtimes (B27), the repository link of a workspace (B07), the starred repositories of the Workspace Manager's GitHub tab, the status groups of the filter (B42), global search's way of opening a run (B43) and the marks of B46.

## Problem

Runnir shows a repository's runs only inside its workspace window. Someone who works across several repositories has to open each workspace, or github.com, to learn whether one of their runs failed or is still going. The menu bar shows pull requests and their checks, but not runs: a dispatch, a push to a branch without a pull request or a scheduled run that failed stays out of sight.

## Decisions

| Question | Decision |
| --- | --- |
| Where the list lives | A Runs tab beside Pull requests, in the menu bar window and in the Pull Requests window (⌥⌘R). One control switches them |
| Which repositories | Every registered workspace linked to a GitHub repository (B07), open or closed, and every repository starred in the Workspace Manager's GitHub tab. A repository in both counts once |
| Whose runs | Only the signed-in user's: runs whose `actor` is the user's login on that server. A teammate's run, or one the user re-ran but did not start, is not listed |
| What counts as failed | Still failing: the user's newest finished run of a workflow on a branch is in the Failed group of B42 (failure, timed out, startup failure) and finished in the last 7 days. A later finished run of that workflow on that branch, or a re-run, that is not failed takes it off. The user can remove a row by hand |
| What counts as running | Runs not completed: in progress, queued, waiting, requested, pending |
| Where the runs come from | An open workspace answers from its runtime, with no extra request. Every other repository is read by the Core from GitHub, one conditional request each, at most every 3 minutes |
| What a click opens | A repository with a workspace: its window (opened or brought forward) with the run in the inspector. A repository without one: the run on GitHub |
| Where From Runnir shows | On every run Runnir started, whether its workspace is open or closed. A closed workspace's database is read read-only for it, as global search reads it (B43) |
| Colour of the tab's count | Neutral, in the colour of the control, not red |

## The Core

### Rules

A new package `core/internal/watch` holds the rules, apart from any I/O:

- `Pick(runs, login, now)` returns the failed and the running runs of one repository.
  - Only runs whose `Actor` equals `login`, compared without case.
  - **Running:** `status` is not `completed`.
  - **Failed:** the runs are grouped by workflow (`WorkflowID`) and branch. In each group the newest finished run decides: it is listed when `runsearch.StatusOf` puts it in `Failed` and its `UpdatedAt` is within 7 days of `now`. A newer finished run that succeeded, was cancelled or was skipped lists nothing. A re-run changes the run's own conclusion, so a re-run that passed lists nothing either.
  - Both lists are newest first, by `UpdatedAt` for failed runs and by `CreatedAt` for running ones.
- The rules are the same for a workspace's saved runs and for runs read from GitHub.

### Reading

The watcher lives in the server, next to `ListPullRequests`:

- **An open workspace** (a runtime exists for one of the `workspace_ids` the app sent) answers from its store. The newest saved runs of the last 7 days are given to `Pick`. No request is made: the workspace's own sync loop (B27) keeps them fresh. `read_at` is the runtime's last successful pass.
- **Any other repository** is read with `RunsIfChanged` with `actor=<login>` and `per_page=50`, with the ETag the watcher kept for it.
  - A 304 keeps the runs read before and does not count against GitHub's primary rate limit.
  - The ETags and the runs are kept in memory only. Nothing is written to a closed workspace's database, so its saved runs stay as they were and the one-writer rule of B27 holds.
  - At most 4 repositories are read at once.
  - A repository read less than 3 minutes ago answers from memory. A refresh the user asks for (the refresh button) reads it again.
- **The marks of B46.** Runnir keeps its starts in the database of the workspace they were sent from. The starts of a repository are joined from every workspace the app sent for it:
  - an open one gives them from its store;
  - a closed one gives them from its database opened read-only (`store.OpenReadOnly`), guarded by the runtimes' claim the way global search is, so the workspace does not open in the middle of the read;
  - the databases are read only when the repository has a failed or running run to list, at most 4 at once;
  - a database that cannot be read gives no marks, and its runs are listed anyway.
  - A starred repository with no workspace has no starts: Runnir starts runs only from a workspace (B46).
- **The login** of each server is read once with `GET /user` and kept with the credential. It is read again when the credential changes. A server without a credential answers every repository of it as signed out, with no request.
- **The rate limit.** The GitHub client keeps the `X-RateLimit-Remaining`, `X-RateLimit-Limit` and `X-RateLimit-Reset` of its latest answer. When fewer than 10% of the requests are left, the watcher reads nothing on that server until the reset time. It answers with the runs it holds and `paused_until`. A `RateLimitError` pauses it the same way. The workspace runtimes keep their own schedule.
- **Access.** A 403 that is not the rate limit, or a 404, gives the repository the access status the other answers use (no Actions access, not found). It is listed with no runs, so the app can say which repositories were skipped.
- **The budget.** At most 100 repositories are watched. Workspaces come first, in the order the app sent them, then starred repositories in the order they were starred. The rest are answered as not watched, with no request.

### Contract

Changed in place (no release yet):

- `rpc ListWatchedRuns(ListWatchedRunsRequest) returns (ListWatchedRunsResponse)`.
- `ListWatchedRunsRequest`:
  - `repeated WatchedRepository repositories`;
  - `bool refresh`: read every repository again, ignoring the 3 minutes.
- `WatchedRepository`: `github_server`, `repository` (`owner/name`), `repeated string workspace_ids` (every registered workspace linked to the repository, the one a click opens first; empty for a starred repository without a workspace).
- `ListWatchedRunsResponse`:
  - `repeated WatchedRuns repositories`, in the order of the request;
  - `repeated ServerPause pauses` (`github_server`, `until`).
- `WatchedRuns`:
  - `repository` (the `WatchedRepository` it answers);
  - `GitHubStatus status`;
  - `bool watched` (false beyond the 100);
  - `repeated WorkflowRun failed` and `repeated WorkflowRun running`, with `runnir_starts` (B46) from all the repository's workspaces, open or closed;
  - `google.protobuf.Timestamp read_at` (zero when never read).

## The app

### Tabs

- The menu bar window and the Pull Requests window get a segmented control at the top: Pull requests | Runs. It replaces the "Pull Requests" title. Refresh and Open window stay beside it, and the "Updated …" line moves under it.
- The Runs tab carries the number of failed runs in a neutral count, in the colour of the control. With no failed run there is no count.
- The chosen tab is kept in UserDefaults and shared by the menu and the window. ⌥⌘R opens the window on it.
- The window's title is the tab's name: "Pull Requests" or "Runs".

### The Runs tab (S19)

- Under the control: "Updated just now · 14 repositories" (the number of repositories watched).
- Chips: "N failed" and "N running", as the pull request chips.
- **FAILED** and **RUNNING** sections with their counts. A section with no rows is not shown.
- **A row** is like a pull request row:
  - the status icon of B42 (failed, timed out, in progress, queued);
  - "Workflow · title" (`name` and `display_title`);
  - below it "owner/name · branch · failed 4 min ago", or "started …", "queued …", "timed out …";
  - the host first when more than one server is signed in;
  - "From Runnir · " first, in the accent colour, when Runnir started the run (B46), from an open or a closed workspace.
- **Hover** highlights the row and says what a click does: "Open in <workspace name>" or "Open on GitHub". A failed row shows a Remove from list control.
- **Click.** A run of a repository with a workspace opens or brings forward that workspace's window and shows the run in the inspector, as a global search result does (B43). One without a workspace opens on GitHub.
- **Removed rows** are kept in `dismissed-runs.json` in the app's support directory, by run id and attempt, so a re-run that fails again comes back. Entries older than 7 days are dropped. "Show Removed (N)" in the footer brings them back, as for pull requests.
- **Notes** under the list, each in one line:
  - "N repositories skipped: Runnir can't read their Actions." Their names show on hover.
  - "Watching 100 of 130 repositories: workspaces first, then starred ones in the order you starred them." The rest show on hover.
- **Footer:** "Open Runs Window ⌥⌘R" and Show Removed.

### Which repositories the app sends

- Repositories of registered workspaces (B07), in the registry's order of their first workspace, each with all its workspaces in `workspace_ids`. The first open one comes first, else the first in the registry, and a click opens it.
- Then starred repositories, in the order they were starred, with no `workspace_ids`.
- A repository is sent once. A starred repository that also has a workspace is sent with its workspaces.

### Reading

`WatchedRunsModel`, built like `PullRequestsModel`:

- While an account is signed in it asks the Core every 3 minutes.
- When the menu or the window opens, it asks again if its list is older than a minute.
- The refresh button asks with `refresh`.
- A sign-out clears the list.
- It also asks again when the registered workspaces or the starred repositories change.

### Menu bar icon

- The dot shows the worse of the pull request checks and the runs: red when a check failed or FAILED holds a run not removed from the list, the running colour when checks or runs are running.
- The accessibility label names both: "Runnir, a run failed, checks running".

## States drawn

1. Failed and running: the Runs tab with its count, two failed runs (one hovered with "Open in runnir" and Remove, one timed out on an Enterprise server), three running (one from Runnir, one queued), a skipped repository and Show Removed.
2. The Pull requests tab with the same control and the Runs count.
3. Nothing failed or running: "Your runs in 9 workspaces and 5 starred repositories."
4. Nothing to watch: "Star repositories in the Workspace Manager's GitHub tab, or link a workspace to its GitHub repository…" and Open Workspace Manager.
5. Paused for the rate limit: "Paused until 14:05 to keep the GitHub rate limit. These runs were read at 13:40.", the runs read before, 100 of 130 watched and two skipped.
6. Offline: "GitHub can't be reached. These runs were read at 13:40."

Not drawn: signed out and checking the sign-in. The Runs tab shows the same screens as the Pull requests tab. The Pull Requests window shows the same tabs as the menu.

## Not in this change

- Teammates' runs and runs on the default branch started by others.
- Notifications for runs that fail in repositories without an open workspace.
- Writing the runs read for a closed workspace into its database.
- A setting for the 3 minutes, the 7 days or the 100 repositories.
- Opening a run of a repository without a workspace inside Runnir.

## Tests

- **Core, rules (`watch.Pick`).**
  - The newest finished run of a workflow on a branch failed: listed.
  - Fixed by a later run, or by a re-run of the same run: not listed.
  - A later cancelled or skipped run: not listed.
  - Failed 8 days ago: not listed.
  - Another actor, and the login in another case.
  - Queued, waiting, requested, pending and in progress are running; completed with action required is not.
  - Two branches and two workflows kept apart, and the order of both lists.
- **Core, watcher (fake GitHub server).**
  - `actor` and `per_page` sent; the ETag sent again and a 304 keeps the runs.
  - Read again only after 3 minutes, or with `refresh`.
  - 403 and 404 answered as a status, not an error.
  - Paused below 10% of the limit and after a `RateLimitError`, until the reset.
  - 100 repositories watched, in order; the rest unwatched with no request.
  - An open workspace answers from its store with no request, with its B46 starts.
  - A closed workspace gives its starts from its database read-only, and the file is not changed; two workspaces of one repository give their starts together; a database that cannot be read gives no marks and the runs are still listed; no database is read for a repository with nothing to list.
  - Two servers with their own logins; a server signed out makes no request.
  - The login read once per credential.
- **App.**
  - The repositories sent: workspaces first, starred after, a repository sent once with all its workspaces, the open one first.
  - The sections, the chips and the tab's count.
  - Removed rows, and a failed new attempt coming back.
  - The icon's dot from pull requests and runs together.
  - The row's words and what a click opens.
- **Not covered by unit tests:** real GitHub, and the menu bar in the running app.

## Delivery

One pull request:

- this spec and the Pen frames;
- the Core: the rules, the watcher, the client's rate limit and login, the contract;
- the app: the tabs, the model, the Runs tab, the icon;
- the docs: the B39 row in the checklist, `grpc-api.md`, `screens-and-states.md`.
