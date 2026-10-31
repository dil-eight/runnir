package github

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Errors a caller can act on. Messages never contain the token.
var (
	ErrNoCredential = errors.New("not signed in to GitHub")
	ErrUnauthorized = errors.New("GitHub rejected the token")
	// ErrNotVisible covers 404 and permission 403: the app is not installed on
	// the repository, or the user cannot see it.
	ErrNotVisible = errors.New("repository is not visible to Runnir")
	// ErrPermissionMissing is GitHub's "Resource not accessible by
	// integration": the app is installed, but it or the user lacks the
	// permission for the call.
	ErrPermissionMissing = errors.New("Runnir Desktop or the user lacks the permission")
	ErrUnavailable       = errors.New("GitHub is unavailable")
	ErrInvalid           = errors.New("unexpected GitHub response")
	// ErrUnreachable is ErrUnavailable without any answer: the server could
	// not be reached or did not answer in time.
	ErrUnreachable = fmt.Errorf("%w: no answer", ErrUnavailable)
	// ErrNotModified is a conditional read's answer when nothing changed
	// (HTTP 304). GitHub does not count it against the rate limit.
	ErrNotModified = errors.New("not modified")
)

// RejectedError is GitHub refusing a change it understood (HTTP 422, 409, or
// 403 on a write), for example a workflow without a workflow_dispatch trigger
// at that ref, cancelling a run that already finished, or re-running a run
// older than a month.
type RejectedError struct{ Message string }

func (e *RejectedError) Error() string {
	if e.Message == "" {
		return "GitHub rejected the request"
	}
	return "GitHub rejected the request: " + e.Message
}

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

	mu sync.Mutex
	// rate is the core rate limit of the latest answer that said it.
	rate RateLimit
	// login is the user's login, read with the token of loginFor.
	login    string
	loginFor uint64
}

// RateLimit is what GitHub said of the core rate limit in an answer; Limit
// is 0 when no answer said it (an Enterprise server without rate limits).
type RateLimit struct {
	Remaining int
	Limit     int
	Reset     time.Time
}

// RateLimit returns the core rate limit GitHub reported last.
func (c *Client) RateLimit() RateLimit {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.rate
}

// noteRateLimit keeps the core rate limit an answer reports. Search and
// GraphQL have limits of their own and are not kept.
func (c *Client) noteRateLimit(header http.Header) {
	if resource := header.Get("X-RateLimit-Resource"); resource != "" && resource != "core" {
		return
	}
	limit, limitErr := strconv.Atoi(header.Get("X-RateLimit-Limit"))
	remaining, remainingErr := strconv.Atoi(header.Get("X-RateLimit-Remaining"))
	reset, resetErr := strconv.ParseInt(header.Get("X-RateLimit-Reset"), 10, 64)
	if limitErr != nil || remainingErr != nil || resetErr != nil || limit <= 0 {
		return
	}
	c.mu.Lock()
	c.rate = RateLimit{Remaining: remaining, Limit: limit, Reset: time.Unix(reset, 0)}
	c.mu.Unlock()
}

// Login is the signed-in user's login, read with GET /user once per token
// and kept until the token changes.
func (c *Client) Login(ctx context.Context) (string, error) {
	generation := c.credential.Generation()
	c.mu.Lock()
	if c.login != "" && c.loginFor == generation {
		login := c.login
		c.mu.Unlock()
		return login, nil
	}
	c.mu.Unlock()
	var user struct {
		Login string `json:"login"`
	}
	if err := c.get(ctx, "/user", nil, &user); err != nil {
		return "", err
	}
	if user.Login == "" {
		return "", ErrInvalid
	}
	c.mu.Lock()
	c.login, c.loginFor = user.Login, generation
	c.mu.Unlock()
	return user.Login, nil
}

// errCrossOriginRedirect ends a request GitHub redirected to another origin,
// which must not get the token.
var errCrossOriginRedirect = errors.New("redirect to another origin")

