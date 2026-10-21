package github

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"
)

func run(workflow int64, status, conclusion string, created time.Time, url string) Run {
	return Run{WorkflowID: workflow, Status: status, Conclusion: conclusion, CreatedAt: created, HTMLURL: url}
}

func TestCIIsSummedUpPerWorkflow(t *testing.T) {
	t0 := time.Date(2026, 10, 21, 10, 0, 0, 0, time.UTC)
	for name, tc := range map[string]struct {
		runs []Run
		want CIState
		url  string
	}{
		"none":      {nil, CINone, ""},
		"passed":    {[]Run{run(1, "completed", "success", t0, "a"), run(2, "completed", "skipped", t0, "b")}, CIPassed, ""},
		"failed":    {[]Run{run(1, "in_progress", "", t0, "a"), run(2, "completed", "failure", t0, "b")}, CIFailed, "b"},
		"running":   {[]Run{run(1, "queued", "", t0, "a"), run(2, "completed", "success", t0, "b")}, CIRunning, "a"},
		"cancelled": {[]Run{run(1, "completed", "cancelled", t0, "a")}, CICancelled, ""},
		// A re-run replaces the failed run of the same workflow.
		"re-run": {[]Run{run(1, "completed", "failure", t0, "old"), run(1, "completed", "success", t0.Add(time.Minute), "new")}, CIPassed, ""},
	} {
		pr := PullRequest{}
		summarizeCI(&pr, tc.runs)
		if pr.CI != tc.want || pr.CIURL != tc.url {
			t.Errorf("%s: %v %q, want %v %q", name, pr.CI, pr.CIURL, tc.want, tc.url)
		}
	}
}

func TestMyPullRequestsCarryTheirCI(t *testing.T) {
	client, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/search/issues" && strings.Contains(r.URL.Query().Get("q"), "is:open"):
			if !strings.Contains(r.URL.Query().Get("q"), "author:@me") {
				t.Errorf("query = %q", r.URL.Query().Get("q"))
			}
			_, _ = w.Write([]byte(`{"items":[
				{"number":7,"title":"Fix","html_url":"https://github.com/o/r/pull/7","state":"open","draft":true,"updated_at":"2026-10-21T09:00:00Z","repository_url":"https://api.github.com/repos/o/r","pull_request":{}},
				{"number":3,"title":"Docs","html_url":"https://github.com/o/locked/pull/3","state":"open","updated_at":"2026-10-21T08:00:00Z","repository_url":"https://api.github.com/repos/o/locked","pull_request":{}},
				{"number":1,"title":"An issue","state":"open","repository_url":"https://api.github.com/repos/o/r"}]}`))
		case r.URL.Path == "/search/issues":
			if !strings.Contains(r.URL.Query().Get("q"), "closed:>=2026-10-20T10:00:00Z") {
				t.Errorf("closed query = %q", r.URL.Query().Get("q"))
			}
			_, _ = w.Write([]byte(`{"items":[{"number":5,"title":"Merged","html_url":"u","state":"closed","closed_at":"2026-10-21T07:00:00Z","repository_url":"https://api.github.com/repos/o/r","pull_request":{"merged_at":"2026-10-21T07:00:00Z"}}]}`))
		case r.URL.Path == "/repos/o/r/pulls/7":
			_, _ = w.Write([]byte(`{"head":{"sha":"abc","ref":"fix"}}`))
		case r.URL.Path == "/repos/o/r/actions/runs":
			if r.URL.Query().Get("head_sha") != "abc" {
				t.Errorf("head_sha = %q", r.URL.Query().Get("head_sha"))
			}
			_, _ = w.Write([]byte(`{"workflow_runs":[{"id":1,"workflow_id":9,"status":"completed","conclusion":"failure","html_url":"https://github.com/o/r/actions/runs/1","created_at":"2026-10-21T09:00:00Z"}]}`))
		case r.URL.Path == "/repos/o/locked/pulls/3":
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"message":"Resource not accessible by integration"}`))
		default:
			t.Errorf("unexpected %s", r.URL)
			w.WriteHeader(http.StatusNotFound)
		}
	})
	pulls, err := client.MyPullRequests(context.Background(), time.Date(2026, 10, 20, 10, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	if len(pulls.Open) != 2 || len(pulls.Closed) != 1 || !pulls.HeadsUnreadable {
		t.Fatalf("pulls = %+v", pulls)
	}
	fix, locked := pulls.Open[0], pulls.Open[1]
	if fix.Repository != "o/r" || !fix.Draft || fix.HeadBranch != "fix" || fix.CI != CIFailed || fix.CIURL != "https://github.com/o/r/actions/runs/1" {
		t.Fatalf("fix = %+v", fix)
	}
	if locked.CI != CIUnknown {
		t.Fatalf("locked = %+v", locked)
	}
	if pulls.Closed[0].State != "merged" || pulls.Closed[0].ClosedAt.IsZero() {
		t.Fatalf("closed = %+v", pulls.Closed[0])
	}
}
