package localrun

import "encoding/json"

// noCommit is the "before" of a push whose previous commit is unknown, as
// GitHub sends for a new branch.
const noCommit = "0000000000000000000000000000000000000000"

// EventContext is what a lane's event payload says, so that github.ref,
// base_ref, head_ref and github.event.* in the lane are the scenario's.
type EventContext struct {
	Event string
	// Ref is the full ref of a push or a manual start: refs/heads/main,
	// refs/tags/v1.0.0.
	Ref string
	// Branch and HeadSHA are the change's: the branch checked out, its commit.
	Branch, HeadSHA string
	// Before is the commit a push moves from; empty when unknown.
	Before string
	// Base is a pull request's base branch; PullRequest its number, 0
	// without one.
	Base        string
	PullRequest int64
	Draft       bool
	// Tag is a release's tag.
	Tag string
	// Source is the workflow a workflow_run follows, by name, and
	// SourceEvent the event that started it.
	Source, SourceEvent string
	DefaultBranch       string
}

// Payload is the JSON act reads with --eventpath.
func Payload(c EventContext) ([]byte, error) {
	event := map[string]any{"repository": map[string]any{"default_branch": c.DefaultBranch}}
	switch c.Event {
	case "pull_request", "pull_request_target":
		event["action"] = "synchronize"
		event["number"] = c.PullRequest
		event["pull_request"] = map[string]any{
			"number": c.PullRequest, "draft": c.Draft,
			"head": map[string]any{"ref": c.Branch, "sha": c.HeadSHA},
			"base": map[string]any{"ref": c.Base},
		}
	case "push":
		before := c.Before
		if before == "" {
			before = noCommit
		}
		event["ref"], event["before"], event["after"] = c.Ref, before, c.HeadSHA
		event["head_commit"] = map[string]any{"id": c.HeadSHA}
	case "release":
		event["action"] = "published"
		event["release"] = map[string]any{"tag_name": c.Tag}
	case "workflow_dispatch":
		// Inputs left out take their defaults.
		event["ref"] = c.Ref
		event["inputs"] = map[string]any{}
	case "workflow_run":
		event["action"] = "completed"
		event["workflow_run"] = map[string]any{
			"name": c.Source, "event": c.SourceEvent, "conclusion": "success", "head_branch": c.Branch, "head_sha": c.HeadSHA,
		}
	}
	return json.Marshal(event)
}
