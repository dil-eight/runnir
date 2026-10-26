# Secrets And Variables For Local Runs (B28)

Status: design approved and implemented on 2026-10-25 ([plan](../plans/2026-10-25-local-run-secrets.md)). Changes made while implementing: the Run Locally review reads each saved value once when it prepares, so a value Keychain refuses shows as missing before the run; lines of a multi-line secret are masked only when at least 4 characters long (the whole value always is); a variable keeps its saved value on screen, a secret only after Touch ID until the window loses focus. Backlog: B28 / F5 in the [MVP checklist](../../product/mvp-implementation-checklist.md); it extends B15 (plan and review) and B16 (act runner). Context: [ADR 0006](../../decisions/0006-bundled-act-for-local-runs.md), [workspace persistence](../../architecture/workspace-persistence.md), [gRPC API](../../architecture/grpc-api.md), [GitHub authentication](../../security/github-authentication.md). Designs: `docs/design/runnir.pen`, S16 redrawn as "Secrets and Variables" and S10 with its new section.

## Goal

A workflow run locally gets the `secrets.X` and `vars.X` it reads. Today it gets none: the plan lists the secret names and says they are empty, and act is given an empty `--secret-file` and `--var-file`. The user keeps values for a workspace in Keychain, imports them from a `.env` file they choose, or types one for a single run. Values reach act through pipes, never through a file, the command line, act's environment, the workspace database or a log.

## Decisions Made

| Question | Decision |
| --- | --- |
| Scope | `secrets.X` and `vars.X`. GitHub Actions secrets stay on GitHub; nothing is uploaded or downloaded |
| Where values are kept | macOS Keychain, per workspace, for secrets and variables alike. No Runnir file format, nothing in `.runnir` |
| Touch ID | Only to show a saved secret's value (`.deviceOwnerAuthentication`, so the password works without biometrics). Running with saved values asks nothing beyond the existing trust checkbox. Variables are shown without it |
| Where values are managed | A new workspace sidebar section, **Secrets and Variables**, between Runs and Workspace. The Run Locally review shows the run's names too, for values used once |
| Layout | Two columns: the name as text, the value as an input. Names are never typed: they come from the workflows |
| Names | Those the workspace's workflows read, upper-cased (GitHub and act compare them without case). Saved values whose name no workflow reads any more are listed separately, to forget them |
| Missing values | Highlighted, never a blocker: as on GitHub, an unset value is an empty string |
| `.env` import | A file the user picks. Values fill the matching names as unsaved edits; names in the file that no workflow reads are skipped and counted; dotenvx-encrypted values (`encrypted:…`) are flagged and not imported. Runnir does not decrypt dotenvx files |
| `GITHUB_TOKEN` | An ordinary secret: the user may enter a token. Runnir never fills it from its own sign-in, and always passes the name (empty when unset) so act does not run `gh auth token` |
| How values reach act | Pipes. `--secret-file` and `--var-file` name `secrets.yaml` and `vars.yaml` in the run's scratch folder, symbolic links to `/dev/fd/3` and `/dev/fd/4`, which are pipes the Core hands act; the Core writes JSON (valid YAML) into them after act starts. This replaces the earlier plan of `-s NAME` through act's environment: a name there becomes an environment variable of act itself (`PATH`, `DOCKER_HOST`, `HTTPS_PROXY`, `GODEBUG`), act prompts on stdin for an empty one, and the values are visible in the process environment for the whole run |
| Windows | The Core refuses a run with values there (Go cannot hand a child extra descriptors); the app is macOS-only |

## What act Does With The Files

Checked against act v0.2.89 (`cmd/root.go`, `cmd/secrets.go`):