// sameOriginRedirects follows a redirect only on the API's own origin (a
// renamed repository moves within it), so a token never leaves its server.
func sameOriginRedirects(request *http.Request, via []*http.Request) error {
	first := via[0].URL
	if request.URL.Scheme != first.Scheme || !strings.EqualFold(request.URL.Host, first.Host) {
		return errCrossOriginRedirect
	}
	if len(via) >= 10 {
		return errors.New("stopped after 10 redirects")
	}
	return nil
}

// NewClient talks to api.github.com; baseURL overrides it for tests.
func NewClient(credential *Credential, baseURL, version string) *Client {
	if baseURL == "" {
		baseURL = defaultBaseURL
	}
	return &Client{
		credential: credential,
		// Paths are appended to it: "…/api/v3/" must not give "//repos".
		baseURL:   strings.TrimRight(baseURL, "/"),
		http:      &http.Client{Timeout: 20 * time.Second, CheckRedirect: sameOriginRedirects},
		userAgent: "Runnir-Core/" + version,
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
	RunAttempt   int64
	Event        string
	Status       string
	Conclusion   string
	Branch       string
	HeadSHA      string
	Actor        string
	HTMLURL      string
	CreatedAt    time.Time
	UpdatedAt    time.Time
	// "owner/name" the head commit came from, lowercased; a fork's differs
	// from the run's repository. Empty when GitHub does not say (a deleted fork).
	HeadRepository string
	// The first line of the head commit's message.
	CommitTitle string
	// Pull requests GitHub lists on the run whose base is the run's own
	// repository; in a fork GitHub also lists the upstream's, which are dropped.
	PullRequests []int64
	// WorkflowPath is the workflow file the run used, as GitHub names it
	// (".github/workflows/ci.yml"), without a ref; empty when GitHub does not
	// say. It is not stored with the cached runs.
	WorkflowPath string
}

// OtherRepository: head, a lowercased "owner/name" a run's or a pull
// request's head came from, is not repository (a fork's head). A head or a
// repository GitHub did not say counts as the same.
func OtherRepository(head, repository string) bool {
	return head != "" && repository != "" && head != repository
}

type Step struct {
	Number      int64
	Name        string
	Status      string
	Conclusion  string
	StartedAt   time.Time
	CompletedAt time.Time
}

type Job struct {
	ID int64
	// RunID is the workflow run the job belongs to, and RunAttempt the attempt
	// of it the job ran in; 0 when GitHub did not say.
	RunID       int64
	RunAttempt  int64
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
		var body workflowsPage
		query := url.Values{"per_page": {"100"}, "page": {strconv.Itoa(page)}}
		if err := c.get(ctx, repoPath(owner, name, "/actions/workflows"), query, &body); err != nil {
			return nil, err
		}
		out = append(out, body.list()...)
		if len(body.Workflows) < 100 || len(out) >= body.TotalCount {
			break
		}
	}
	return out, nil
}

type workflowsPage struct {
	TotalCount int `json:"total_count"`
	Workflows  []struct {
		ID      int64  `json:"id"`
		Name    string `json:"name"`
		Path    string `json:"path"`
		State   string `json:"state"`
		HTMLURL string `json:"html_url"`
	} `json:"workflows"`
}

func (p workflowsPage) list() []Workflow {
	out := make([]Workflow, 0, len(p.Workflows))
	for _, w := range p.Workflows {
		out = append(out, Workflow{ID: w.ID, Name: w.Name, Path: w.Path, State: w.State, HTMLURL: w.HTMLURL})
	}
	return out
}

