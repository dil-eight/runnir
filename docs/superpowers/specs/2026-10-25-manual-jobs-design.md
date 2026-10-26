# Manual Jobs In The Overview Pipeline

Status: design agreed on 2026-10-25 in conversation. Backlog: B08 (Overview pipeline); designs: `runnir.pen` "S03 / Repository overview / Pipeline with manual jobs" and component "C26 / Pipeline job · manual".

## Goal

A job meant to be started by hand, such as "Deploy to production", shows a ▶ on its card in the Overview pipeline. Pressing it, after a confirmation, starts that job. Other jobs get no ▶.

## Which jobs are manual

GitHub has two ways to make a job wait for a person, and Runnir supports both:

| Kind | How the workflow says it | What ▶ does |
| --- | --- | --- |
| Waiting for approval | The job has an `environment` with required reviewers; the run stops at the job with status `waiting` | Approves the run's pending deployments the signed-in user may approve (`POST /actions/runs/{id}/pending_deployments`, `state: approved`). The same run goes on |
| Started by hand | The job's `if` requires `github.event_name == 'workflow_dispatch'` as one of its top-level `&&` terms, and the workflow has a `workflow_dispatch` trigger | Starts the workflow by hand on the shown run's branch, with the inputs the same `if` compares by `==` (`github.event.inputs.X` or `inputs.X` against a string or boolean). Other inputs keep their defaults. A new run starts |

Required reviewers on environments need a public repository or GitHub Enterprise; on Free, Pro and Team they are not available for private repositories. The second kind works on every plan.

Runnir does not guess which input means "this commit" (for example an `image_tag`): only inputs the condition fixes are set.

## Behavior

- **Started by hand:** ▶ asks "Run *workflow* on *branch*?" naming the inputs, then the optional Touch ID confirmation of Settings › Runs, then prepares and sends the dispatch once through the Core, as Run Workflow does. On success the card says "Started"; the new run appears with the next refresh. Refusals and access problems are shown under the pipeline.
- **Waiting for approval:** the Core lists the run's pending deployments when the action is prepared. ▶ shows only when the latest run is `waiting` and the job is `waiting`; the confirmation names the environments; nothing the user may not approve is sent. The Runnir Desktop GitHub App needs the repository permission "Deployments: Read and write".
- The hover hint of a manual job says how it starts: "Runs only when started by hand with environment=production" or "Waiting for approval to deploy to production".
- A job whose run is still going, or whose workflow GitHub does not know yet, shows no ▶. A job started by hand shows ▶ only when the shown run is on the repository's default branch, so a ▶ never starts a deployment from a pull request's branch.

## Core

- The repository scan marks a job manual (`Job.manual`, `Job.manual_inputs`) from its `if`, parsed with actionlint's expression parser. Input names follow the declared `workflow_dispatch` inputs' spelling.
- `RunAction.RUN_ACTION_APPROVE_DEPLOYMENTS`: Prepare checks the run is `waiting` and reads its pending deployments; it is refused when there are none the user may approve. `PrepareRunActionResponse.environments` names them. Confirm approves those environment ids once.

## Tests

Scanner: manual detection (order of terms, `inputs.X` and `github.event.inputs.X`, booleans, `||` not counted, no `workflow_dispatch` trigger). GitHub client against a test server: pending deployments read and approval body. Server: approve action prepared and confirmed against a fake GitHub. App: the card's ▶ for both kinds, the dispatch sent with the condition's inputs on the run's branch, the confirmation declined.
