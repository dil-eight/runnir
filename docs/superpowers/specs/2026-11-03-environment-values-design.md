# Values Per Environment For Local Runs

Status: design approved and implemented on 2026-11-03; environments an expression picks added on 2026-11-04. It extends [Secrets And Variables For Local Runs (B28)](2026-10-25-local-run-secrets-design.md), which left environment secrets out. Designs: `docs/design/runnir.pen`, row "Secrets and Variables (S16)": "Environments: the Repository's values", "Environments: production's own values, the rest from the Repository" and "Environments: production from GitHub, for a job whose environment an expression picks"; row "Local execution": "A production job: its environment's values, then the Repository's" and "A job whose environment an expression picks: choose whose values the run gets (menu open)".

## Goal

On GitHub a job with `environment: production` gets production's secrets and variables, and the repository's for names production does not set. Locally every job got the one set a workspace kept. Now a workspace keeps the Repository's values and one set per environment its workflows name, and a local run of a job in an environment gets that environment's values first.

## Decisions Made

| Question | Decision |
| --- | --- |
| Which environments | The names in the workflows' `environment:` (a string or `name:`). When some job picks its environment with an expression (`${{ needs.changes.outputs.target }}`), known only when it runs, also the repository's environments on GitHub (`GET /repos/{owner}/{repo}/environments`, Actions: read, which Runnir has), since such a job may run in any of them. Without an expression GitHub is not asked, so an environment no job can use (`github-pages`) stays out. Names that differ only in case are one, spelled as the workflows spell it |
| What a set lists | The Repository: every name a workflow reads, as before. An environment: the names its jobs read, the workflow's own `env` included; a job an expression places reads its names in every environment |
| Inheritance | As on GitHub: a name an environment leaves empty gets the Repository's value. Shown as an empty field "The Repository's value", captioned "From the Repository" |
| Missing | In an environment: neither it nor the Repository has a value. In the Repository: some job reading the name gets nothing, because it has no environment or its environment does not set the name; a job an expression places counts once per environment. A Repository name every environment reading it sets is not missing; its caption says "production and staging set their own" |
| Picker | Segments above the tables, "Repository" then the environments by name (ignoring case), a warning dot on a set in which a job would get an empty value. Not a menu. An environment no run can take any more keeps a dimmed segment while it has saved values, so they can be forgotten. An environment's line says which jobs get its values: "Jobs with environment: production", "jobs whose environment an expression picks, when you run them with production's", or both |
| Import .env | Fills the set shown |
| Keychain | The workspace's service as before. The Repository's accounts stay `secret:NAME`, an environment's are `environment:production:secret:NAME` |
| A run's environment | The Core's plan says it (`LocalRunPlan.environment`). act gives every job of a run the same values, so one environment among the run's jobs is the run's, and a run of a job in production with a job without one notes that both get production's values. For jobs in several environments, or one an expression picks, the user chooses: the plan says why (`environment_choice`) and lists the environments (`environments`, as ListEnvironments). With none known (signed out, no environments on GitHub) the run gets the Repository's values and a plan note says why |
| Run Locally review | The header names the environment. Each saved value says where it comes from: "Saved for production" or "Saved for the Repository". "Save entered values to production" saves to the run's environment. When the user chooses: "Run with [the Repository's values]" beside the SECRETS AND VARIABLES heading opens Runnir's own menu of the Repository and the environments, each with how many of the run's names it leaves empty; the plan's reason and "Choose whose values this run gets" sit under the heading. The Repository's values come first, and the choice is not remembered: a run with production's values can reach production, so Runnir asks every time |

## Core

- `references.FindByJob` lists the names each job reads, adding those outside `jobs:` to every job.
- The scanner's `Job` gains `Environment`, `EnvironmentExpression`, `Secrets` and `Variables`; `ListWorkflows` returns them. `scanner.EnvironmentName` reads `environment:` for both the scanner and the scenario flow.
- `github.Client.Environments` reads the repository's environments (up to 300).
- `localrun.Environments` merges the workflows' environments with GitHub's, asking GitHub only when a job picks its environment with an expression. `ListEnvironments` returns them and always asks GitHub; GitHub out of reach leaves its own out. `PrepareLocalRun` reuses GitHub's answer for five minutes, so a review planned again does not wait on GitHub each time.
- `localrun.NewPlan` sets `Plan.Environment`, or `Plan.EnvironmentChoice`, and the note as above; `PrepareLocalRun` fills `Plan.Environments` for a choice.

## App

- `LocalRunValueKey` gains `environment` (nil: the Repository's) and `in(_:)` for the same name in another set.
- `WorkspaceValuesModel` keeps the workflows, the Core's environments (`update(environments:)`, after the rows, as the Core may ask GitHub, and again after a GitHub sign-in; until the Core answers the jobs' own names stand in) and the saved names it loaded, and builds the rows of the set shown (`select(_:)`), the environments, the stale ones and the sets with missing values.
- `LocalRunReviewModel` reads each plan name from the run environment's set, else the Repository's, and saves entered values to the environment's set. `choose(_:)` takes another environment's values when the plan leaves it to the user; `emptyCount(with:)` counts what each choice leaves empty.

## Not In This Change

Organization secrets; GitHub's environment protection rules and deployment branches (a local run is not a deployment); working out what an expression picks, even `${{ inputs.target }}` with the inputs of the run; remembering the choice between reviews; suggesting `.env.production` for production in the Import .env menu.

## Tests

- Core: per-job names with the workflow's own `env`; the scanner's environment, expression flag and names per job; the plan's environment for one job, a job with a need outside the environment, and the choice for several environments, one expression and two; GitHub's environments read page by page; the merged list asking GitHub only for an expression, one name per case; `ListWorkflows`, `ListEnvironments` and `PrepareLocalRun` carry them, signed out and in.
- App: Keychain accounts with an environment, including one whose name holds a colon; the S16 sets, inheritance, missing, stale environments, and edits and imports saved to the set shown; a job an expression places reading its names in each environment from the Core; the review taking the environment's value first and saving entered values there; a review choosing production's values, with the empty count of each choice.