// WorkflowsIfChanged reads the workflows like Workflows. The read is
// conditional only while the first page holds them all; for a repository
// with more than 100 the rest are read every time and the ETag is empty.
func (c *Client) WorkflowsIfChanged(ctx context.Context, owner, name, etag string) ([]Workflow, string, error) {
	var first workflowsPage
	path := repoPath(owner, name, "/actions/workflows")
	tag, err := c.getConditional(ctx, path, url.Values{"per_page": {"100"}, "page": {"1"}}, etag, &first)
	if err != nil {
		return nil, "", err
	}
	out := first.list()
	if len(first.Workflows) < 100 || len(out) >= first.TotalCount {
		return out, tag, nil
	}
	for page := 2; page <= 3; page++ {
		var next workflowsPage
		if err := c.get(ctx, path, url.Values{"per_page": {"100"}, "page": {strconv.Itoa(page)}}, &next); err != nil {
			return nil, "", err
		}
		out = append(out, next.list()...)
		if len(next.Workflows) < 100 || len(out) >= first.TotalCount {
			break
		}
	}
	return out, "", nil
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
		WorkflowRuns []runJSON `json:"workflow_runs"`
	}
	if err := c.get(ctx, repoPath(owner, name, "/actions/runs"), query, &body); err != nil {
		return nil, err
	}
	runs := make([]Run, 0, len(body.WorkflowRuns))
	for _, r := range body.WorkflowRuns {
		runs = append(runs, r.run(owner, name))
	}
	return runs, nil
}

// RunsQuery reads one page of up to 100 runs by the filters of a search
// (`actor`, `branch`, `event`, `status`, `head_sha`, `created`), newest first.
// GitHub answers at most 1000 results of a filtered search; a caller that
// goes deeper pages by `created` instead, as the older-runs read does.
func (c *Client) RunsQuery(ctx context.Context, owner, name string, filters url.Values) ([]Run, error) {
	query := url.Values{"per_page": {"100"}}
	for key, values := range filters {
		for _, value := range values {
			if value != "" {
				query.Set(key, value)
			}
		}
	}
	var body struct {
		WorkflowRuns []runJSON `json:"workflow_runs"`
	}
	if err := c.get(ctx, repoPath(owner, name, "/actions/runs"), query, &body); err != nil {
		return nil, err
	}
	runs := make([]Run, 0, len(body.WorkflowRuns))
	for _, r := range body.WorkflowRuns {
		runs = append(runs, r.run(owner, name))
	}
	return runs, nil
}

// RunsIfChanged reads the newest runs like Runs; with etag set GitHub
// answers ErrNotModified when they did not change. It returns the new ETag.
func (c *Client) RunsIfChanged(ctx context.Context, owner, name string, limit int, etag string) ([]Run, string, error) {
	return c.runsIfChanged(ctx, owner, name, url.Values{}, limit, etag)
}

// ActorRunsIfChanged is RunsIfChanged for the runs actor started.
func (c *Client) ActorRunsIfChanged(ctx context.Context, owner, name, actor string, limit int, etag string) ([]Run, string, error) {
	return c.runsIfChanged(ctx, owner, name, url.Values{"actor": {actor}}, limit, etag)
}

func (c *Client) runsIfChanged(ctx context.Context, owner, name string, query url.Values, limit int, etag string) ([]Run, string, error) {
	if limit <= 0 || limit > maxRuns {
		limit = maxRuns
	}
	query.Set("per_page", strconv.Itoa(limit))
	var body struct {
		WorkflowRuns []runJSON `json:"workflow_runs"`
	}
	tag, err := c.getConditional(ctx, repoPath(owner, name, "/actions/runs"), query, etag, &body)
	if err != nil {
		return nil, "", err
	}
	runs := make([]Run, 0, len(body.WorkflowRuns))
	for _, r := range body.WorkflowRuns {
		runs = append(runs, r.run(owner, name))
	}
	return runs, tag, nil
}

