package github

import (
	"context"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// RepositoryPullRequest is a pull request of the repository a workspace
// syncs, with what linking runs to it needs.
type RepositoryPullRequest struct {
	Number int64
	Title  string
	// "open" or "closed"; MergedAt tells a merge apart.
	State   string
	Draft   bool
	Author  string
	HTMLURL string
	HeadRef string
	HeadSHA string
	// Lowercased "owner/name" of the head branch's repository; a fork's
	// differs. Empty when the fork was deleted.
	HeadRepository string
	BaseRef        string
	// The commit the merge created; only set once merged (before that
	// GitHub reports a test merge, which no run is on).
	MergeCommitSHA string
	CreatedAt      time.Time
	UpdatedAt      time.Time
	ClosedAt       time.Time
	MergedAt       time.Time
}

// pullsPerPage is how many of the most recently updated pull requests one
// sync pass reads.
const pullsPerPage = 50

type pullJSON struct {
	Number  int64  `json:"number"`
	Title   string `json:"title"`
	State   string `json:"state"`
	Draft   bool   `json:"draft"`
	HTMLURL string `json:"html_url"`
	User    *struct {
		Login string `json:"login"`
	} `json:"user"`
	Head struct {
		Ref  string `json:"ref"`
		SHA  string `json:"sha"`
		Repo *struct {
			FullName string `json:"full_name"`
		} `json:"repo"`
	} `json:"head"`
	Base struct {
		Ref string `json:"ref"`
	} `json:"base"`
	MergeCommitSHA *string    `json:"merge_commit_sha"`
	CreatedAt      *time.Time `json:"created_at"`
	UpdatedAt      *time.Time `json:"updated_at"`
	ClosedAt       *time.Time `json:"closed_at"`
	MergedAt       *time.Time `json:"merged_at"`
}

func (p pullJSON) pull() RepositoryPullRequest {
	out := RepositoryPullRequest{
		Number: p.Number, Title: truncate(p.Title, 300), State: p.State, Draft: p.Draft, HTMLURL: p.HTMLURL,
		HeadRef: p.Head.Ref, HeadSHA: p.Head.SHA, BaseRef: p.Base.Ref,
		CreatedAt: deref(p.CreatedAt), UpdatedAt: deref(p.UpdatedAt), ClosedAt: deref(p.ClosedAt), MergedAt: deref(p.MergedAt),
	}
	if p.User != nil {
		out.Author = p.User.Login
	}
	if p.Head.Repo != nil {
		out.HeadRepository = strings.ToLower(p.Head.Repo.FullName)
	}
	if p.MergedAt != nil && p.MergeCommitSHA != nil {
		out.MergeCommitSHA = *p.MergeCommitSHA
	}
	return out
}

func pulls(list []pullJSON) []RepositoryPullRequest {
	out := make([]RepositoryPullRequest, 0, len(list))
	for _, p := range list {
		if p.Number > 0 {
			out = append(out, p.pull())
		}
	}
	return out
}

// PullRequestsIfChanged reads the 50 most recently updated pull requests,
// open and closed; with etag set GitHub answers ErrNotModified when they did
// not change. It returns the new ETag.
func (c *Client) PullRequestsIfChanged(ctx context.Context, owner, name, etag string) ([]RepositoryPullRequest, string, error) {
	query := url.Values{"state": {"all"}, "sort": {"updated"}, "direction": {"desc"}, "per_page": {strconv.Itoa(pullsPerPage)}}
	var body []pullJSON
	tag, err := c.getConditional(ctx, repoPath(owner, name, "/pulls"), query, etag, &body)
	if err != nil {
		return nil, "", err
	}
	return pulls(body), tag, nil
}

// RepositoryPull reads one pull request.
func (c *Client) RepositoryPull(ctx context.Context, owner, name string, number int64) (RepositoryPullRequest, error) {
	if number <= 0 {
		return RepositoryPullRequest{}, ErrInvalid
	}
	var body pullJSON
	if err := c.get(ctx, repoPath(owner, name, fmt.Sprintf("/pulls/%d", number)), nil, &body); err != nil {
		return RepositoryPullRequest{}, err
	}
	return body.pull(), nil
}

// CommitPullRequests lists the pull requests a commit belongs to; for a
// merge commit on the default branch, the pull request it merged.
func (c *Client) CommitPullRequests(ctx context.Context, owner, name, sha string) ([]RepositoryPullRequest, error) {
	if sha == "" {
		return nil, ErrInvalid
	}
	var body []pullJSON
	if err := c.get(ctx, repoPath(owner, name, "/commits/"+url.PathEscape(sha)+"/pulls"), url.Values{"per_page": {"10"}}, &body); err != nil {
		return nil, err
	}
	return pulls(body), nil
}

// HeadPullRequests lists the pull requests, open or closed, whose head is
// branch in headOwner's fork.
func (c *Client) HeadPullRequests(ctx context.Context, owner, name, headOwner, branch string) ([]RepositoryPullRequest, error) {
	if headOwner == "" || branch == "" {
		return nil, ErrInvalid
	}
	query := url.Values{"head": {headOwner + ":" + branch}, "state": {"all"}, "per_page": {"10"}}
	var body []pullJSON
	if err := c.get(ctx, repoPath(owner, name, "/pulls"), query, &body); err != nil {
		return nil, err
	}
	return pulls(body), nil
}
