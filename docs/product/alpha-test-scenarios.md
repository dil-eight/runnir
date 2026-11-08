# Alpha Test Scenarios

Status: by-hand checks before the first alpha (`v0.1.0-alpha.1`), written 2026-11-08. They collect the "Missing for acceptance" column of the [MVP checklist](mvp-implementation-checklist.md), the L01-L10 cases of [desktop lifecycle](../architecture/desktop-lifecycle.md) and the W01-W09 cases of [workspace persistence](../architecture/workspace-persistence.md) into one pass.

**Gate** marks a scenario that must pass before the alpha is published; the others are recorded and may ship as known issues in the release notes.

## Builds

| Build | What it can check | What it cannot |
| --- | --- | --- |
| Runnir Local (`RUNNIR_BUILD=local`, signed and notarized on a Mac) | Everything in sections 1-10 | Analytics sending (no token), updates (local builds never update), the ALPHA mark, the CI signing path |
| `v0.1.0-alpha.1` from the release workflow | Section 11 | — |
| `v0.1.0-alpha.2` | The update from one tag to the next (11.6) | — |

Runnir Local has its own data, logs, caches and Keychain items, so it runs beside Runnir Dev without touching it.

## Fixtures

- A GitHub test repository the account owns, cloned on this Mac, with:
  - `ci.yml`: push and pull request; a job that fails on purpose, a job that `needs` it (skipped), a matrix of 2-3, a job with `if:` false for pull requests;
  - `deploy.yml`: `workflow_dispatch` with a required string, a choice, a boolean and an input that looks secret (`token`), and a job waiting for an environment approval;
  - `local.yml`: an `ubuntu-latest` job that echoes `secrets.API_KEY` and `vars.REGION`;
  - an open pull request with two pushes.
- A second account or organization where the Runnir Desktop GitHub App is installed (B07).
- OrbStack running; Docker Desktop or Colima if available.
- A folder that is not a Git working tree, and one copy of the test repository in `~/Documents`.

## 1. Install And First Launch

| ID | Scenario | Expected |
| --- | --- | --- |
| A01 Gate | Download the zip in a browser, unzip, move to Applications, open | Opens without a Gatekeeper warning (notarized, stapled); `spctl -a -vv` says Notarized Developer ID |
| A02 Gate | First launch | Splash, then the Workspace Manager; nothing written into any repository |
| A03 Gate | The analytics question in the first workspace window | Shown once, both answers work, Settings › Privacy shows the level and what is sent |
| A04 | Quit and open again | No Keychain password prompt at any point |

## 2. GitHub Sign-In

| ID | Scenario | Expected |
| --- | --- | --- |
| G01 Gate | Sign in with the device code | Signed in; the token only in Keychain |
| G02 Gate | Quit, open again | Still signed in, no prompt |
| G03 | Sign out | Signed out; workspaces and saved runs stay |
| G04 | Revoke the app's authorization on github.com, then refresh | Runnir says the sign-in was rejected and asks to sign in again |
| G05 | Turn Wi-Fi off, open Runnir | Saved data shown with the offline state; it recovers by itself when the network returns |
| G06 | Manager › GitHub tab | Repositories of every installation, search, owner filter, starred first |

## 3. Workspaces And Windows

| ID | Scenario | Expected |
| --- | --- | --- |
| W01 Gate | Import the test repository | Opens on Overview; no file written in it (`git status` clean) |
| W02 | Import the folder that is not a Git working tree | Says so; nothing registered |
| W03 | Import the copy in `~/Documents` | It opens, and opens again after a relaunch; macOS asks about Documents at most once |
| W04 Gate | Open a second window of the same workspace (Manager › … › Open New Window), give each its own section, quit, open again | Both windows come back with their sections (L02, L06) |
| W05 Gate | Close one window by hand, quit, open again | Only the other window comes back; close it too, relaunch: the Manager (L03) |
| W06 | Close every window, click the Dock icon twice | One Manager (L04) |
| W07 | Switch a window to another workspace (Reuse Current Window) | Same window, new workspace; the first workspace is still registered |
| W08 | Rename the repository folder in Finder, open the workspace | Opens; the path and name follow the folder |
| W09 | Move the folder somewhere Runnir cannot find, open | Locate offered; choosing the folder fixes it, open windows keep their state |
| W10 | With a window on an external display, quit, unplug it, open | The window opens on the built-in display, fully visible (L09) |
| W11 | Quit, replace `desktop-state.json` in `~/Library/Application Support/Runnir Local` with `{`, open | Workspaces come back, no windows, the Manager says the session was restored from a backup (B23) |

## 4. Workflows Editor

| ID | Scenario | Expected |
| --- | --- | --- |
| E01 Gate | Open `ci.yml`, introduce a YAML error | actionlint diagnostics with line and column in the editor |
| E02 Gate | Fix it, save | Saved; diagnostics clear; only that file changed in `git status` |
| E03 | Change the file in another editor while it is open with edits, save in Runnir | Asks: Reload from Disk or Save Anyway; nothing lost |
| E04 | Edit, then close the window or quit | Asks to save, not save or cancel |
| E05 | New workflow file, rename it | Created from the starter, renamed; unsaved edits and the star kept |

## 5. Runs And The Run Inspector