// OlderRuns reads up to limit runs created at or before `before`, newest
// first: a page of history older than what the caller holds. Runs created
// in the same second as `before` come again; callers drop the ones they have.
func (c *Client) OlderRuns(ctx context.Context, owner, name string, before time.Time, limit int) ([]Run, error) {
	if limit <= 0 || limit > maxRuns {
		limit = maxRuns
	}
	query := url.Values{"per_page": {strconv.Itoa(limit)}, "created": {"<=" + before.UTC().Format(time.RFC3339)}}
	var body struct {
		WorkflowRuns []runJSON `json:"workflow_runs"`
	}
	if err := c.get(ctx, repoPath(owner, name, "/actions/runs"), query, &body); err != nil {
		return nil, err
	}
	runs := make([]Run, 0, len(body.WorkflowRuns))
	for _, r := range body.WorkflowRuns {
		runs = append(runs, r.run(owner, name))
	}
	return runs, nil
}

// Run reads one workflow run.
func (c *Client) Run(ctx context.Context, owner, name string, runID int64) (Run, error) {
	if runID <= 0 {
		return Run{}, ErrInvalid
	}
	var body runJSON
	if err := c.get(ctx, repoPath(owner, name, fmt.Sprintf("/actions/runs/%d", runID)), nil, &body); err != nil {
		return Run{}, err
	}
	return body.run(owner, name), nil
}

type runJSON struct {
	ID           int64     `json:"id"`
	WorkflowID   int64     `json:"workflow_id"`
	Name         string    `json:"name"`
	DisplayTitle string    `json:"display_title"`
	RunNumber    int64     `json:"run_number"`
	RunAttempt   int64     `json:"run_attempt"`
	Event        string    `json:"event"`
	Status       string    `json:"status"`
	Conclusion   *string   `json:"conclusion"`
	HeadBranch   string    `json:"head_branch"`
	HeadSHA      string    `json:"head_sha"`
	HTMLURL      string    `json:"html_url"`
	Path         string    `json:"path"`
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
	Actor        *struct {
		Login string `json:"login"`
	} `json:"actor"`
	HeadRepository *struct {
		FullName string `json:"full_name"`
	} `json:"head_repository"`
	HeadCommit *struct {
		Message string `json:"message"`
	} `json:"head_commit"`
	PullRequests []struct {
		Number int64 `json:"number"`
		Base   struct {
			Repo struct {
				URL string `json:"url"`
			} `json:"repo"`
		} `json:"base"`
	} `json:"pull_requests"`
}

// run maps a run of owner/name.
func (r runJSON) run(owner, name string) Run {
	run := Run{
		ID: r.ID, WorkflowID: r.WorkflowID, Name: r.Name, DisplayTitle: r.DisplayTitle, RunNumber: r.RunNumber,
		RunAttempt: r.RunAttempt, Event: r.Event, Status: r.Status, Branch: r.HeadBranch, HeadSHA: r.HeadSHA,
		HTMLURL: r.HTMLURL, CreatedAt: r.CreatedAt, UpdatedAt: r.UpdatedAt,
	}
	// GitHub may add the ref the file was read at: ".github/workflows/ci.yml@refs/heads/main".
	run.WorkflowPath, _, _ = strings.Cut(r.Path, "@")
	if r.Conclusion != nil {
		run.Conclusion = *r.Conclusion
	}
	if r.Actor != nil {
		run.Actor = r.Actor.Login
	}
	if r.HeadRepository != nil {
		run.HeadRepository = strings.ToLower(r.HeadRepository.FullName)
	}
	if r.HeadCommit != nil {
		run.CommitTitle = commitTitle(r.HeadCommit.Message)
	}
	own := strings.ToLower("/repos/" + owner + "/" + name)
	for _, pr := range r.PullRequests {
		if pr.Number > 0 && strings.HasSuffix(strings.ToLower(pr.Base.Repo.URL), own) {
			run.PullRequests = append(run.PullRequests, pr.Number)
		}
	}
	return run
}

// commitTitle is a commit message's first line, at most 300 characters.
func commitTitle(message string) string {
	title, _, _ := strings.Cut(message, "\n")
	return truncate(strings.TrimSpace(title), 300)
}

