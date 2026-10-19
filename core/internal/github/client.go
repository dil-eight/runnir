package github

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"time"
)

// Errors a caller can act on. Messages never contain the token.
var (
	ErrNoCredential = errors.New("not signed in to GitHub")
	ErrUnauthorized = errors.New("GitHub rejected the token")
	// ErrNotVisible covers 404 and permission 403: the app is not installed on
	// the repository, or the user cannot see it.
	ErrNotVisible  = errors.New("repository is not visible to Runnir")
	ErrUnavailable = errors.New("GitHub is unavailable")
	ErrInvalid     = errors.New("unexpected GitHub response")
)

// RateLimitError says when GitHub will accept requests again.
type RateLimitError struct{ Reset time.Time }

func (e *RateLimitError) Error() string { return "GitHub rate limit reached" }

const (
	defaultBaseURL   = "https://api.github.com"
	maxResponseBytes = 8 << 20
	maxRuns          = 100
)

// Client reads GitHub Actions data with the user's token. Safe for concurrent use.
type Client struct {
	credential *Credential
	baseURL    string
	http       *http.Client
	userAgent  string
}

// NewClient talks to api.github.com; baseURL overrides it for tests.
func NewClient(credential *Credential, baseURL, version string) *Client {
	if baseURL == "" {
		baseURL = defaultBaseURL
	}
	return &Client{
		credential: credential,
		baseURL:    baseURL,
		http:       &http.Client{Timeout: 20 * time.Second},
		userAgent:  "Runnir-Core/" + version,
	}
}

type Workflow struct {
	ID      int64
	Name    string
	Path    string
	State   string
	HTMLURL string
}

type Run struct {
	ID           int64
	WorkflowID   int64
	Name         string
	DisplayTitle string
	RunNumber    int64
	Event        string
	Status       string
	Conclusion   string
	Branch       string
	HeadSHA      string
	Actor        string
	HTMLURL      string
	CreatedAt    time.Time
	UpdatedAt    time.Time
}

type Step struct {
	Number     int64
	Name       string
	Status     string
	Conclusion string
}

type Job struct {
	ID          int64
	Name        string
	Status      string
	Conclusion  string
	StartedAt   time.Time
	CompletedAt time.Time
	HTMLURL     string
	Steps       []Step
}

// Workflows lists the repository's workflows (up to 300).
func (c *Client) Workflows(ctx context.Context, owner, name string) ([]Workflow, error) {
	var out []Workflow
	for page := 1; page <= 3; page++ {
		var body struct {
			TotalCount int `json:"total_count"`
			Workflows  []struct {
				ID      int64  `json:"id"`
				Name    string `json:"name"`
				Path    string `json:"path"`
				State   string `json:"state"`
				HTMLURL string `json:"html_url"`
			} `json:"workflows"`
		}
		query := url.Values{"per_page": {"100"}, "page": {strconv.Itoa(page)}}
		if err := c.get(ctx, repoPath(owner, name, "/actions/workflows"), query, &body); err != nil {
			return nil, err
		}
		for _, w := range body.Workflows {
			out = append(out, Workflow{ID: w.ID, Name: w.Name, Path: w.Path, State: w.State, HTMLURL: w.HTMLURL})
		}
		if len(body.Workflows) < 100 || len(out) >= body.TotalCount {
			break
		}
	}
	return out, nil
}

// Runs lists the newest workflow runs, optionally for one branch.
func (c *Client) Runs(ctx context.Context, owner, name, branch string, limit int) ([]Run, error) {
	if limit <= 0 || limit > maxRuns {
		limit = maxRuns
	}
	query := url.Values{"per_page": {strconv.Itoa(limit)}}
	if branch != "" {
		query.Set("branch", branch)
	}
	var body struct {
		WorkflowRuns []struct {
			ID           int64     `json:"id"`
			WorkflowID   int64     `json:"workflow_id"`
			Name         string    `json:"name"`
			DisplayTitle string    `json:"display_title"`
			RunNumber    int64     `json:"run_number"`
			Event        string    `json:"event"`
			Status       string    `json:"status"`
			Conclusion   *string   `json:"conclusion"`
			HeadBranch   string    `json:"head_branch"`
			HeadSHA      string    `json:"head_sha"`
			HTMLURL      string    `json:"html_url"`
			CreatedAt    time.Time `json:"created_at"`
			UpdatedAt    time.Time `json:"updated_at"`
			Actor        *struct {
				Login string `json:"login"`
			} `json:"actor"`
		} `json:"workflow_runs"`
	}
	if err := c.get(ctx, repoPath(owner, name, "/actions/runs"), query, &body); err != nil {
		return nil, err
	}
	runs := make([]Run, 0, len(body.WorkflowRuns))
	for _, r := range body.WorkflowRuns {
		run := Run{
			ID: r.ID, WorkflowID: r.WorkflowID, Name: r.Name, DisplayTitle: r.DisplayTitle, RunNumber: r.RunNumber,
			Event: r.Event, Status: r.Status, Branch: r.HeadBranch, HeadSHA: r.HeadSHA, HTMLURL: r.HTMLURL,
			CreatedAt: r.CreatedAt, UpdatedAt: r.UpdatedAt,
		}
		if r.Conclusion != nil {
			run.Conclusion = *r.Conclusion
		}
		if r.Actor != nil {
			run.Actor = r.Actor.Login
		}
		runs = append(runs, run)
	}
	return runs, nil
}

