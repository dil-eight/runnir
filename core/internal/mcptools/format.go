package mcptools

import (
	"strings"
	"time"

	"google.golang.org/protobuf/types/known/timestamppb"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

// stamp is a time in RFC 3339, empty for none.
func stamp(t *timestamppb.Timestamp) string {
	if t == nil || (t.GetSeconds() == 0 && t.GetNanos() == 0) {
		return ""
	}
	return t.AsTime().UTC().Format(time.RFC3339)
}

func stampOf(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}

// gitHubProblem says why GitHub did not answer; empty when it did.
func gitHubProblem(s *corev1.GitHubStatus) string {
	switch s.GetAccess() {
	case corev1.GithubAccess_GITHUB_ACCESS_UNSPECIFIED, corev1.GithubAccess_GITHUB_ACCESS_OK:
		return ""
	case corev1.GithubAccess_GITHUB_ACCESS_NO_REMOTE:
		return "This workspace's origin is not on GitHub."
	case corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT:
		return "Runnir is not signed in to GitHub. Sign in in Runnir first."
	case corev1.GithubAccess_GITHUB_ACCESS_TOKEN_REJECTED:
		return "GitHub refused Runnir's sign-in. Sign in again in Runnir."
	case corev1.GithubAccess_GITHUB_ACCESS_NOT_VISIBLE:
		return "GitHub does not show this repository to Runnir: the Runnir app is not installed on it, or the account cannot see it."
	case corev1.GithubAccess_GITHUB_ACCESS_RATE_LIMITED:
		if at := stamp(s.GetRetryAfter()); at != "" {
			return "GitHub's rate limit is reached; it takes requests again at " + at + "."
		}
		return "GitHub's rate limit is reached; try again later."
	case corev1.GithubAccess_GITHUB_ACCESS_PERMISSION_MISSING:
		return "GitHub refused: the Runnir app or the signed-in account lacks a permission for this."
	default:
		return "GitHub could not be reached."
	}
}

// run is a GitHub run as the tools return it.
type run struct {
	ID          int64  `json:"id"`
	Number      int64  `json:"number"`
	Workflow    string `json:"workflow"`
	Title       string `json:"title"`
	Event       string `json:"event"`
	Branch      string `json:"branch"`
	Commit      string `json:"commit"`
	CommitTitle string `json:"commit_title,omitempty"`
	Status      string `json:"status"`
	Conclusion  string `json:"conclusion,omitempty"`
	Group       string `json:"status_group,omitempty"`
	Actor       string `json:"actor,omitempty"`
	Attempt     int64  `json:"attempt"`
	CreatedAt   string `json:"created_at,omitempty"`
	UpdatedAt   string `json:"updated_at,omitempty"`
	URL         string `json:"url,omitempty"`
	// StartedFromRunnir: Runnir on this Mac dispatched or re-ran it.
	StartedFromRunnir bool `json:"started_from_runnir,omitempty"`
}

func runOf(r *corev1.WorkflowRun) run {
	sha := r.GetHeadSha()
	if len(sha) > 7 {
		sha = sha[:7]
	}
	return run{
		ID: r.GetId(), Number: r.GetRunNumber(), Workflow: r.GetName(), Title: clip(r.GetDisplayTitle(), 300), Event: r.GetEvent(),
		Branch: r.GetBranch(), Commit: sha, CommitTitle: clip(r.GetCommitTitle(), 300), Status: r.GetStatus(), Conclusion: r.GetConclusion(),
		Group: groupName(r.GetStatusGroup()), Actor: r.GetActor(), Attempt: r.GetRunAttempt(),
		CreatedAt: stamp(r.GetCreatedAt()), UpdatedAt: stamp(r.GetUpdatedAt()), URL: r.GetHtmlUrl(),
		StartedFromRunnir: len(r.GetRunnirStarts()) > 0,
	}
}

func groupName(g corev1.RunStatusGroup) string {
	return lowerName(g.String(), "RUN_STATUS_GROUP_")
}

// lowerName is an enum's name without its prefix, lower-cased; empty for
// UNSPECIFIED.
func lowerName(name, prefix string) string {
	name = strings.ToLower(strings.TrimPrefix(name, prefix))
	if name == "unspecified" {
		return ""
	}
	return name
}

// scenarioKind reads a scenario's name; false for an unknown one.
func scenarioKind(name string) (corev1.ScenarioKind, bool) {
	switch name {
	case "pull_request":
		return corev1.ScenarioKind_SCENARIO_KIND_PULL_REQUEST, true
	case "push":
		return corev1.ScenarioKind_SCENARIO_KIND_PUSH, true
	case "merge":
		return corev1.ScenarioKind_SCENARIO_KIND_MERGE, true
	case "tag":
		return corev1.ScenarioKind_SCENARIO_KIND_TAG, true
	case "manual":
		return corev1.ScenarioKind_SCENARIO_KIND_MANUAL, true
	case "schedule":
		return corev1.ScenarioKind_SCENARIO_KIND_SCHEDULE, true
	}
	return 0, false
}

// scenarioArg is the scenario a call asks for; nil for the branch's own.
func scenarioArg(kind, target *string) (*corev1.Scenario, error) {
	if kind == nil || *kind == "" {
		if target != nil && *target != "" {
			return nil, refuse("Give a scenario with target.")
		}
		return nil, nil
	}
	k, ok := scenarioKind(*kind)
	if !ok {
		return nil, refuse("scenario must be pull_request, push, merge, tag, manual or schedule.")
	}
	s := &corev1.Scenario{Kind: k}
	if target != nil {
		s.Target = *target
	}
	return s, nil
}

type scenario struct {
	Kind   string `json:"kind"`
	Target string `json:"target,omitempty"`
	Title  string `json:"title"`
}

func scenarioOf(s *corev1.Scenario) *scenario {
	if s == nil {
		return nil
	}
	return &scenario{Kind: lowerName(s.GetKind().String(), "SCENARIO_KIND_"), Target: s.GetTarget(), Title: s.GetTitle()}
}

func scenariosOf(list []*corev1.Scenario) []scenario {
	out := []scenario{}
	for _, s := range list {
		out = append(out, *scenarioOf(s))
	}
	return out
}