| ID | Scenario | Expected |
| --- | --- | --- |
| R01 Gate | Push to the test repository | The run appears and updates while it runs; the failed job shown as failed |
| R02 Gate | Open the run: graph, a job's steps and log | Columns from `needs`, matrix as `name ×N`; log tail with search; Open in Visual Studio Code works |
| R03 | The skipped job | Says why (a need that failed, a condition false for the event) |
| R04 Gate | Re-run failed jobs, re-run one job, cancel a running run | One confirmation each; GitHub starts or cancels; no second request on an unclear answer |
| R05 | Runs › By change for the pull request | Pushes grouped, superseded runs labelled |
| R06 | Search (`#n`, a commit, `branch:`, `status:`), status filter chips | Matches; works offline on saved runs |
| R07 | Search deeper on GitHub | Older runs found, Cancel works |

## 6. Run Workflow

| ID | Scenario | Expected |
| --- | --- | --- |
| D01 Gate | Run `deploy.yml` on a branch with inputs | Required and choice inputs validated; one confirmation; the run located and marked From Runnir |
| D02 | Save a preset, relaunch, apply it | Branch and values back; the secret-looking input not saved |
| D03 | A preset in `.runnir/launches` | Listed as "in this repository"; broken files listed, not fatal |
| D04 | Earlier runs: fill the form from an entry, Compare two | Values filled, nothing sent until confirmed |
| D05 | Settings › Manual Runs › Touch ID on, run again | Touch ID or the password before sending |
| D06 | The job waiting for an environment approval | ▶ approves it after a confirmation |

## 7. Local Runs

| ID | Scenario | Expected |
| --- | --- | --- |
| L01 Gate | Settings › Tools with OrbStack running, then stopped | act and Docker found; a stopped engine said plainly; nothing installed or started by Runnir |
| L02 Gate | Run `local.yml` locally: review, secrets and variables entered for one run | Live output; the secret masked; job states; success counted under Saved |
| L03 | Save the values, run again | No re-entry; showing a saved secret asks Touch ID or the password |
| L04 | Fill values from a `.env` file | Names matched; dotenvx-encrypted values flagged |
| L05 Gate | Stop a running local run | Stops; containers removed (`docker ps -a` shows none labelled by Runnir) |
| L06 Gate | Quit during a local run | Asks first; after relaunch the run is shown as interrupted, never restarted (L10, W09) |
| L07 | A workflow with an unsupported job (macOS runner) | Listed as unsupported in the plan, not run |
| L08 | Change the limits (CPUs, memory, timeout) | Warnings shown, the run prepared again |

## 8. Menu Bar, Notifications, Search

| ID | Scenario | Expected |
| --- | --- | --- |
| M01 | Menu bar: pull requests and the Runs tab | The failing and running runs of workspaces and starred repositories; a row opens the run |
| M02 | A local run ends, a pull request check fails | System notification; the bell lists it; opening it marks it read in every window |
| M03 | ⌘K: a workflow, a run, a setting | Found and opened at its place |

## 9. Storage And Recovery

| ID | Scenario | Expected |
| --- | --- | --- |
| S01 | Settings › Storage › Clear Cache | Saved runs download again; local run history, presets, favorites and sign-in stay |
| S02 | Quit, damage `state.sqlite` of a workspace (overwrite its first bytes), open | Banner "Saved data of this workspace was recovered.", local runs restored, Show in Finder opens `recovery` |
| S03 | Close the banner; Settings › Storage › Delete Recovery Copies | The banner stays closed in every window; copies gone, database kept |
| S04 | Remove a workspace registration | Its data on this Mac deleted; the repository untouched |

## 10. Settings And Help

| ID | Scenario | Expected |
| --- | --- | --- |
| H01 Gate | Settings › About | Version, license, links, third-party software with texts |
| H02 | Report a Bug | Opens a GitHub issue draft with versions only; nothing sent by itself |
| H03 | Settings › Privacy › Off | Nothing counted from then on |

## 11. The Tagged Alpha

| ID | Scenario | Expected |
| --- | --- | --- |
| T01 Gate | Push `v0.1.0-alpha.1` | Release Build passes; a draft pre-release with `Runnir-v0.1.0-alpha.1.zip`, the Core binaries and `runnir-v0.1.0-alpha.1-THIRD-PARTY-NOTICES.txt` |
| T02 Gate | The downloaded app | `com.runnir.app`, named Runnir, ALPHA pill on the icon and the menu bar capsule, no DEV or LOCAL mark; A01-A04 again |
| T03 Gate | The Core binaries | `runnir version` prints the tag's version; the darwin ones notarized |
| T04 | Analytics, the day after first use | `first_launch` and the daily batch in the Runnir PostHog project; nothing more than the chosen level allows |
| T05 | Settings › About › Check for Updates | "Up to date" with alpha.1 the only release |
| T06 | Publish `v0.1.0-alpha.2`, wait or Check for Updates | Card above the GitHub account: Download, progress, checking the signature, Update; Update quits as usual, the app is replaced and opens again as alpha.2 with its sign-in, workspaces and windows |
| T07 | Runnir Dev and the alpha side by side | Separate data, sign-in and menu bar icons |

## Recording

Note the build, the date and, for each failure, the scenario ID, what happened and a screenshot with no private repository content. A failed Gate scenario blocks the tag; the rest go to the release notes or the backlog.
