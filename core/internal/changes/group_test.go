package changes

import (
	"reflect"
	"testing"

	"runnir/core/internal/github"
)

func TestTheExampleIsOneChange(t *testing.T) {
	in := example()
	changes := Group(in, Analyze(in), in.Runs)
	if len(changes) != 1 {
		t.Fatalf("changes = %+v", changes)
	}
	c := changes[0]
	if c.ID != "pr:142" || c.PullRequest == nil || c.PullRequest.Title != "Add retry to deploy" || c.PullRequest.State != "merged" ||
		c.Status != github.CIPassed || !c.LatestAt.Equal(at(70)) {
		t.Fatalf("change = %+v", c)
	}
	if len(c.Sections) != 2 {
		t.Fatalf("sections = %+v", c.Sections)
	}
	merged, latest := c.Sections[0], c.Sections[1]
	if merged.Kind != SectionAfterMerge || merged.HeadSHA != "m1" || merged.Branch != "main" || !reflect.DeepEqual(merged.RunIDs, []int64{5, 4}) {
		t.Fatalf("after merge = %+v", merged)
	}
	if latest.Kind != SectionLatestCommit || latest.HeadSHA != "c3" || !reflect.DeepEqual(latest.RunIDs, []int64{3}) {
		t.Fatalf("latest = %+v", latest)
	}
	if !reflect.DeepEqual(c.OlderRunIDs, []int64{2, 1}) || c.OlderCommits != 2 {
		t.Fatalf("older = %v, %d", c.OlderRunIDs, c.OlderCommits)
	}
}

func TestCommitsCollapseRepeats(t *testing.T) {
	in := Input{Runs: newestFirst(
		mk(1, 7, "schedule", "main", "s1", 1),
		mk(2, 7, "schedule", "main", "s1", 2),
		mk(3, 7, "schedule", "main", "s1", 3, concluded("failure")),
		mk(4, 8, "push", "main", "s1", 0),
		mk(5, 1, "push", "main", "s2", 10),
	), DefaultBranch: "main", Repository: "o/r"}
	changes := Group(in, Analyze(in), in.Runs)
	if len(changes) != 2 || changes[0].ID != "commit:s2" || changes[1].ID != "commit:s1" {
		t.Fatalf("changes = %+v", changes)
	}
	s1 := changes[1]
	section := s1.Sections[0]
	if s1.PullRequest != nil || s1.Status != github.CIFailed || section.Kind != SectionCommit ||
		!reflect.DeepEqual(section.RunIDs, []int64{3, 4}) || !reflect.DeepEqual(section.RepeatRunIDs, []int64{2, 1}) {
		t.Fatalf("s1 = %+v", s1)
	}
}

func TestAPullRequestNotReadYetStillFormsAChange(t *testing.T) {
	in := Input{Runs: []github.Run{mk(1, 1, "pull_request", "typo", "t1", 1, lists(300), titled("Fix typo"))},
		DefaultBranch: "main", Repository: "o/r", RepositoryURL: "https://github.com/o/r"}
	c := Group(in, Analyze(in), in.Runs)[0]
	if c.ID != "pr:300" || c.PullRequest.Title != "Fix typo" || c.PullRequest.State != "" ||
		c.PullRequest.HTMLURL != "https://github.com/o/r/pull/300" || c.PullRequest.HeadBranch != "typo" {
		t.Fatalf("change = %+v %+v", c, c.PullRequest)
	}
}

func TestMissingPullRequestsAreAskedForNewestFirst(t *testing.T) {
	in := Input{Runs: newestFirst(
		mk(1, 1, "pull_request", "retry", "c1", 1, lists(142)),
		mk(2, 1, "push", "main", "m1", 2),
		mk(3, 1, "pull_request", "patch-1", "f1", 3, fromRepository("fork/r")),
		mk(4, 1, "push", "main", "m0", 4),
	), Lookups: map[string][]int64{"commit:m0": {}}, DefaultBranch: "main", Repository: "o/r"}
	a := Analyze(in)
	want := []Need{
		{Kind: NeedHead, Key: "head:fork/r:patch-1", HeadOwner: "fork", Branch: "patch-1"},
		{Kind: NeedCommit, Key: "commit:m1", SHA: "m1"},
		{Kind: NeedPullRequest, Key: "pr:142", Number: 142},
	}
	if got := Missing(in, a, 10); !reflect.DeepEqual(got, want) {
		t.Fatalf("needs = %+v", got)
	}
	if got := Missing(in, a, 1); len(got) != 1 || got[0].Key != "head:fork/r:patch-1" {
		t.Fatalf("first need = %+v", got)
	}
}

func TestHintsNeedOverlapsAndAFileWithoutConcurrency(t *testing.T) {
	in := example()
	a := Analyze(in)
	ci := ".github/workflows/ci.yml"
	remote := []github.Workflow{{ID: 1, Path: ci}, {ID: 2, Path: ".github/workflows/deploy.yml"}}
	hints := Hints(a, remote, []LocalWorkflow{{Path: ci, Triggers: []string{"pull_request", "push"}}})
	if len(hints) != 1 || hints[0].WorkflowID != 1 || hints[0].Path != ci || hints[0].Runs != 2 || hints[0].OverlapMinutes != 15 ||
		!reflect.DeepEqual(hints[0].RunIDs, []int64{1, 2}) || !reflect.DeepEqual(hints[0].PullRequests, []int64{142}) {
		t.Fatalf("hints = %+v", hints)
	}
	for name, file := range map[string]LocalWorkflow{
		"has concurrency":         {Path: ci, Triggers: []string{"pull_request"}, Concurrency: true},
		"unreadable":              {Path: ci, Triggers: []string{"pull_request"}, ParseError: "invalid YAML"},
		"called only":             {Path: ci, Triggers: []string{"workflow_call"}},
		"not in the working tree": {Path: ".github/workflows/other.yml", Triggers: []string{"pull_request"}},
	} {
		if got := Hints(a, remote, []LocalWorkflow{file}); len(got) != 0 {
			t.Errorf("%s: hints = %+v", name, got)
		}
	}
	one := example()
	one.Runs = one.Runs[:len(one.Runs)-1] // without run 1, the oldest
	if got := Hints(Analyze(one), remote, []LocalWorkflow{{Path: ci, Triggers: []string{"pull_request"}}}); len(got) != 0 {
		t.Fatalf("one overlapping run made a hint: %+v", got)
	}
}
