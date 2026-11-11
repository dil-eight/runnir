package localrun

import (
	"slices"
	"strings"
	"testing"
)

// A job with an action that works only on GitHub, and a job that needs it,
// are never ticked locally and say why; naming one refuses the run.
func TestJobsThatNeedGitHubDoNotRunLocally(t *testing.T) {
	source := `on: pull_request
jobs:
  build:
    runs-on: ubuntu-latest
    steps: [{run: make}]
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: Actions/Dependency-Review-Action@v5
  after-review:
    needs: review
    runs-on: ubuntu-latest
    steps: [{run: echo}]
  provenance:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/attest-build-provenance@v3
        with: {subject-path: dist/app}
  sarif:
    runs-on: ubuntu-latest
    steps:
      - uses: github/codeql-action/upload-sarif@v4
        with: {sarif_file: results.sarif}
`
	p := plan(t, source, "", readyReport(), nil)
	if got := selected(p.Lanes[0]); !slices.Equal(got, []string{"build"}) {
		t.Fatalf("ticked = %v", got)
	}
	if len(p.Blockers) != 0 {
		t.Fatalf("the scenario's own run is refused: %v", p.Blockers)
	}
	want := map[string]string{
		"review":       "Only on GitHub: Actions/Dependency-Review-Action@v5 compares the pull request's dependencies through GitHub's dependency graph.",
		"after-review": "Only on GitHub: needs review, which runs only on GitHub.",
		"provenance":   "Only on GitHub: actions/attest-build-provenance@v3 signs an attestation with the run's OIDC token, which only GitHub issues.",
		"sarif":        "Only on GitHub: github/codeql-action/upload-sarif@v4 uploads results to GitHub code scanning.",
	}
	for _, job := range p.Lanes[0].Jobs {
		if reason, ok := want[job.ID]; ok && (job.Support != Unsupported || !job.GitHubOnly || job.Reason != reason) {
			t.Fatalf("%s = %+v", job.ID, job)
		}
		if job.ID == "build" && job.GitHubOnly {
			t.Fatalf("build runs only on GitHub: %+v", job)
		}
	}

	for _, named := range []string{"review", "after-review"} {
		p := plan(t, source, named, readyReport(), nil)
		if p.Runnable() || !slices.ContainsFunc(p.Blockers, func(b string) bool {
			return strings.Contains(b, "cannot run locally") && strings.Contains(b, "Only on GitHub")
		}) {
			t.Fatalf("naming %s: runnable = %v, blockers = %v", named, p.Runnable(), p.Blockers)
		}
	}
}

// A checkout of the action's repository under another name, or another
// action of the same owner, is not on the list.
func TestOnlyListedActionsNeedGitHub(t *testing.T) {
	source := `on: push
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: github/codeql-action/init@v4
      - uses: actions/dependency-review-action-fork@v1
      - uses: ./actions/dependency-review-action
`
	p := plan(t, source, "", readyReport(), nil)
	if job := p.Lanes[0].Jobs[0]; job.GitHubOnly || job.Support != Supported || !job.Selected {
		t.Fatalf("scan = %+v", job)
	}
}
