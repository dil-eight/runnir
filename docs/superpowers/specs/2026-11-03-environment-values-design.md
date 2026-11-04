# Values Per Environment For Local Runs

Status: design approved and implemented on 2026-11-03. It extends [Secrets And Variables For Local Runs (B28)](2026-10-25-local-run-secrets-design.md), which left environment secrets out. Designs: `docs/design/runnir.pen`, row "Secrets and Variables (S16)": "Environments: the Repository's values" and "Environments: production's own values, the rest from the Repository"; row "Local execution": "A production job: its environment's values, then the Repository's".

## Goal

On GitHub a job with `environment: production` gets production's secrets and variables, and the repository's for names production does not set. Locally every job got the one set a workspace kept. Now a workspace keeps the Repository's values and one set per environment its workflows name, and a local run of a job in an environment gets that environment's values first.

## Decisions Made

| Question | Decision |
| --- | --- |
| Which environments | The names in the workflows' `environment:` (a string or `name:`). An environment an expression picks (`${{ inputs.target }}`) is not listed: it is known only when the job runs |
| What a set lists | The Repository: every name a workflow reads, as before. An environment: the names its jobs read, the workflow's own `env` included |
| Inheritance | As on GitHub: a name an environment leaves empty gets the Repository's value. Shown as an empty field "The Repository's value", captioned "From the Repository" |
| Missing | In an environment: neither it nor the Repository has a value. In the Repository: some job reading the name gets nothing, because it has no environment or its environment does not set the name. A Repository name every environment reading it sets is not missing; its caption says "production and staging set their own" |
| Picker | Segments above the tables, "Repository" then the environments by name, a warning dot on a set in which a job would get an empty value. Not a menu. An environment no workflow names any more keeps a dimmed segment while it has saved values, so they can be forgotten |
| Import .env | Fills the set shown |
| Keychain | The workspace's service as before. The Repository's accounts stay `secret:NAME`, an environment's are `environment:production:secret:NAME` |
| A run's environment | The Core's plan says it (`LocalRunPlan.environment`). act gives every job of a run the same values, so: one environment among the run's jobs is the run's; jobs in several environments, or one an expression picks, get the Repository's, and a plan note says why. A run of a job in production with a job without one notes that both get production's values |
| Run Locally review | The header names the environment. Each saved value says where it comes from: "Saved for production" or "Saved for the Repository". "Save entered values to production" saves to the job's environment |

## Core

- `references.FindByJob` lists the names each job reads, adding those outside `jobs:` to every job.
- The scanner's `Job` gains `Environment`, `EnvironmentExpression`, `Secrets` and `Variables`; `ListWorkflows` returns them. `scanner.EnvironmentName` reads `environment:` for both the scanner and the scenario flow.
- `localrun.NewPlan` sets `Plan.Environment` and the note as above.

## App

- `LocalRunValueKey` gains `environment` (nil: the Repository's) and `in(_:)` for the same name in another set.
- `WorkspaceValuesModel` keeps the workflows and saved names it loaded and builds the rows of the set shown (`select(_:)`), the environments, the stale ones and the sets with missing values.
- `LocalRunReviewModel` reads each plan name from the environment's set, else the Repository's, and saves entered values to the environment's set.

## Not In This Change

Organization secrets; GitHub's environment protection rules and deployment branches (a local run is not a deployment); listing environments from the GitHub API; suggesting `.env.production` for production in the Import .env menu.

## Tests

- Core: per-job names with the workflow's own `env`; the scanner's environment, expression flag and names per job; the plan's environment for one job, a job with a need outside the environment, several environments and an expression; `ListWorkflows` and `PrepareLocalRun` carry them.
- App: Keychain accounts with an environment, including one whose name holds a colon; the S16 sets, inheritance, missing, stale environments, and edits and imports saved to the set shown; the review taking the environment's value first and saving entered values there.
