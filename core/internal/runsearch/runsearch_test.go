package runsearch

import (
	"reflect"
	"testing"
	"time"
)

func record(id int64) Record {
	return Record{ID: id, RunNumber: id, Title: "Fix build", Workflow: "CI", Branch: "main", SHA: "a3f9c21ffee0", Author: "eugene",
		Event: "push", Status: "completed", Conclusion: "success", CreatedAt: time.Date(2026, 3, 12, 10, 0, 0, 0, time.UTC)}
}

func found(query string, runs ...Record) []int64 {
	q := Parse(query)
	var ids []int64
	for _, r := range runs {
		if q.Matches(r) {
			ids = append(ids, r.ID)
		}
	}
	return ids
}

func TestABlankQueryIsNoSearch(t *testing.T) {
	if q := Parse("   "); q.Active() || len(q.Words) != 0 {
		t.Fatalf("blank = %+v", q)
	}
	if got := found("", record(1), record(2)); !reflect.DeepEqual(got, []int64{1, 2}) {
		t.Fatalf("blank matches = %v", got)
	}
}

func TestWordsMatchInAnyCaseAndEveryWordHasToMatch(t *testing.T) {
	a, b := record(1), record(2)
	a.Title, b.Title = "Fix profile lookup for archive step", "Bump Fastlane"
	if got := found("PROFILE", a, b); !reflect.DeepEqual(got, []int64{1}) {
		t.Fatalf("profile = %v", got)
	}
	if got := found("fix lookup", a, b); !reflect.DeepEqual(got, []int64{1}) {
		t.Fatalf("two words = %v", got)
	}
	if got := found("fix fastlane", a, b); len(got) != 0 {
		t.Fatalf("words of different runs = %v", got)
	}
}

func TestACommitMatchesFromItsFirstCharactersOnly(t *testing.T) {
	a, b := record(1), record(2)
	b.SHA = "0b1c2d3e4f50"
	for query, want := range map[string][]int64{"a3f9": {1}, "a3f9c21": {1}, "f9c2": nil, "a3f": nil} {
		if got := found(query, a, b); !reflect.DeepEqual(got, want) {
			t.Errorf("%q = %v, want %v", query, got, want)
		}
	}
}

func TestTheOutcomeAndTheNumbersMatch(t *testing.T) {
	ok, failed := record(881), record(879)
	failed.Conclusion = "failure"
	failed.PullRequests = []int64{142}
	if got := found("failed", ok, failed); !reflect.DeepEqual(got, []int64{879}) {
		t.Fatalf("failed = %v", got)
	}
	if got := found("succeeded", ok, failed); !reflect.DeepEqual(got, []int64{881}) {
		t.Fatalf("succeeded = %v", got)
	}
	if got := found("#142", ok, failed); !reflect.DeepEqual(got, []int64{879}) {
		t.Fatalf("pull request = %v", got)
	}
	if got := found("#881", ok, failed); !reflect.DeepEqual(got, []int64{881}) {
		t.Fatalf("run number = %v", got)
	}
	if got := found("879", ok, failed); !reflect.DeepEqual(got, []int64{879}) {
		t.Fatalf("bare number = %v", got)
	}
}

func TestTextOfALinkedPullRequestFindsTheRun(t *testing.T) {
	r := record(1)
	r.PullRequestText = []string{"Add retry to deploy", "octocat"}
	if got := found("retry octocat", r); !reflect.DeepEqual(got, []int64{1}) {
		t.Fatalf("pull request words = %v", got)
	}
}

func TestQualifiersNarrowTheSearch(t *testing.T) {
	a, b := record(1), record(2)
	b.Branch, b.Author, b.Event, b.Workflow, b.Conclusion = "release/1.4", "octocat", "workflow_dispatch", "Deploy", "failure"
	cases := map[string][]int64{
		"branch:main": {1}, "branch:RELEASE/1.4": {2}, "author:octocat": {2}, "event:push": {1},
		"workflow:deploy": {2}, "status:failed": {2}, "status:success": {1}, "status:failed status:success": {1, 2},
		"branch:main status:failed": nil,
	}
	for query, want := range cases {
		if got := found(query, a, b); !reflect.DeepEqual(got, want) {
			t.Errorf("%q = %v, want %v", query, got, want)
		}
	}
}

func TestDatesBoundTheDayARunWasCreated(t *testing.T) {
	a, b := record(1), record(2)
	b.CreatedAt = time.Date(2026, 4, 2, 23, 59, 0, 0, time.UTC)
	cases := map[string][]int64{
		"after:2026-03-12": {1, 2}, "after:2026-03-13": {2}, "before:2026-03-12": {1}, "before:2026-04-02": {1, 2},
		"after:2026-03-01 before:2026-03-31": {1},
	}
	for query, want := range cases {
		if got := found(query, a, b); !reflect.DeepEqual(got, want) {
			t.Errorf("%q = %v, want %v", query, got, want)
		}
	}
	if q := Parse("after:yesterday status:nope"); len(q.Problems) != 2 {
		t.Fatalf("problems = %v", q.Problems)
	}
}

func TestAWordWithAColonIsAWordUnlessItIsAQualifier(t *testing.T) {
	q := Parse("fix: retry foo:bar branch:")
	if !reflect.DeepEqual(q.Words, []string{"fix:", "retry", "foo:bar", "branch:"}) || q.Branch != "" {
		t.Fatalf("query = %+v", q)
	}
}

func TestStatusMapsEveryPairToOneOfSix(t *testing.T) {
	cases := []struct {
		status, conclusion string
		want               Status
	}{
		{"completed", "success", Succeeded}, {"completed", "failure", Failed}, {"completed", "timed_out", Failed},
		{"completed", "startup_failure", Failed}, {"completed", "cancelled", Cancelled}, {"completed", "skipped", Skipped},
		{"completed", "neutral", Skipped}, {"completed", "stale", Skipped}, {"completed", "action_required", Queued},
		{"in_progress", "", Running}, {"queued", "", Queued}, {"waiting", "", Queued}, {"pending", "", Queued}, {"requested", "", Queued},
	}
	for _, c := range cases {
		if got := StatusOf(c.status, c.conclusion); got != c.want {
			t.Errorf("%s/%s = %s, want %s", c.status, c.conclusion, got, c.want)
		}
	}
}

func TestGitHubGetsWhatItCanFilter(t *testing.T) {
	q := Parse("branch:main author:Octo event:push status:failed after:2026-03-01 deploy")
	f := q.GitHub(time.Time{})
	if f.Branch != "main" || f.Actor != "octo" || f.Event != "push" || f.Status != "failure" || f.Created != ">=2026-03-01T00:00:00Z" {
		t.Fatalf("filter = %+v", f)
	}
	upper := time.Date(2026, 3, 10, 12, 0, 0, 0, time.UTC)
	if f := q.GitHub(upper); f.Created != "2026-03-01T00:00:00Z..2026-03-10T12:00:00Z" {
		t.Fatalf("range = %q", f.Created)
	}
	if f := Parse("status:failed status:cancelled").GitHub(time.Time{}); f.Status != "" {
		t.Fatalf("two statuses are filtered here, not by GitHub: %q", f.Status)
	}
	sha := "a3f9c21ffee0a3f9c21ffee0a3f9c21ffee0a3f9"
	if f := Parse(sha).GitHub(time.Time{}); f.HeadSHA != sha {
		t.Fatalf("sha = %q", f.HeadSHA)
	}
	if f := Parse("").GitHub(upper); f.Created != "<=2026-03-10T12:00:00Z" {
		t.Fatalf("no filters, a bound = %q", f.Created)
	}
}