// Jobs lists the jobs of one run's latest attempt with their steps, every
// page of them.
func (c *Client) Jobs(ctx context.Context, owner, name string, runID int64) ([]Job, error) {
	if runID <= 0 {
		return nil, ErrInvalid
	}
	path := repoPath(owner, name, fmt.Sprintf("/actions/runs/%d/jobs", runID))
	var jobs []Job
	for page := 1; ; page++ {
		var body struct {
			TotalCount int       `json:"total_count"`
			Jobs       []jobJSON `json:"jobs"`
		}
		if err := c.get(ctx, path, url.Values{"per_page": {"100"}, "page": {strconv.Itoa(page)}}, &body); err != nil {
			return nil, err
		}
		for _, j := range body.Jobs {
			jobs = append(jobs, j.job())
		}
		if len(body.Jobs) < 100 || len(jobs) >= body.TotalCount {
			return jobs, nil
		}
	}
}

// Job reads one job with its steps.
func (c *Client) Job(ctx context.Context, owner, name string, jobID int64) (Job, error) {
	if jobID <= 0 {
		return Job{}, ErrInvalid
	}
	var body jobJSON
	if err := c.get(ctx, repoPath(owner, name, fmt.Sprintf("/actions/jobs/%d", jobID)), nil, &body); err != nil {
		return Job{}, err
	}
	return body.job(), nil
}

type jobJSON struct {
	ID          int64      `json:"id"`
	RunID       int64      `json:"run_id"`
	RunAttempt  int64      `json:"run_attempt"`
	Name        string     `json:"name"`
	Status      string     `json:"status"`
	Conclusion  *string    `json:"conclusion"`
	StartedAt   *time.Time `json:"started_at"`
	CompletedAt *time.Time `json:"completed_at"`
	HTMLURL     string     `json:"html_url"`
	Steps       []struct {
		Number      int64      `json:"number"`
		Name        string     `json:"name"`
		Status      string     `json:"status"`
		Conclusion  *string    `json:"conclusion"`
		StartedAt   *time.Time `json:"started_at"`
		CompletedAt *time.Time `json:"completed_at"`
	} `json:"steps"`
}

func (j jobJSON) job() Job {
	job := Job{ID: j.ID, RunID: j.RunID, RunAttempt: j.RunAttempt, Name: j.Name, Status: j.Status, HTMLURL: j.HTMLURL,
		StartedAt: deref(j.StartedAt), CompletedAt: deref(j.CompletedAt)}
	if j.Conclusion != nil {
		job.Conclusion = *j.Conclusion
	}
	for _, s := range j.Steps {
		step := Step{Number: s.Number, Name: s.Name, Status: s.Status,
			StartedAt: deref(s.StartedAt), CompletedAt: deref(s.CompletedAt)}
		if s.Conclusion != nil {
			step.Conclusion = *s.Conclusion
		}
		job.Steps = append(job.Steps, step)
	}
	return job
}

func deref(t *time.Time) time.Time {
	if t == nil {
		return time.Time{}
	}
	return *t
}

func repoPath(owner, name, suffix string) string {
	return "/repos/" + url.PathEscape(owner) + "/" + url.PathEscape(name) + suffix
}

func (c *Client) get(ctx context.Context, path string, query url.Values, out any) error {
	data, _, err := c.send(ctx, http.MethodGet, path, query, nil, "application/vnd.github+json")
	if err != nil {
		return err
	}
	if err := json.Unmarshal(data, out); err != nil {
		return ErrInvalid
	}
	return nil
}

// send performs one request and maps GitHub's failure statuses. A 422, a 409,
// or a 403 on a change is returned as *RejectedError with GitHub's message,
// which never holds the token.
func (c *Client) send(ctx context.Context, method, path string, query url.Values, body []byte, accept string) ([]byte, int, error) {
	data, status, _, err := c.exchange(ctx, method, path, query, body, accept)
	return data, status, err
}

