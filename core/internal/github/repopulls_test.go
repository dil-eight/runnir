package github

import (
	"context"
	"errors"
	"net/http"
	"testing"
	"time"
)

const pullsPage = `[
	{"number":142,"title":"Add retry","state":"closed","draft":false,"html_url":"https://github.com/o/r/pull/142",
	 "user":{"login":"octocat"},"head":{"ref":"retry","sha":"b2","repo":{"full_name":"O/R"}},"base":{"ref":"main"},
	 "merge_commit_sha":"m1","created_at":"2026-10-18T08:00:00Z","updated_at":"2026-10-18T12:00:00Z",
	 "closed_at":"2026-10-18T11:00:00Z","merged_at":"2026-10-18T11:00:00Z"},
	{"number":145,"title":"Cache images","state":"open","draft":true,"html_url":"https://github.com/o/r/pull/145",
	 "user":null,"head":{"ref":"cache","sha":"d4","repo":null},"base":{"ref":"main"},
	 "merge_commit_sha":"test-merge","created_at":"2026-10-18T09:00:00Z","updated_at":"2026-10-18T10:00:00Z",
	 "closed_at":null,"merged_at":null}]`

func TestRepositoryPullRequestsAreReadConditionally(t *testing.T) {
	client, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		query := r.URL.Query()
		if r.URL.Path != "/repos/o/r/pulls" || query.Get("state") != "all" || query.Get("sort") != "updated" ||
			query.Get("direction") != "desc" || query.Get("per_page") != "50" {
			t.Errorf("request = %s", r.URL)
		}
		if r.Header.Get("If-None-Match") == `"p1"` {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.Header().Set("ETag", `"p1"`)
		_, _ = w.Write([]byte(pullsPage))
	})
	ctx := context.Background()
	pulls, tag, err := client.PullRequestsIfChanged(ctx, "o", "r", "")
	if err != nil || tag != `"p1"` || len(pulls) != 2 {
		t.Fatalf("pulls = %+v, %q, %v", pulls, tag, err)
	}
	merged, open := pulls[0], pulls[1]
	if merged.Number != 142 || merged.State != "closed" || merged.Author != "octocat" || merged.HeadRepository != "o/r" ||
		merged.MergeCommitSHA != "m1" || !merged.MergedAt.Equal(time.Date(2026, 10, 18, 11, 0, 0, 0, time.UTC)) {
		t.Fatalf("merged = %+v", merged)
	}
	// An open pull request's merge_commit_sha is GitHub's test merge: not kept.
	if open.MergeCommitSHA != "" || !open.Draft || open.HeadRepository != "" || !open.ClosedAt.IsZero() {
		t.Fatalf("open = %+v", open)
	}
	if _, _, err := client.PullRequestsIfChanged(ctx, "o", "r", tag); !errors.Is(err, ErrNotModified) {
		t.Fatalf("second read = %v", err)
	}
}

func TestPullRequestLookups(t *testing.T) {
	client, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/repos/o/r/pulls/142":
			_, _ = w.Write([]byte(`{"number":142,"title":"Add retry","state":"open","head":{"ref":"retry","sha":"b2","repo":{"full_name":"o/r"}},"base":{"ref":"main"}}`))
		case r.URL.Path == "/repos/o/r/commits/m1/pulls":
			_, _ = w.Write([]byte(pullsPage))
		case r.URL.Path == "/repos/o/r/pulls" && r.URL.Query().Get("head") == "fork:patch-1":
			if r.URL.Query().Get("state") != "all" {
				t.Errorf("head query = %s", r.URL)
			}
			_, _ = w.Write([]byte(`[{"number":150,"title":"Typo","state":"open","head":{"ref":"patch-1","sha":"f5","repo":{"full_name":"fork/r"}},"base":{"ref":"main"}}]`))
		default:
			t.Errorf("unexpected %s", r.URL)
			w.WriteHeader(http.StatusNotFound)
		}
	})
	ctx := context.Background()
	if pr, err := client.RepositoryPull(ctx, "o", "r", 142); err != nil || pr.Number != 142 || pr.HeadSHA != "b2" {
		t.Fatalf("pull = %+v, %v", pr, err)
	}
	if prs, err := client.CommitPullRequests(ctx, "o", "r", "m1"); err != nil || len(prs) != 2 {
		t.Fatalf("commit = %+v, %v", prs, err)
	}
	if prs, err := client.HeadPullRequests(ctx, "o", "r", "fork", "patch-1"); err != nil || len(prs) != 1 || prs[0].HeadRepository != "fork/r" {
		t.Fatalf("head = %+v, %v", prs, err)
	}
	if _, err := client.RepositoryPull(ctx, "o", "r", 0); !errors.Is(err, ErrInvalid) {
		t.Fatalf("number 0 = %v", err)
	}
}
