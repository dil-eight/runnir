# GitHub Actions Pain Points: Field Research

Period covered: 2026-04-25 to 2026-10-25. Written 2026-10-25 from an external research summary of public discussions (Reddit, GitHub Issues and Discussions, other developer forums). Focus: awkward pipelines, deployment, and managing workflow runs and jobs.

This is a sample of publicly visible discussions, not a systematic or representative study. "Signal" below is a qualitative judgement of how often a complaint recurred, never a measured frequency. The links were carried over from the summary. On 2026-10-25 the GitHub links were opened and dated (see Sources). Reddit cannot be fetched with the tools used here, so the Reddit links and their dates are unverified. Check each source before quoting it in anything public.

## Findings

| # | Pain | Signal | In Runnir today | Gap and decision |
| --- | --- | --- | --- | --- |
| 1 | Manual runs: `workflow_dispatch` forms are clumsy with many inputs, and inputs behave unpredictably when the branch changes | Repeated | Typed inputs read from the workflow file at the chosen ref (`DescribeWorkflowDispatch`), validation, branch/tag selection, device-private presets, presets from `.runnir/launches` (B09, B10, B25) | None. Covered |
| 2 | Inputs of earlier runs are hard to recover | Several platforms | Presets keep values the user chose to save; nothing records what each dispatch sent | Dispatch history for runs started in Runnir: **B34**, built. Inputs of runs started elsewhere are not available from GitHub and are shown as unknown |
| 3 | Re-running one failed job takes too many steps | Several confirmations | Cancel, re-run all, re-run failed jobs with confirmation (B13); job logs (B12) | Re-run of a single job was missing (the contract had `CANCEL`, `RERUN`, `RERUN_FAILED` only): added to **B13** and built, a button on each finished job of a finished run |
| 4 | Finding a run by `run-name`, version, environment, region or component among many workflows | Single feature request | Runs browser filters by repository, workflow, status and ref; By change grouping (S07, B30) | Text search over title, SHA, branch, actor and event: **B33**, built. Environment is not a run property and belongs to **B37** |
| 5 | Debugging workflows through endless commit and push | Repeated | actionlint diagnostics, editor, local runs with act, scenario pipeline designed (B03, B04, B14–B16, B32) | None new. B32 is approved as a design and not implemented |
| 6 | Opaque `needs`, `if`, reusable workflows; why a job was skipped | Several, small competing tools exist | Pipeline per workflow (B08); B32 plans a scenario and explains why a workflow or job will not run | Explaining a skipped job in a run that already happened: **B35**, using B32's `if:` evaluator |
| 7 | Rebuilding the same commit when going from test to deploy; no safe artifact promotion | Single engineering case, a known anti-pattern | Run links and concurrency suggestions (B30); roadmap v0.4 | Not a v0.1 or v0.2 feature. Duplicate-build detection for one SHA joins the v0.2 CI-usage insights as the read-only first step; promotion stays in v0.4 |
| 8 | One-off scheduled deployments | Single feature request | Nothing | **Not taken.** Running while the Mac is off needs an always-on executor, which contradicts "no mandatory backend" |
| 9 | Runs stuck in `queued`, jobs never created, force-cancel not working | Several, some are the same platform incident | States shown in the inspector (B11); cancel and re-run (B13) | Diagnosis of long-queued runs: **B36**. Runnir cannot fix a stuck GitHub scheduler and will not claim to |
| 10 | Token permissions, reusable workflow requirements, and what is deployed where | Mixed, several different problems | Nothing | Deployments per environment: **B37**. Permissions preflight: **B38** |
| — | A single place to watch failed and active runs across repositories | Part of the "control center" framing | Per-workspace Overview; the menu bar shows pull requests with their CI state across accounts | Cross-repository activity: **B39** |

## Sources

As listed in the research summary, by finding. GitHub threads were opened on 2026-10-25 and carry their creation date; Reddit threads are unverified (marked "Reddit, not fetched").