- `readEnvsEx` stats the path, then parses it as YAML when its extension is `.yml` or `.yaml` (`readYamlFile`: one `os.ReadFile`, `yaml.Unmarshal` into `map[string]string`), otherwise as a dotenv file. The YAML path keeps newlines, quotes and `$` in values exactly; JSON written by `encoding/json` is valid YAML.
- Secret names are upper-cased (`readEnvsEx(..., true)`); variable names are not, but act's expression evaluator compares map keys with `strings.EqualFold`, so `vars.foo` finds `FOO`.
- With no `GITHUB_TOKEN` among the secrets, act runs `gh auth token`. Today only the reduced `PATH` stops that; passing `GITHUB_TOKEN` always closes it.
- act masks secret values in its output (`valueMasker`), including `--json` output. Variables are not masked, as on GitHub.
- YAML secret, env and input files arrived in April 2023 (nektos/act#1733), before 0.2.60, the oldest installed act Runnir accepts; `--var-file` uses the same reader. No extra version check is needed for the experimental installed act.

## Interface

### Secrets and Variables (S16, sidebar section)

- Two tables, **Secrets** and **Variables**. Each row: the name in monospace text with a caption below naming the workflows that read it (`ci.yml, deploy.yml`), and a value input on the right.
- A secret's value is a secure field. A saved value shows as dots with an eye button; showing it asks for Touch ID or the password first, and it hides again when the window loses focus or the section changes. A variable's value is a plain field.
- A name with no saved value shows an empty, highlighted field and "Missing".
- A row with a saved value has a remove button (Forget).
- A third group, **Saved, not used by any workflow**, lists saved names no workflow reads, with Forget only.
- Edits are pending until **Save**; **Revert** drops them. Only Save writes to Keychain. Pending edits survive switching sections; closing the window or switching it to another workspace with pending edits asks Save / Don't Save / Cancel, as the workflow editor does.
- **Import .env…** opens a file panel. The values of matching names become pending edits, in both tables when a name is read as a secret and as a variable. A summary line says what happened: "Filled 4 values. 2 names are not used by any workflow. 1 value is encrypted by dotenvx and was not imported. Line 7 could not be read." Missing names stay highlighted.
- A note below the tables: "Values stay on this Mac in Keychain and are used only for local runs. GitHub Actions secrets stay on GitHub."
- Empty state (no workflow reads a secret or variable): "No workflow in this workspace reads secrets or variables."

### Run Locally review (S10)

- A **SECRETS AND VARIABLES** section with the same two columns for the names this run reads. Names are text. A saved value shows as dots; a missing one is an empty, highlighted field. Typing a value uses it for this run, also over a saved one.
- A checkbox **Save entered values to this workspace** (off by default) and a link **Manage in Secrets and Variables**.
- The access row "Secrets" says what the run gets, for example "3 passed, 1 empty. Workflow steps can read these values and send them over the network." With none read: "None read by this workflow. GitHub token and host environment are not passed."
- A plan note when the workflow reads secrets it does not name (`toJSON(secrets)`, `secrets: inherit`): "This workflow reads secrets it does not name; only the listed ones are passed."
- Run Locally stays enabled with missing values.

## App: Storage And Flow

- `LocalRunValueStore`, an actor behind a protocol so tests use a fake. Keychain generic-password items: service `dev.runnir.local-run.<workspace-uuid>` (with `.ui-testing` inserted for UI tests of a Debug build, as `KeychainCredentialStore` does), account `secret:NAME` or `variable:NAME`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable. Operations: `names(workspace)` (attributes only, no values), `value(workspace, kind, name)`, `save`, `remove`, `removeAll(workspace)`.
- Showing a saved secret evaluates `LAContext` `.deviceOwnerAuthentication` with the reason "show the saved value of NAME", then reads it. Reading for a run asks nothing: the value is not displayed.
- Starting a run: for each name in the plan, the value typed in the review, else the saved one, else nothing. Only plan names are sent. When **Save entered values** is on, the typed values are saved before the run starts.
- Values never go to `UserDefaults`, `desktop-state.json`, the app's logs or bug reports. The review's fields are cleared when the sheet closes.
- Removing a workspace registration calls `removeAll` where its database is deleted today (`DesktopCoordinator`). Clear Cache leaves values alone: they are not cache.
- The section's names come from `ListWorkflows`: each workflow's `secrets` and `variables`, merged by name with the workflows that read it.

## Core

### Name references

- One function, used by the repository scan and by the plan, finds `secrets.NAME`, `secrets['NAME']`, `secrets["NAME"]` and the same for `vars` in a workflow's source. Names are upper-cased, de-duplicated and sorted. Expressions are not evaluated.
- It also reports whether the workflow reads secrets it does not name: `toJSON(secrets)`, `secrets: inherit`, or `secrets` used as a whole.

### Contract

- `Workflow` gains `repeated string secrets` and `repeated string variables`.
- `LocalRunPlan.secrets` keeps the names the run reads (comment updated: values are passed when the user sets them); `LocalRunPlan` gains `repeated string variables` and `bool unnamed_secrets`.
- `ConfirmLocalRunRequest` gains `map<string, string> secrets` and `map<string, string> variables`. The Core accepts at most 100 names of each kind, each name in the approved plan (compared upper-cased), each value at most 48 KiB (GitHub's limit). Otherwise it answers `INVALID_ARGUMENT`; the confirmation is used up, and the app reviews again as it does for an expired one. On Windows a request with values is `FAILED_PRECONDITION`.
- New `ReadEnvFile(path)` returns `repeated EnvEntry {name, value, encrypted, line}` and `repeated EnvProblem {line, message}`. A file larger than 1 MiB, not a regular file, or not valid UTF-8 is `INVALID_ARGUMENT` with a message for the user.
- Values travel in the confirmed `localrun.Spec` (`Secrets`, `Variables`), never in `Plan`, which `GetLocalRunOutput` returns. They are not logged and not recorded in the workspace database.

### dotenv parser

`core/internal/dotenv`, pure Go, no dependency:

- `KEY=VALUE` and `export KEY=VALUE`; keys `[A-Za-z_][A-Za-z0-9_]*`, upper-cased on import. Blank lines and lines starting with `#` are skipped.
- Unquoted values are trimmed and end at ` #`. Single-quoted values are literal and may span lines. Double-quoted values may span lines and understand `\n`, `\r`, `\t`, `\"` and `\\`.
- `${X}` and `$X` are kept as written: implementations differ, and expanding from Runnir's environment would be wrong.
- A value starting with `encrypted:` is returned with `encrypted` set and an empty value.
- A line that cannot be read becomes a problem with its line number; parsing continues. A later duplicate key wins, as in dotenv.

### Runner

- `prepareScratch` keeps the `empty` file for `--env-file` and `--input-file`.
- `Run` creates two `os.Pipe`s, passes their read ends through `cmd.ExtraFiles` (fd 3 and 4), and creates `scratch/secrets.yaml → /dev/fd/3` and `scratch/vars.yaml → /dev/fd/4`. `Args` gives `--secret-file=<scratch>/secrets.yaml` and `--var-file=<scratch>/vars.yaml`.
- After `cmd.Start` the parent closes the read ends; a goroutine per pipe writes one JSON object and closes its write end. The secrets object always has `GITHUB_TOKEN`. A write error (act exited before reading) is ignored: act's own failure is what the user sees. Both write ends are closed after `cmd.Wait` at the latest.
- Every run uses the pipes, with or without values, so there is one path.

### Masking

The Core masks secret values in the run's output lines before keeping them (`output.go`), as a second line behind act: each non-empty value and each non-empty line of a multi-line value becomes `***`, longest first. Secret values stay in Core memory for the run's lifetime for this and are dropped when it finishes. Variables are not masked.

## Error Handling

| Case | Behavior |
| --- | --- |
| Keychain refuses a read for a run | That name counts as missing, highlighted with "Keychain refused access"; the run is not blocked |
| Touch ID or password declined | The value stays hidden |
| Save fails | An error above the tables; edits stay pending |
| `.env` file unreadable, too large, not UTF-8 | The Core's message; nothing changes |
| A line of the file cannot be read | Listed in the summary by line number; other lines import |
| Names sent that the plan does not have, or limits exceeded | `INVALID_ARGUMENT`; the review prepares a new plan |
| Workflow file changed after the review | The existing digest check refuses the confirmation; the new plan lists the new names |
| act exits before reading a pipe | Write error ignored; the run fails with act's own message |

## Testing

- Core, deterministic: name references (all forms, case, duplicates, `toJSON(secrets)`, `secrets: inherit`, names in comments still count); dotenv fixtures (quotes, multi-line, `export`, comments, `encrypted:`, bad lines, duplicates, size and UTF-8 limits); `ConfirmLocalRun` limits and unknown names; `Args` holds no value and names the two links; a runner test with a fake act that copies the two files into its output, showing the values arrive and are absent from argv and the environment; masking in output; refusal on Windows (build-tagged test).
- Core, end to end (`e2e` tag, OrbStack): a workflow prints the SHA-256 of a secret and of a variable; the test checks both hashes and that the secret's value never appears in the output.
- App unit tests: the store against a fake Keychain; values for a run (typed over saved, plan names only, missing names); the section's model (names merged across workflows, the not-used group, import as pending edits with skipped and encrypted counts, Save and Revert, unsaved-changes prompt); removing a workspace removes its values.

## Docs And Design

- `runnir.pen`: S16 redrawn as Secrets and Variables (filled, missing, revealed secret, import summary, empty) in a new row for its sidebar section between Runs (D) and Workspace (E); S10 with the new section and access line. Index card states updated.
- `screens-and-states.md`: S16 row rewritten; S10 states updated; S17 marked as not needed (no portable environments).
- `workspace-persistence.md`: the Secrets paragraph describes pipes instead of `-s NAME`.
- `grpc-api.md`: `ReadEnvFile`, the new fields.
- `mvp-implementation-checklist.md`: B28 row in Progress.

## Not In This Slice

dotenvx decryption or `dotenvx run`; uploading secrets to GitHub; environment and organization secrets; `env:` values from a `.env` file; Touch ID before a run; a Runnir file format for environments.
