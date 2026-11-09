# GitHub Actions pain points and Runnir opportunities

Accumulated publication window: **2026-04-26 through 2026-11-09**, inclusive through the latest review. Baseline verified on 2026-10-26; latest findings added on 2026-11-09 for the overlapping 2026-10-26 through 2026-11-09 review window. Older source-specific verification dates are retained.

## Executive summary

The [evidence database](pain-points.csv) contains **42 evidence rows from 34 threads, 41 distinct source/comment permalinks, and 20 pain points**. There are 41 distinguishable public author accounts within platforms. Different accounts across platforms do not prove different people or organizations. One HN comment describes two problems, so evidence rows are not a user count. One transferable CI/CD example does not identify its provider and is labeled `firsthand_cross_ci`.

The strongest recurring product signal is the need to validate workflows before pushing and explain the limits of local execution. Six authors describe a difficult feedback loop or local-runner incompatibility. The latest reports also support inspecting individual matrix legs and distinguishing missing schedule opportunities from queued runs. Three authors describe separate manual-dispatch frustrations. Queue diagnosis is useful, but Runnir cannot repair GitHub's internal scheduler.

The [earlier report](../github-actions-pain-points.md), [tracker](../pain-tracker.md), `pains.tsv`, and `pain-sources.tsv` remain intact. Fourteen existing GitHub Discussions were reverified. Three legacy HN mappings now use exact comment permalinks and comment publication dates. The CSV is the primary evidence database for these reports; legacy counters are not added to its totals.

## Distribution

| Category | Evidence rows | Distinct pains |
|---|---:|---:|
| A - Pipelines and workflows | 16 | 7 |
| B - Deployments and manual launch | 7 | 5 |
| C - Runs and jobs | 19 | 8 |
| Total | 42 | 20 |

Each pain has one category. Manual launch belongs to B even when the workflow is not a deployment. Totals include historical bugs, feature requests, and weak opinions; they are not counts of active confirmed defects. Evidence strength describes the specificity of the source, not proof of the alleged cause. Reports were not reproduced on the authors' infrastructure. A read-only check of one public matrix run corroborated the reported cancelled zero-step leg and successful gate; it did not reproduce GitHub's aggregation behavior.

## Prioritized findings

The table links every included evidence row. Author counts identify different accounts within their platforms, not proven independent people across platforms. P09 reports are grouped conservatively because several may describe the same outage.

