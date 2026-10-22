package github

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// CIState sums up the GitHub Actions runs on a pull request's head commit.
type CIState int

const (
	// CINone: no workflow ran on the head commit.
	CINone CIState = iota
	CIRunning
	CIPassed
	CIFailed
	CICancelled
	// CIUnknown: the pull request's head could not be read.
	CIUnknown
)

// PullRequest is one of the signed-in user's pull requests.
type PullRequest struct {
	// "owner/name".
	Repository string
	Number     int64
	Title      string
	HTMLURL    string
	// "open", "closed" or "merged".
	State      string
	Draft      bool
	HeadBranch string
	UpdatedAt  time.Time
	ClosedAt   time.Time
	CI         CIState
	// Runs on the head commit, and of those failed and still running.
	CIRuns    int
	CIFailed  int
	CIRunning int
	// The run to look at: the first failed, else the first running.
	CIURL string
}

// PullRequests are the user's open pull requests and those closed since a
// time, newest first.
type PullRequests struct {
	Open   []PullRequest
	Closed []PullRequest
	// The head of some open pull request could not be read: the token
	// lacks Pull requests read, and their CI is CIUnknown.
	HeadsUnreadable bool
}

const (
	maxPullRequests = 50
	pullConcurrency = 4
)

// MyPullRequests lists the pull requests the signed-in user opened that are
// still open, and those closed since closedSince, through the search API;
// open ones carry the state of the GitHub Actions runs on their head commit.
func (c *Client) MyPullRequests(ctx context.Context, closedSince time.Time) (PullRequests, error) {
	open, err := c.searchPullRequests(ctx, "is:pr author:@me is:open archived:false")
	if err != nil {
		return PullRequests{}, err
	}
	closed, err := c.searchPullRequests(ctx, "is:pr author:@me is:closed closed:>="+closedSince.UTC().Format(time.RFC3339))
	if err != nil {
		return PullRequests{}, err
	}
	out := PullRequests{Open: open, Closed: closed}

	var wg sync.WaitGroup
	var mu sync.Mutex
	limit := make(chan struct{}, pullConcurrency)
	for i := range out.Open {
		wg.Add(1)
		go func(pr *PullRequest) {
			defer wg.Done()
			limit <- struct{}{}
			defer func() { <-limit }()
			if err := c.fillCI(ctx, pr); err != nil {
				pr.CI = CIUnknown
				if errors.Is(err, ErrPermissionMissing) || errors.Is(err, ErrNotVisible) {
					mu.Lock()
					out.HeadsUnreadable = true
					mu.Unlock()
				}
			}
		}(&out.Open[i])
	}
	wg.Wait()
	if err := ctx.Err(); err != nil {
		return PullRequests{}, err
	}
	return out, nil
}

func (c *Client) searchPullRequests(ctx context.Context, query string) ([]PullRequest, error) {
	var body struct {
		Items []struct {
			Number        int64      `json:"number"`
			Title         string     `json:"title"`
			HTMLURL       string     `json:"html_url"`
			State         string     `json:"state"`
			Draft         bool       `json:"draft"`
			UpdatedAt     *time.Time `json:"updated_at"`
			ClosedAt      *time.Time `json:"closed_at"`
			RepositoryURL string     `json:"repository_url"`
			PullRequest   *struct {
				MergedAt *time.Time `json:"merged_at"`
			} `json:"pull_request"`
		} `json:"items"`
	}
	values := url.Values{"q": {query}, "sort": {"updated"}, "order": {"desc"}, "per_page": {strconv.Itoa(maxPullRequests)}}
	if err := c.get(ctx, "/search/issues", values, &body); err != nil {
		return nil, err
	}
	var out []PullRequest
	for _, item := range body.Items {
		repository := repositoryFromAPIURL(item.RepositoryURL)
		if item.PullRequest == nil || !ValidRepository(repository) {
			continue
		}
		state := item.State
		if item.PullRequest.MergedAt != nil {
			state = "merged"
		}
		out = append(out, PullRequest{
			Repository: repository, Number: item.Number, Title: truncate(item.Title, 300), HTMLURL: item.HTMLURL,
			State: state, Draft: item.Draft, UpdatedAt: deref(item.UpdatedAt), ClosedAt: deref(item.ClosedAt),
		})
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].UpdatedAt.After(out[j].UpdatedAt) })
	return out, nil
}

// repositoryFromAPIURL takes "owner/name" from
// "https://api.github.com/repos/owner/name".
func repositoryFromAPIURL(value string) string {
	_, rest, found := strings.Cut(value, "/repos/")
	if !found {
		return ""
	}
	return strings.Trim(rest, "/")
}

// fillCI reads the pull request's head commit and the Actions runs on it.
func (c *Client) fillCI(ctx context.Context, pr *PullRequest) error {
	owner, name, _ := strings.Cut(pr.Repository, "/")
	var pull struct {
		Head struct {
			SHA string `json:"sha"`
			Ref string `json:"ref"`
		} `json:"head"`
	}
	if err := c.get(ctx, repoPath(owner, name, fmt.Sprintf("/pulls/%d", pr.Number)), nil, &pull); err != nil {
		return err
	}
	pr.HeadBranch = pull.Head.Ref
	var runs struct {
		WorkflowRuns []runJSON `json:"workflow_runs"`
	}
	query := url.Values{"head_sha": {pull.Head.SHA}, "per_page": {"50"}}
	if err := c.get(ctx, repoPath(owner, name, "/actions/runs"), query, &runs); err != nil {
		return err
	}
	list := make([]Run, 0, len(runs.WorkflowRuns))
	for _, r := range runs.WorkflowRuns {
		list = append(list, r.run())
	}
	summarizeCI(pr, list)
	return nil
}

// summarizeCI keeps the newest run of each workflow (a re-run replaces the
// one before) and sums them up: any failure fails, then anything still
// going is running, then all cancelled is cancelled, else passed.
func summarizeCI(pr *PullRequest, runs []Run) {
	latest := map[int64]Run{}
	for _, run := range runs {
		if current, ok := latest[run.WorkflowID]; !ok || run.CreatedAt.After(current.CreatedAt) {
			latest[run.WorkflowID] = run
		}
	}
	pr.CIRuns, pr.CIFailed, pr.CIRunning = len(latest), 0, 0
	pr.CI = CINone
	if len(latest) == 0 {
		return
	}
	ordered := make([]Run, 0, len(latest))
	for _, run := range latest {
		ordered = append(ordered, run)
	}
	sort.Slice(ordered, func(i, j int) bool { return ordered[i].CreatedAt.Before(ordered[j].CreatedAt) })
	cancelled := 0
	var failedURL, runningURL string
	for _, run := range ordered {
		switch {
		// A run waiting for a maintainer's approval (a fork's pull request)
		// has not run yet, so it counts as still going, not as a pass.
		case run.Status != "completed" || run.Conclusion == "action_required":
			pr.CIRunning++
			if runningURL == "" {
				runningURL = run.HTMLURL
			}
		case run.Conclusion == "failure" || run.Conclusion == "timed_out" || run.Conclusion == "startup_failure":
			pr.CIFailed++
			if failedURL == "" {
				failedURL = run.HTMLURL
			}
		case run.Conclusion == "cancelled":
			cancelled++
		}
	}
	switch {
	case pr.CIFailed > 0:
		pr.CI, pr.CIURL = CIFailed, failedURL
	case pr.CIRunning > 0:
		pr.CI, pr.CIURL = CIRunning, runningURL
	case cancelled == len(ordered):
		pr.CI = CICancelled
	default:
		pr.CI = CIPassed
	}
}