1. GitHub [Discussion 210506](https://github.com/orgs/community/discussions/210506), created 2026-10-17: the Run workflow form keeps old input values after the branch changes. Reddit, not fetched: [GitHub Actions issues](https://www.reddit.com/r/devops/comments/1wfw0o1/what_github_actions_issues_do_you_run_into/).
2. GitHub [Discussion 49648](https://github.com/orgs/community/discussions/49648) was created on 2023-03-09, **outside the period**, and is not counted; it shows the request is old and still open. The Reddit thread of finding 1.
3. GitHub [Discussion 211030](https://github.com/orgs/community/discussions/211030), 2026-10-22, and [Discussion 195854](https://github.com/orgs/community/discussions/195854), 2026-05-14 (log autoscroll hides the Rerun buttons).
4. GitHub [Discussion 202191](https://github.com/orgs/community/discussions/202191), 2026-07-17.
5. The Reddit thread of finding 1; Reddit, not fetched: [Team A or B](https://www.reddit.com/r/devops/comments/1vg0i1u/are_you_team_a_or_team_b/).
6. Reddit, not fetched: [why didn't my job run?](https://www.reddit.com/r/coolgithubprojects/comments/1wegi6x/why_didnt_my_job_run_paste_a_github_actions/).
7. Reddit, not fetched: [CI pipeline was wrong](https://www.reddit.com/r/devops/comments/1uaafd5/reddit_taught_me_why_my_ci_pipeline_was_wrong/). One case reported a pipeline falling from about 10 minutes to 3:50 after removing repeated builds; a single example, not a benchmark.
8. GitHub [Discussion 204703](https://github.com/orgs/community/discussions/204703), 2026-08-12.
9. GitHub [Discussion 205874](https://github.com/orgs/community/discussions/205874), 2026-08-26, and [Discussion 210234](https://github.com/orgs/community/discussions/210234), 2026-10-14. Newer queued-run reports from 2026-10-20 and 2026-10-23 look like the same incident and are counted once in the tracker.
10. Reddit, not fetched: [GitHub frustration](https://www.reddit.com/r/devops/comments/1to04xf/anyone_else_frustrated_with_github_lately/). Discussion 49648 (2023) does not count.

Context found while checking: GitHub raised the `workflow_dispatch` limit from 10 to 25 inputs on 2025-12-04 ([changelog](https://github.blog/changelog/2025-12-04-actions-workflow-dispatch-workflows-now-support-25-inputs/)). Complaints about large input forms are therefore partly answered upstream. Re-running a single failed job from the run page has existed since 2022; the complaint of finding 3 is about the pull request checks view.

## What The Research Confirms

The summary's P0 items are the multi-repository control center and smart workflow forms. The forms, run tracking, logs, cancel and re-run are implemented (B09–B13). The direction is right. The new ground is diagnosis, search and history, plus the cross-repository view.

## Changes To The Backlog

Existing items:

- **B13** gains re-run of one job from its row in the inspector.
- **S06, S07, S08** in the [screen matrix](../design/screens-and-states.md) note the planned additions.
- The [roadmap](../product/roadmap.md) v0.2 and v0.4 entries are rewritten.
- The [specification](../product/specification.md) success criteria get a measuring protocol.

New candidates, none a v0.1 gate (see the [checklist](../product/mvp-implementation-checklist.md#field-research-candidates-not-v01-gates)):

| ID | Outcome |
| --- | --- |
| B33 | Search runs by title, SHA, branch, actor and event over the saved runs |
| B34 | History of non-secret inputs of dispatches sent from Runnir, with Run again |
| B35 | Why a job was skipped in a finished run |
| B36 | Why a run stays queued |
| B37 | What is deployed in each environment |
| B38 | Permissions preflight from the workflow files |
| B39 | Failed and active runs across favorite repositories and workspaces |

## What Runnir Will Not Promise

- Fixing GitHub's internal outages, stuck queues or scheduling failures. B36 diagnoses and offers the existing confirmed cancel and re-run.
- A local sandbox identical to a GitHub-hosted runner. B14–B16 already report what cannot run locally.
- Reusing an artifact between arbitrary workflows. Promotion needs an explicit deploy-only workflow, provenance and permissions.
- The inputs or secrets of runs that were not started from Runnir.
- A money figure for saved CI minutes. Only time is shown, unless the runner type, plan and billed minutes are known.

## Measuring Usability Without Telemetry

Runnir collects no usage data by default, so the summary's MVP metrics are measured by hand in short moderated sessions on a controlled fixture repository, comparing Runnir with the GitHub web UI on the same task:

- Time to start a workflow with inputs, from choosing the repository to a located run.
- Time from opening the app to the log of a failed job.
- Time from seeing a failure to a re-run request being accepted.
- Navigation steps for each of the three.
- Whether the tester chooses Runnir again for the next run.

Results go into the verification notes of the feature they concern. They are small-sample observations, not benchmarks. "Saved minutes" is reported only where an avoided build is established.

## Pain Tracker

[pain-tracker.md](pain-tracker.md) is the running log: sixteen pains Runnir addresses (the ten above plus log reading, local-run secrets, duplicate runs, cross-repository monitoring, YAML validation and slow web pages), a counter for each over the last six months, and a link to every thread. It is generated by [scripts/pain-tracker.sh](../../scripts/pain-tracker.sh) from [pains.tsv](pains.tsv) (definitions and search queries), [pain-sources.tsv](pain-sources.tsv) (threads) and [pain-rejected.txt](pain-rejected.txt) (threads that do not fit).

Daily procedure:

1. `scripts/pain-tracker.sh collect` searches GitHub Community discussions, issues of `nektos/act` and `actions/runner`, and Hacker News stories posted inside the window, and prints the ones not yet recorded or rejected. Dates, links and comment counts come from the APIs, never from memory.
2. Each candidate is opened and judged against the pains: does the author describe the problem, in the window, as a person with the problem rather than an announcement or an outage notice? Fit goes in with `add` (one paraphrased line, no username, no quote); everything else goes in with `reject` so it is not read again tomorrow. Posts about the same outage, or the same report twice, count once.
3. `scripts/pain-tracker.sh render` rebuilds [pain-tracker.md](pain-tracker.md). The counters are computed from the data, not typed.
4. Threads from other places (Reddit, Stack Overflow, blogs, other forums) are added with `add` after someone has opened the thread and read its date. The search tools used here cannot reach Reddit or Stack Overflow.

The tracker is evidence of demand, not an outreach list. Replies are written by a person, say that they work on Runnir, follow the community's self-promotion rules, and only claim what is built. Runnir has no release yet.

## Continuing The Research

For each new signal record: the date and the direct source; what the author tried to do; the existing workaround; whether independent reports exist (several messages about one outage count once); whether the answer is a GitHub API call, a change to YAML, local execution or outside infrastructure; and the verdict (`P0`, `P1`, `P2` or not taken). Separate feature requests from platform defects, and check whether GitHub has since fixed the problem natively.