| ID | Category | Pain Point | Evidence | Impact | Runnir Opportunity | Priority |
|---|---|---|---|---|---|---|
| P05 | A | Push/test loops and local-runner incompatibilities | 6 author account(s): [E0017](https://github.com/nektos/act/issues/6095), [E0018](https://github.com/nektos/act/issues/6124), [E0019](https://github.com/nektos/act/issues/6114), [E0025](https://www.reddit.com/r/devops/comments/1wfw0o1/comment/p9qt228/), [E0027](https://news.ycombinator.com/item?id=50185520), [E0039](https://github.com/nektos/act/issues/6236) | Feedback is slow; valid cloud YAML may fail locally. | Check bundled act compatibility and distinguish linting, simulation, and execution. | P1 |
| P01 | B | Manual dispatch retains stale inputs or adds interaction friction | 3 author account(s): [E0001](https://github.com/orgs/community/discussions/210506), [E0009](https://github.com/orgs/community/discussions/210253), [E0010](https://github.com/orgs/community/discussions/210277) | Incorrect parameters or additional manual actions. | Reload schema at the selected ref, show explicit submission state, and keep the launch action visible. | P1 |
| P03 | C | Rerunning failed jobs takes too much navigation | 2 author account(s): [E0002](https://github.com/orgs/community/discussions/211030), [E0003](https://github.com/orgs/community/discussions/195854) | CI recovery requires additional interaction. | Keep job controls visible and explain which dependent jobs will rerun. | P1 |
| P09 | C | Queued and zero-job states are hard to diagnose or cancel | 7 author account(s); incident independence remains unknown: [E0006](https://github.com/orgs/community/discussions/205874), [E0007](https://github.com/orgs/community/discussions/210234), [E0008](https://github.com/orgs/community/discussions/210840), [E0011](https://github.com/orgs/community/discussions/210841), [E0036](https://github.com/orgs/community/discussions/211664), [E0037](https://github.com/community/community/discussions/210234#discussioncomment-19249538), [E0040](https://www.reddit.com/r/github/comments/1xhpv6l/best_dropin_replacement_runners_github_actions_pr/) | Waiting leads to unproductive configuration debugging. | Show a timeline, jobs, pending deployments, upstream status, and diagnostic evidence. | P1 |
| P06 | A | Workflow organization and zero-job failures are hard to explain | 2 author account(s): [E0014](https://github.com/orgs/community/discussions/210766), [E0028](https://news.ycombinator.com/item?id=50168622) | The operator cannot tell what ran or why. | Show the event/ref scenario and linked workflows without inventing runtime values. | P1 |
| P22 | A | A dependency aggregate can conceal a cancelled matrix leg | 1 author account: [E0034](https://github.com/orgs/community/discussions/211624) | A successful gate can mislead while a matrix leg never ran. | Inspect every expected leg in the same attempt and expose conflicting conclusions. | P1 |
| P02 | B | Previous manual-run inputs are not visible | 1 author account(s): [E0023](https://www.reddit.com/r/devops/comments/1wfw0o1/comment/p9pk8j8/) | Repeating and explaining a run is harder. | Retain non-secret inputs submitted through Runnir; label external inputs unknown. | P1 |
| P04 | C | Run history cannot be searched by run-name | 1 author account(s): [E0004](https://github.com/orgs/community/discussions/202191) | Deployment history requires manual paging. | Search display_title within the locally loaded history and disclose coverage. | P1 |
| P11 | C | Inline job logs appear late | 1 author account(s): [E0013](https://github.com/orgs/community/discussions/210225) | Failure investigation is delayed. | Display available API logs and distinguish pending, unavailable, and expired states. | P1 |
| P17 | A | Cache, downloads, and setup can consume time savings | 2 author account(s): [E0020](https://github.com/nektos/act/issues/6120), [E0026](https://www.reddit.com/r/devops/comments/1wfw0o1/comment/p9pghpl/) | Repeated downloads slow iterations. | Separate setup, transfer, and execution timings; suggest opt-in caching. | P2 |
| P18 | C | Runner updates and deprecations disrupt fleet readiness | 2 author account(s): [E0021](https://github.com/actions/runner/issues/4570), [E0022](https://github.com/actions/runner/issues/4442) | Jobs hang or runners stop accepting work. | Provide read-only runner version/health information and upstream notices. | P2 |
| P19 | B | Sequential phases require repeated environment approvals | 1 author account(s): [E0015](https://github.com/orgs/community/discussions/201528) | Operators return for multiple approvals. | Show current pending approvals while preserving protection semantics. | P2 |
| P20 | C | Run elapsed duration is confused with job execution | 2 author account(s): [E0012](https://github.com/orgs/community/discussions/211084), [E0033](https://github.com/orgs/community/discussions/211773) | Queue time or cost can be misdiagnosed. | Separate intervals and attempts, flag contradictory timestamps, and do not treat updated_at as completion. | P2 |
| P10 | A | Permissions and workflow trust boundaries are hard to navigate | 3 author account(s): [E0024](https://www.reddit.com/r/devops/comments/1wfw0o1/comment/p9pg63t/), [E0029](https://news.ycombinator.com/item?id=50185520), [E0042](https://stackoverflow.com/questions/80012905/how-can-i-safely-publish-a-report-for-a-fork-pr-when-actions-checkoutv7-blocks) | Access configuration is harder; one concrete fork-reporting case involves an intended security safeguard. | Explain grants, trusted publisher code, and intended fork-checkout protection. | P2 |
| P07 | B | Rebuilding instead of promoting one artifact | 1 author account(s); provider unspecified: [E0032](https://www.reddit.com/r/devops/comments/1v0v1a4/comment/ozuiecg/) | Releases and hotfixes take longer. | Detect duplicate builds read-only before adding explicit promotion workflows. | P2 |
| P13 | C | Duplicate suites can disagree with required-check and merge state | 1 author account: [E0038](https://github.com/orgs/community/discussions/211754) | Operators can target the wrong rerun or mistake a green aggregate for merge readiness. | Group runs, attempts, suites, and checks by exact PR head and show merge readiness separately. | P2 |
| P23 | A | Expected schedule executions are missing without a run record | 1 author account: [E0035](https://github.com/orgs/community/discussions/211723) | There is no job log for the missing opportunity. | Show suspected schedule gaps separately from queued runs; do not infer a cause or auto-dispatch replacements. | P2 |
| P24 | A | Artifact storage limits are confused with compute and Git activity | 1 author account: [E0041](https://www.reddit.com/r/vibecoding/comments/1xmhx3y/hit_my_github_usage_amount_and_not_sure_what_to_do/) | The operator cannot identify the relevant usage category or retention change. | Explain artifact inventory and retention separately from accrued billing; offer reviewed cleanup. | P2 |
| P08 | B | No one-time future dispatch with custom inputs | 1 author account(s): [E0005](https://github.com/orgs/community/discussions/204703) | An operator must wait for a maintenance window. | Keep outside the MVP: reliable scheduling requires an available executor. | P3 |
| P21 | C | Historical stale API results selected an incorrect baseline | 3 author account(s): [E0016](https://github.com/orgs/community/discussions/206725), [E0030](https://github.com/community/community/discussions/206725#discussioncomment-18275373), [E0031](https://github.com/community/community/discussions/206725#discussioncomment-18776081) | Builds repeated unnecessarily or consumed outdated dependencies. | Validate freshness and coverage; the primary upstream defect was reported resolved. | P3 |


## Priority rationale

P0 means a demonstrated Runnir release blocker. **No new P0 is established by this sample.** Priorities reflect qualitative frequency, impact, feasibility, differentiation, and MVP fit rather than numeric scores.

| Pains | Frequency and impact | Feasibility and differentiation | MVP fit and decision |
|---|---|---|---|
| P05 | Six authors; concrete local compatibility failures | Preflight is feasible; full cloud parity is not. Value comes from combining editing, validation, and honest capability reporting | P1: strengthen B03/B14-B16 without promising faster or equivalent execution |
| P01/P03 | Three and two authors; repeated manual operations | Dispatch and rerun APIs exist; value is reduced navigation | P1: assess usability of the existing B09/B10/B13/B25 flows |
| P09/P06 | Several reports with operational impact; some queue reports are outage-related | Observations can be shown; internal causes cannot be inferred reliably | P1 for B35/B36 diagnosis, without a new scheduler |
| P02/P04/P11 | One detailed source each; broad recurrence is unproven | APIs and local storage offer bounded improvements | P1 for inspector/history improvements; older docs call B33/B34 built, but runtime behavior was not verified here |
| P17/P18 | Two authors each; time and reliability impact | Measurement and read-only health are feasible; upstream repairs are outside the app's control | P2 candidates for v0.2, without automatic fleet administration |
| P19/P20 | One approval scenario and two distinct timing reports | UI can explain state without changing GitHub protection or billing | P2 inspection, without approval bypass |
| P10/P07 | Two broad permission opinions, one concrete trust-boundary question, and one cross-CI artifact scenario | Explain intended safeguards and offer reviewed suggestions; universal promotion is not feasible | P2 discovery; preserve security protections and keep artifact promotion in v0.4 |
| P24 | One detailed storage-confusion scenario; broader recurrence is unproven | Artifact metadata is readable and retention is explainable; inventory is not an authoritative account bill | P2 visibility candidate with modest infrastructure, no automatic deletion or predicted savings |
| P08/P21 | Scheduling has poor MVP fit; stale listing received an upstream resolution | Always-on infrastructure exceeds a desktop MVP; API integrity remains useful engineering practice | P3 rather than new MVP features |
| P22 | One detailed report; one public job snapshot corroborates a cancelled leg and successful gate | Attempt-specific Jobs API is available; value is accurate inspection rather than changing aggregation | P1 diagnostic candidate, not a new release gate or an automatic gate rewrite |
| P23 | One concrete missing-schedule report; recurrence and internal cause are unproven | Compare default-branch schedule with observed runs; a durable scheduler requires separate infrastructure | P2 visibility candidate; absence of a run is not a queued job |
| P13 | One author supplies natural observations and a controlled recovery experiment | Runs/checks can be grouped read-only; GitHub's internal selection rule is not established | P2 extension of existing run-by-change inspection; no branch-policy bypass |

## Verified GitHub API capabilities

Official documentation and OpenAPI were checked on 2026-10-26. No production dispatch, rerun, or cancellation was performed.

| Capability | Verified contract | Recommendation boundary |
|---|---|---|
| Manual dispatch | [Workflows API](https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event): ref, inputs, and Actions write permission. API version 2026-03-10 returns HTTP 200 with workflow_run_id and URLs | Bind the receipt to the returned ID. Acceptance does not prove successful execution. Unsaved local YAML cannot be dispatched as a published remote workflow |
| Dispatch response versions | [Official OpenAPI](https://github.com/github/rest-api-description/blob/main/descriptions/api.github.com/api.github.com.json), operation actions/create-workflow-dispatch, change_workflow_dispatch_response_status | The older contract offers return_run_details as opt-in; 2026-03-10 returns the ID by default. Correlation is not universally heuristic. Verify individual GHES versions separately |
| Rerun and cancel | [Runs API](https://docs.github.com/en/rest/actions/workflow-runs#re-run-a-job-from-a-workflow-run): job rerun also reruns dependent jobs; failed-jobs rerun and cancel/force-cancel are available | Do not promise exactly one isolated job or successful force-cancel in every state |
| History and search | [List runs](https://docs.github.com/en/rest/actions/workflow-runs#list-workflow-runs-for-a-repository) exposes filters and display_title | Text search is client-side; show the limits of loaded history |
| Previous inputs | The checked OpenAPI workflow-run schema has no documented inputs field | Retain only permitted non-secret values submitted through Runnir; external inputs or secrets may remain unavailable |
| Jobs and logs | [Jobs API](https://docs.github.com/en/rest/actions/workflow-jobs) exposes jobs and downloadable logs | Do not promise live streaming before logs become available. Distinguish unavailable and expired resources |
| Deployments | [Deployments API](https://docs.github.com/en/rest/deployments/deployments) and [pending deployments](https://docs.github.com/en/rest/actions/workflow-runs#get-pending-deployments-for-a-workflow-run) expose recorded deployment state | Recorded state does not prove the current state of a VPS or Kubernetes cluster without reporting integration. Approval requires current_user_can_approve and the appropriate permissions; it does not approve future jobs automatically |
| Artifact reuse | [Artifacts API](https://docs.github.com/en/rest/actions/artifacts) supports listing, retrieval, and download | Promotion needs an explicit deployment workflow, digest, producer SHA, access, integrity, and retention checks. There is no universal rollback API |
| Local execution | [act limitations](https://nektosact.com/not_supported.html) include ignored permissions, environments, concurrency, and missing OIDC behavior | Local success does not prove remote success, security-policy compliance, or environment approval |

## Upstream solutions and changed assumptions

- **Inputs:** [25 inputs replaced the limit of 10 on 2025-12-04](https://github.blog/changelog/2025-12-04-actions-workflow-dispatch-workflows-now-support-25-inputs/). The old limit is no longer a product argument, although stale branch-specific forms are a separate complaint.
- **Skipped jobs and editing:** [The 2026-01-29 update](https://github.blog/changelog/2026-01-29-github-actions-smarter-editing-clearer-debugging-and-a-new-case-function/) added expanded condition logs and validation. B35 should present available explanations conveniently and mark unknown runtime contexts explicitly.
- **Stale listings:** [The 2026-10-09 reply](https://github.com/community/community/discussions/206725#discussioncomment-18835621) reports that the main timeout cause was eliminated. This is an upstream report, not an independent load test. The included sample contains no later verified regression; P21 remains historical and P3.
- **Large history queries:** [The 2026-09-25 change](https://github.blog/changelog/2026-09-25-changes-to-query-results-in-the-github-actions-api-and-ui/) caps counts at 2,500+ and paginated results at 1,000. Use bounded date ranges and avoid treating total_count as exact complete history.
- **Security:** [Workflow lockfiles entered public preview on 2026-10-14](https://github.blog/changelog/2026-10-14-github-actions-workflow-lockfiles-in-public-preview/). Future diagnostics should understand actions.lock rather than introduce another lock format.

## Product opportunities

1. **Compatibility preflight for local execution:** distinguish actionlint from act execution, identify unsupported syntax/action versions before running, and expose setup time. Time savings still require measurement.
2. **A connected manual-run and recovery flow:** selected-ref inputs, a receipt containing the run ID, saved non-secret values, logs, and rerun controls next to failed jobs. Compare task time and interaction counts with GitHub on the same fixture repository.
3. **Queue and execution-state explanations:** distinguish missing jobs, allocation delay, approval, and stale metadata; show source and freshness. A single status field cannot establish the cause, and production dispatch should not be retried blindly.

For the MVP, preserve SwiftUI and portable Go Core under ADR 0002/0004, Keychain storage, and telemetry disabled by default. These findings introduce no acceptance gates and do not verify features described as built in older documents.

For v0.2, consider P17/P18/P19/P20, bounded history and retention, and deployment metadata linked to environments. Cross-repository monitoring (P14/B39) remains a hypothesis: the [dashboard post](https://www.reddit.com/r/devops/comments/1qvlqgq/i_built_a_github_actions_monitoring_tool_for/) is promotional and outside this window. P12 and P14-P16 remain reserved without evidence assigned in this CSV. P13 retains its legacy duplicate/superseded-run identity and now has direct evidence; P22 and P23 are new IDs. Legacy P10 combined permissions and deployment visibility; this dataset uses it for permissions without claiming separate verified demand for deployment visibility.

For v0.4, consider explicit artifact promotion and build-once-deploy-many through an opt-in YAML diff with provenance, digest, and permission checks. Diagnose repeated work first; elapsed duration alone cannot establish monetary savings.

## Research limitations

- This is a targeted, nonrepresentative sample. The 34 threads are included sources, not all examined results. Included publications start in May; no April entries does not establish an absence of problems.
- Platform coverage is uneven, especially Stack Overflow and engineering blogs. No saturation or population-frequency claim is supported.
- Some Reddit content was unavailable or removed. Cached content that disagreed with the current source was excluded. The old acceleration claim from post 1uaafd5 was not imported.
- HN comments were verified through Algolia because the direct page was unavailable. A DEV deployment story with an unconfirmed publication year was excluded. Crawl dates were not substituted for publication dates.
- Bots, generic advice, promotional announcements, and brief agreement do not count as independent evidence. Public author accounts support deduplication, not outreach.
- Several queue reports may describe the same incident. Reported causes are not independent reproductions or proof that Runnir can repair GitHub infrastructure.
- API findings describe the checked github.com contract; GHES support requires version-specific verification. Monetary savings, arbitrary-workflow safety, and full local/remote parity are unproven.

See the [baseline findings](weekly/2026-10-26.md), [2026-11-02 findings](weekly/2026-11-02.md), and [latest findings](weekly/2026-11-09.md). The latest review adds three evidence rows from three new parent threads outside GitHub; prior weekly reports remain unchanged.

## Latest API and upstream review - 2026-11-02

- [Attempt-specific jobs](https://docs.github.com/en/rest/actions/workflow-jobs#list-jobs-for-a-workflow-run-attempt) expose per-job conclusions with Actions read permission. Paginate and compare against the expected matrix: observing one or more jobs is not proof that all intended legs exist. The [needs context](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#needs-context) documents result values but does not establish the internal cause of E0034.
- [Schedule documentation](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule) warns of delays and dropped jobs under load, default-branch requirements, and public-repository inactivity disabling. A gap is not proof of a particular backend failure. The checked Runs API lists created runs; no documented missed-tick history was identified.
- [Check runs](https://docs.github.com/en/rest/checks/runs) and [workflow runs](https://docs.github.com/en/rest/actions/workflow-runs) provide separate identities and conclusions. Do not infer merge permission from a selected green check. Reruns require appropriate authorization and may be rejected; no read API allows Runnir to reconcile GitHub's internal state. E0038's recovery is author-reported, case-specific evidence, not a general service fix.
- [GitHub Agentic Workflows became generally available on 2026-10-28](https://github.blog/changelog/2026-10-28-github-agentic-workflows-generally-available/), including CI failure analysis. This is upstream product context, not independent complaint evidence or a reason to add AI infrastructure to the desktop MVP.

## Latest findings and API review - 2026-11-09

The three new records come from two Reddit threads and one Stack Overflow question. External evidence now comprises 11 rows across six parent threads, versus 31 GitHub rows. This improves source diversity but does not establish representative coverage; HN, DEV, engineering blogs, and competing-CI discussions remain thin. P24 is a new artifact-storage visibility pain, while P09 and P10 receive additional evidence. Same-author follow-ups to P13 are not new independent users.

- [Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions) distinguishes compute from artifact/cache storage. Current inventory and accrued storage are different: deleting artifacts reduces current storage and future accumulation without erasing past usage. A warning does not establish which workflow or billing category caused the account's charges.
- [Artifacts API](https://docs.github.com/en/rest/actions/artifacts) provides artifact metadata with Actions read permission; deletion is a separate authorized operation. A size inventory alone cannot reconstruct a complete account bill, and metadata inspection does not require downloading artifact contents.
- [Checkout v7 release notes](https://github.com/actions/checkout/releases/tag/v7.0.0) document the block on fork PR checkout under workflow_run and pull_request_target. [workflow_run documentation](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run) warns about executing untrusted code with elevated privileges. P10's new report concerns adapting to an intended protection; it is not evidence for disabling the safeguard. Trusted publisher code must still validate untrusted report data, run/PR identity, and output handling.

No new upstream fix or backend cause is established for the queue report. Recommendations remain read-only diagnosis, reviewed workflow suggestions, and explicit approval for cleanup or execution.