// Jobs lists the jobs of one run with their steps (up to 100 jobs).
func (c *Client) Jobs(ctx context.Context, owner, name string, runID int64) ([]Job, error) {
	if runID <= 0 {
		return nil, ErrInvalid
	}
	var body struct {
		Jobs []struct {
			ID          int64      `json:"id"`
			Name        string     `json:"name"`
			Status      string     `json:"status"`
			Conclusion  *string    `json:"conclusion"`
			StartedAt   *time.Time `json:"started_at"`
			CompletedAt *time.Time `json:"completed_at"`
			HTMLURL     string     `json:"html_url"`
			Steps       []struct {
				Number     int64   `json:"number"`
				Name       string  `json:"name"`
				Status     string  `json:"status"`
				Conclusion *string `json:"conclusion"`
			} `json:"steps"`
		} `json:"jobs"`
	}
	path := repoPath(owner, name, fmt.Sprintf("/actions/runs/%d/jobs", runID))
	if err := c.get(ctx, path, url.Values{"per_page": {"100"}}, &body); err != nil {
		return nil, err
	}
	jobs := make([]Job, 0, len(body.Jobs))
	for _, j := range body.Jobs {
		job := Job{ID: j.ID, Name: j.Name, Status: j.Status, HTMLURL: j.HTMLURL}
		if j.Conclusion != nil {
			job.Conclusion = *j.Conclusion
		}
		if j.StartedAt != nil {
			job.StartedAt = *j.StartedAt
		}
		if j.CompletedAt != nil {
			job.CompletedAt = *j.CompletedAt
		}
		for _, s := range j.Steps {
			step := Step{Number: s.Number, Name: s.Name, Status: s.Status}
			if s.Conclusion != nil {
				step.Conclusion = *s.Conclusion
			}
			job.Steps = append(job.Steps, step)
		}
		jobs = append(jobs, job)
	}
	return jobs, nil
}

func repoPath(owner, name, suffix string) string {
	return "/repos/" + url.PathEscape(owner) + "/" + url.PathEscape(name) + suffix
}

func (c *Client) get(ctx context.Context, path string, query url.Values, out any) error {
	token, ok := c.credential.Token()
	if !ok {
		return ErrNoCredential
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+path+"?"+query.Encode(), nil)
	if err != nil {
		return ErrInvalid
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("User-Agent", c.userAgent)

	response, err := c.http.Do(request)
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return ErrUnavailable
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes+1))
	if err != nil {
		return ErrUnavailable
	}
	if len(data) > maxResponseBytes {
		return ErrInvalid
	}
	switch status := response.StatusCode; {
	case status >= 200 && status < 300:
		if err := json.Unmarshal(data, out); err != nil {
			return ErrInvalid
		}
		return nil
	case status == http.StatusUnauthorized:
		return ErrUnauthorized
	case status == http.StatusTooManyRequests, status == http.StatusForbidden && isRateLimited(response):
		return &RateLimitError{Reset: rateLimitReset(response)}
	case status == http.StatusForbidden, status == http.StatusNotFound:
		return ErrNotVisible
	case status >= 500:
		return ErrUnavailable
	default:
		return ErrInvalid
	}
}

func isRateLimited(response *http.Response) bool {
	return response.Header.Get("X-RateLimit-Remaining") == "0" || response.Header.Get("Retry-After") != ""
}

func rateLimitReset(response *http.Response) time.Time {
	if after, err := strconv.Atoi(response.Header.Get("Retry-After")); err == nil {
		return time.Now().Add(time.Duration(after) * time.Second)
	}
	if reset, err := strconv.ParseInt(response.Header.Get("X-RateLimit-Reset"), 10, 64); err == nil {
		return time.Unix(reset, 0)
	}
	return time.Now().Add(time.Minute)
}