// getConditional reads JSON with If-None-Match and returns the new ETag.
func (c *Client) getConditional(ctx context.Context, path string, query url.Values, etag string, out any) (string, error) {
	var extra http.Header
	if etag != "" {
		extra = http.Header{"If-None-Match": {etag}}
	}
	data, _, header, err := c.exchangeWith(ctx, http.MethodGet, path, query, nil, "application/vnd.github+json", extra)
	if err != nil {
		return "", err
	}
	if err := json.Unmarshal(data, out); err != nil {
		return "", ErrInvalid
	}
	return header.Get("ETag"), nil
}

// exchange is send that also returns the response headers, for what GitHub
// says only there (a classic token's scopes, its expiry, SSO).
func (c *Client) exchange(ctx context.Context, method, path string, query url.Values, body []byte, accept string) ([]byte, int, http.Header, error) {
	return c.exchangeWith(ctx, method, path, query, body, accept, nil)
}

// exchangeWith is exchange with extra request headers, such as If-None-Match.
func (c *Client) exchangeWith(ctx context.Context, method, path string, query url.Values, body []byte, accept string, extra http.Header) ([]byte, int, http.Header, error) {
	token, ok := c.credential.Token()
	if !ok {
		return nil, 0, nil, ErrNoCredential
	}
	target := c.baseURL + path
	if len(query) > 0 {
		target += "?" + query.Encode()
	}
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	request, err := http.NewRequestWithContext(ctx, method, target, reader)
	if err != nil {
		return nil, 0, nil, ErrInvalid
	}
	request.Header.Set("Accept", accept)
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("User-Agent", c.userAgent)
	for name, values := range extra {
		for _, value := range values {
			request.Header.Add(name, value)
		}
	}
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}

	response, err := c.http.Do(request)
	if err != nil {
		if ctx.Err() != nil {
			return nil, 0, nil, ctx.Err()
		}
		return nil, 0, nil, ErrUnreachable
	}
	defer response.Body.Close()
	c.noteRateLimit(response.Header)
	data, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes+1))
	if err != nil {
		return nil, response.StatusCode, response.Header, ErrUnavailable
	}
	if len(data) > maxResponseBytes {
		return nil, response.StatusCode, response.Header, ErrInvalid
	}
	switch status := response.StatusCode; {
	case status >= 200 && status < 300:
		return data, status, response.Header, nil
	case status == http.StatusUnauthorized:
		return nil, status, response.Header, ErrUnauthorized
	case status == http.StatusTooManyRequests, status == http.StatusForbidden && isRateLimited(response):
		return nil, status, response.Header, &RateLimitError{Reset: rateLimitReset(response)}
	case status == http.StatusForbidden && missingAccess(data):
		return nil, status, response.Header, ErrPermissionMissing
	case status == http.StatusForbidden && method != http.MethodGet:
		// A refused change carries GitHub's reason, for example a run too
		// old to re-run or an organization policy. Refused reads stay
		// NOT_VISIBLE.
		return nil, status, response.Header, &RejectedError{Message: problemMessage(data)}
	case status == http.StatusForbidden, status == http.StatusNotFound:
		return nil, status, response.Header, ErrNotVisible
	case status == http.StatusUnprocessableEntity, status == http.StatusConflict:
		return nil, status, response.Header, &RejectedError{Message: problemMessage(data)}
	case status >= 500:
		return nil, status, response.Header, ErrUnavailable
	case status == http.StatusNotModified:
		return nil, status, response.Header, ErrNotModified
	default:
		return nil, status, response.Header, ErrInvalid
	}
}

func problemMessage(data []byte) string {
	var problem struct {
		Message string `json:"message"`
	}
	_ = json.Unmarshal(data, &problem)
	return problem.Message
}

// missingAccess recognizes GitHub's answer when the app or the user lacks
// the permission for a call on a repository the app is installed on.
func missingAccess(data []byte) bool {
	message := strings.ToLower(problemMessage(data))
	return strings.Contains(message, "not accessible by integration") || strings.Contains(message, "not accessible by personal access token")
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
