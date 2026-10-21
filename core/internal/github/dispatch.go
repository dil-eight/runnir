package github

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

const maxWorkflowFileBytes = 1 << 20

// Refs are the branches and tags a workflow can be dispatched on.
type Refs struct {
	DefaultBranch string
	Branches      []string
	Tags          []string
}

// Repository is what the app shows about a linked GitHub repository.
type Repository struct {
	FullName      string
	Visibility    string
	DefaultBranch string
	HTMLURL       string
	// The signed-in user can push to it.
	CanPush bool
}

// Repository reads one repository; NOT_VISIBLE when the token cannot see it.
func (c *Client) Repository(ctx context.Context, owner, name string) (Repository, error) {
	var body struct {
		FullName      string `json:"full_name"`
		Visibility    string `json:"visibility"`
		Private       bool   `json:"private"`
		DefaultBranch string `json:"default_branch"`
		HTMLURL       string `json:"html_url"`
		Permissions   struct {
			Push bool `json:"push"`
		} `json:"permissions"`
	}
	if err := c.get(ctx, repoPath(owner, name, ""), nil, &body); err != nil {
		return Repository{}, err
	}
	visibility := body.Visibility
	if visibility == "" {
		visibility = "public"
		if body.Private {
			visibility = "private"
		}
	}
	return Repository{FullName: body.FullName, Visibility: visibility, DefaultBranch: body.DefaultBranch, HTMLURL: body.HTMLURL,
		CanPush: body.Permissions.Push}, nil
}

// Refs lists up to 300 branches and 100 tags, plus the default branch.
func (c *Client) Refs(ctx context.Context, owner, name string) (Refs, error) {
	var repository struct {
		DefaultBranch string `json:"default_branch"`
	}
	if err := c.get(ctx, repoPath(owner, name, ""), nil, &repository); err != nil {
		return Refs{}, err
	}
	refs := Refs{DefaultBranch: repository.DefaultBranch}
	for page := 1; page <= 3; page++ {
		var branches []struct {
			Name string `json:"name"`
		}
		query := url.Values{"per_page": {"100"}, "page": {strconv.Itoa(page)}}
		if err := c.get(ctx, repoPath(owner, name, "/branches"), query, &branches); err != nil {
			return Refs{}, err
		}
		for _, b := range branches {
			refs.Branches = append(refs.Branches, b.Name)
		}
		if len(branches) < 100 {
			break
		}
	}
	var tags []struct {
		Name string `json:"name"`
	}
	if err := c.get(ctx, repoPath(owner, name, "/tags"), url.Values{"per_page": {"100"}}, &tags); err != nil {
		return Refs{}, err
	}
	for _, t := range tags {
		refs.Tags = append(refs.Tags, t.Name)
	}
	return refs, nil
}

// WorkflowPath returns the file path of a workflow by id, so a dispatch can be
// checked against the definition it will actually run.
func (c *Client) WorkflowPath(ctx context.Context, owner, name string, workflowID int64) (string, error) {
	var workflow struct {
		Path string `json:"path"`
	}
	if err := c.get(ctx, repoPath(owner, name, fmt.Sprintf("/actions/workflows/%d", workflowID)), nil, &workflow); err != nil {
		return "", err
	}
	return workflow.Path, nil
}

// File returns a file's bytes at a ref, at most 1 MiB.
func (c *Client) File(ctx context.Context, owner, name, path, ref string) ([]byte, error) {
	if path == "" || strings.Contains(path, "..") {
		return nil, ErrInvalid
	}
	escaped := make([]string, 0, 4)
	for _, part := range strings.Split(path, "/") {
		escaped = append(escaped, url.PathEscape(part))
	}
	data, _, err := c.send(ctx, http.MethodGet, repoPath(owner, name, "/contents/"+strings.Join(escaped, "/")),
		url.Values{"ref": {ref}}, nil, "application/vnd.github.raw+json")
	if err != nil {
		return nil, err
	}
	if len(data) > maxWorkflowFileBytes {
		return nil, ErrInvalid
	}
	return data, nil
}

// Dispatch asks GitHub to run a workflow_dispatch workflow. GitHub answers
// 204 without the run, or 200 with run details on newer API versions; the
// returned run id is 0 when GitHub did not say. It is never retried here: a
// lost answer would otherwise start the workflow twice.
func (c *Client) Dispatch(ctx context.Context, owner, name string, workflowID int64, ref string, inputs map[string]string) (int64, error) {
	body, err := json.Marshal(struct {
		Ref    string            `json:"ref"`
		Inputs map[string]string `json:"inputs,omitempty"`
	}{Ref: ref, Inputs: inputs})
	if err != nil {
		return 0, ErrInvalid
	}
	data, status, err := c.send(ctx, http.MethodPost,
		repoPath(owner, name, fmt.Sprintf("/actions/workflows/%d/dispatches", workflowID)), nil, body, "application/vnd.github+json")
	if err != nil {
		return 0, err
	}
	if status == http.StatusOK && len(data) > 0 {
		var details struct {
			WorkflowRunID int64 `json:"workflow_run_id"`
		}
		if json.Unmarshal(data, &details) == nil {
			return details.WorkflowRunID, nil
		}
	}
	return 0, nil
}
