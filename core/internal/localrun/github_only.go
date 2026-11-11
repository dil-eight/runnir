package localrun

import (
	"strings"

	"github.com/rhysd/actionlint"
)

// gitHubOnlyActions are actions that work only in a run on GitHub, by owner,
// repository and path as `uses:` names them (without the ref). They need
// what only GitHub gives a run: its APIs about the pull request or the
// repository, or the run's OIDC token. A local run fails at them whatever
// the workflow does, so Runnir does not run their jobs locally (ADR 0006).
var gitHubOnlyActions = map[string]string{
	"actions/dependency-review-action":  "compares the pull request's dependencies through GitHub's dependency graph",
	"actions/attest-build-provenance":   "signs an attestation with the run's OIDC token, which only GitHub issues",
	"actions/attest-sbom":               "signs an attestation with the run's OIDC token, which only GitHub issues",
	"actions/attest":                    "signs an attestation with the run's OIDC token, which only GitHub issues",
	"actions/deploy-pages":              "deploys to GitHub Pages with the run's OIDC token, which only GitHub issues",
	"github/codeql-action/upload-sarif": "uploads results to GitHub code scanning",
}

// gitHubOnlyPrefix starts the reason of a job that runs only on GitHub.
const gitHubOnlyPrefix = "Only on GitHub: "

// gitHubOnly says why a job runs only on GitHub, or "" when it can run
// locally: the first of its steps that uses an action from the list.
func gitHubOnly(job *actionlint.Job) string {
	if job == nil {
		return ""
	}
	for _, step := range job.Steps {
		if step == nil {
			continue
		}
		action, ok := step.Exec.(*actionlint.ExecAction)
		if !ok || action.Uses == nil {
			continue
		}
		name, _, _ := strings.Cut(strings.ToLower(action.Uses.Value), "@")
		if why, found := gitHubOnlyActions[name]; found {
			return gitHubOnlyPrefix + action.Uses.Value + " " + why + "."
		}
	}
	return ""
}

// markGitHubOnly marks the jobs that run only on GitHub, and the jobs that
// need one of them, which cannot start without it.
func markGitHubOnly(jobs []JobPlan, workflow *actionlint.Workflow) {
	for i := range jobs {
		if why := gitHubOnly(workflow.Jobs[strings.ToLower(jobs[i].ID)]); why != "" {
			jobs[i].Support, jobs[i].Reason, jobs[i].Image, jobs[i].GitHubOnly = Unsupported, why, "", true
		}
	}
	for changed := true; changed; {
		changed = false
		for i := range jobs {
			if jobs[i].GitHubOnly {
				continue
			}
			for _, need := range jobs[i].Needs {
				if j := jobIndex(jobs, need); j >= 0 && jobs[j].GitHubOnly {
					jobs[i].Support, jobs[i].Image, jobs[i].GitHubOnly = Unsupported, "", true
					jobs[i].Reason = gitHubOnlyPrefix + "needs " + jobs[j].ID + ", which runs only on GitHub."
					changed = true
					break
				}
			}
		}
	}
}

func jobIndex(jobs []JobPlan, id string) int {
	for i := range jobs {
		if strings.EqualFold(jobs[i].ID, id) {
			return i
		}
	}
	return -1
}
