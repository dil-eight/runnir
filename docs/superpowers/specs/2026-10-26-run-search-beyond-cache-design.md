# Run search beyond the saved runs (B40)

Status: design agreed, states drawn in Pen (Row — Run search, and the S12 storage frame), not implemented.

## Problem

Run search (B33) covers the runs saved on this Mac: the newest 5000, kept as one unbroken stretch of history. It cannot find

- runs newer than the last sync pass,
- runs older than the cache, or dropped from it by the budget,
- runs GitHub has since deleted.

## What GitHub offers

`GET /repos/{owner}/{repo}/actions/runs` filters by `actor`, `branch`, `event`, `status`, `created` (a range), `head_sha`, `check_suite_id` and `exclude_pull_requests`. There is no text search over a run's name or title. With a filter the endpoint returns at most 1,000 results per search; a pass that pages by `created<=` the oldest run read (as `OlderRuns` does) has no such cap. A page holds 100 runs, so reading 1,000 runs costs 10 of the 5,000 requests an hour.

Words from a title can therefore only be matched on this Mac, either in the saved runs, in the search index below, or in pages read from GitHub for the purpose.

## Design

### Three layers of one search

1. **Saved runs and the search index**, instant, as today.
2. **The tail**, in the background. Opening a query asks the runtime for a sync pass. It is a conditional request with the ETag, usually a 304, and merges with the passes other windows ask for. When it brings runs the local result is computed again. State: "Checking GitHub for newer runs…".
3. **A deep search on GitHub**, started by the user ("Not found? Search GitHub…", offered by itself when nothing matches). Pages of 100 by `created<=`, with the query's filters sent to GitHub and the title words matched in the Core. At most 10 pages a step, then "Search deeper"; Cancel, a changed query and a low rate limit stop it. One deep search per repository at a time. A run found is added to the index.

### Core

- One query grammar in Go: words (all must match), `#123`, a SHA or prefix, `branch:`, `author:`, `event:`, `status:`, `workflow:`, `after:`, `before:`. One parse gives the local predicate and the GitHub parameters; the words left are the residue matched locally.
- `SearchRuns(repository_id, query, limit)` reads the saved runs and the index. `SearchRunsOnGitHub(repository_id, query, cursor, page_budget)` reads a step and returns the runs, the cursor, how far back it looked and why it stopped (done, budget, rate limit, cancelled). Unary calls with a cursor, no streaming: the app shows progress and cancels between steps.
- The matcher in Swift (`RunSearch.swift`) goes away, which settles the finding that search logic lived outside the Core.
- `#123` on GitHub resolves the pull request's `head` and `merge_commit_sha` (2 requests) and searches by `head_sha`. Earlier commits of the pull request are found through the index only.

### Search index

- `run_index` in the workspace database: run id, source (server and repository), title, workflow name, SHA, branch, actor, event, status, conclusion, created and updated time, pull request numbers; about 200 bytes a run.
- Filled by everything the Core reads: sync passes, older pages, deep searches. It is not the cache: the cache stays one unbroken stretch of the newest runs.
- Own budget of 50,000 runs a workspace (about 10 MB), oldest evicted first. Kept by Clear Cache, because what GitHub deleted cannot be downloaded again; not part of the local-data backup. Settings › Storage shows its size and has Clear Search Index.
- A result from the index is a light row. Opening it reads the run from GitHub; a 404 shows "GitHub no longer has this run" with the stored title, commit, branch and time, and an option to remove it from the index.

### App

- The search field is as in B33. Below the results: the coverage line ("Showing 3 of 812 saved runs · 12 340 in the search index."), the Search GitHub row, progress with Cancel while searching, a "Found on GitHub" group, and the limit state with "Search deeper" and a hint to narrow with `branch:`, `author:` or `after:`.
- Paused by the rate limit: a notice with the time it resets; saved runs and the index keep working. Offline reads the same way.
- States are in Pen: S07 checking, searching, searched back to the limit, nothing found anywhere, paused, run kept only in the index; S12 Storage with the search index row.

## Delivery

Two sequential pull requests, not stacked:

1. Core: grammar, `SearchRuns`, `run_index` filled by the sync, the tail refresh; the app switches to the RPC and drops the Swift matcher.
2. Deep search: `SearchRunsOnGitHub`, the states above, the Storage row, the "no longer on GitHub" inspector state.

## Tests

- Core: grammar to local predicate and GitHub parameters (table); a fake GitHub for the filter mapping, paging by `created<=`, the page budget, the cursor, the rate-limit stop and cancellation; index fill, eviction and survival of Clear Cache.
- App: the states of the search model for each outcome; the Search GitHub row only while a deep search is possible.
- Not covered by unit tests: a real deep search against GitHub, a window with 50,000 indexed runs.
