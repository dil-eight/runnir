package mcptools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/mcpbridge"
)

// Core is the app's Core as the tools use it, in process: its RPCs and two
// reads that have no RPC.
type Core interface {
	ListWorkflows(context.Context, *corev1.ListWorkflowsRequest) (*corev1.ListWorkflowsResponse, error)
	ValidateWorkflows(context.Context, *corev1.ValidateWorkflowsRequest) (*corev1.ValidateWorkflowsResponse, error)
	GetFlow(context.Context, *corev1.GetFlowRequest) (*corev1.GetFlowResponse, error)
	GetWorkspaceActivity(context.Context, *corev1.GetWorkspaceActivityRequest) (*corev1.WorkspaceActivity, error)
	RefreshWorkspaceActivity(context.Context, *corev1.RefreshWorkspaceActivityRequest) (*corev1.WorkspaceActivity, error)
	SearchRuns(context.Context, *corev1.SearchRunsRequest) (*corev1.SearchRunsResponse, error)
	ListRunJobs(context.Context, *corev1.ListRunJobsRequest) (*corev1.ListRunJobsResponse, error)
	GetRunWorkflow(context.Context, *corev1.GetRunWorkflowRequest) (*corev1.GetRunWorkflowResponse, error)
	GetJobLog(context.Context, *corev1.GetJobLogRequest) (*corev1.GetJobLogResponse, error)
	ListPullRequests(context.Context, *corev1.ListPullRequestsRequest) (*corev1.ListPullRequestsResponse, error)
	GetGitHubOrigins(context.Context, *corev1.GetGitHubOriginsRequest) (*corev1.GetGitHubOriginsResponse, error)
	ListGitHubWorkflows(context.Context, *corev1.ListGitHubWorkflowsRequest) (*corev1.ListGitHubWorkflowsResponse, error)
	PrepareWorkflowDispatch(context.Context, *corev1.PrepareWorkflowDispatchRequest) (*corev1.PrepareWorkflowDispatchResponse, error)
	ConfirmWorkflowDispatch(context.Context, *corev1.ConfirmWorkflowDispatchRequest) (*corev1.ConfirmWorkflowDispatchResponse, error)
	PrepareRunAction(context.Context, *corev1.PrepareRunActionRequest) (*corev1.PrepareRunActionResponse, error)
	ConfirmRunAction(context.Context, *corev1.ConfirmRunActionRequest) (*corev1.ConfirmRunActionResponse, error)
	GetLocalRunOutput(context.Context, *corev1.GetLocalRunOutputRequest) (*corev1.GetLocalRunOutputResponse, error)
	CancelExecution(context.Context, *corev1.CancelExecutionRequest) (*corev1.CancelExecutionResponse, error)

	// WorkflowSource reads a workflow file of an open repository as on disk.
	WorkflowSource(repositoryID, path string) ([]byte, error)
	// LocalRuns lists a repository's local runs, newest first, at most limit.
	LocalRuns(ctx context.Context, repositoryID string, limit int) ([]LocalRunSummary, error)
}

// LocalRunSummary is a local run as the workspace's history and the Core's
// memory know it.
type LocalRunSummary struct {
	ExecutionID string
	Scenario    string
	Workflows   []string
	State       string
	Message     string
	StartedAt   time.Time
	FinishedAt  time.Time
	// StartedBy is the MCP client that started it, while the Core holds it.
	StartedBy string
}

// App is what the tools ask the app (mcpbridge.Broker).
type App interface {
	Workspaces(ctx context.Context, client string) (*corev1.McpWorkspaces, error)
	Open(ctx context.Context, client, repository string, action bool) (*corev1.McpOpenedWorkspace, error)
	Start(ctx context.Context, client, repository string, start *corev1.McpLocalRunStart) (*corev1.McpLocalRunStarted, error)
	List(ctx context.Context, client, repository string) (*corev1.McpValueSets, error)
	Set(ctx context.Context, request *corev1.McpRequest) (*corev1.McpSavedValues, error)
}

// Result is a tool's answer: text for the model, structured content and
// whether it is an error.
type Result struct {
	Text       string
	Structured any
	IsError    bool
}

// Tools runs the tools. Safe for concurrent use.
type Tools struct {
	core Core
	app  App
	// poll is how often a wait reads a local run again.
	poll   time.Duration
	logMu  sync.Mutex
	log    io.Writer
	handle map[string]handler
}

// call is one tool call as a handler sees it; note adds to its log line.
type call struct {
	ctx    context.Context
	client string
	args   json.RawMessage
	notes  []string
}

func (c *call) note(format string, args ...any) {
	c.notes = append(c.notes, fmt.Sprintf(format, args...))
}

type handler func(t *Tools, c *call) (Result, error)

// New runs tools with the Core's services and the app's answers, and writes
// one line per call to log, which may be nil.
func New(core Core, app App, log io.Writer) *Tools {
	t := &Tools{core: core, app: app, log: log, poll: 500 * time.Millisecond}
	t.handle = map[string]handler{
		ListWorkspaces: (*Tools).listWorkspaces, ListWorkflows: (*Tools).listWorkflows, GetWorkflow: (*Tools).getWorkflow,
		PlanScenario: (*Tools).planScenario, ListRuns: (*Tools).listRuns, GetRun: (*Tools).getRun, GetJobLog: (*Tools).getJobLog,
		ListPullRequests: (*Tools).listPullRequests, ListLocalRuns: (*Tools).listLocalRuns, GetLocalRun: (*Tools).getLocalRun,
		ListValueSets: (*Tools).listValueSets, StartLocalRun: (*Tools).startLocalRun, StopLocalRun: (*Tools).stopLocalRun,
		DispatchWorkflow: (*Tools).dispatchWorkflow, CancelRun: (*Tools).cancelRun, RerunRun: (*Tools).rerunRun, SetValues: (*Tools).setValues,
	}
	return t
}

// Known reports a tool name of the catalog.
func Known(name string) bool {
	for _, tool := range Catalog {
		if tool.Name == name {
			return true
		}
	}
	return false
}

// Call runs one tool. Refusals and failures are results with IsError.
func (t *Tools) Call(ctx context.Context, client, name string, arguments json.RawMessage) Result {
	h := t.handle[name]
	if h == nil {
		return failure("Runnir has no tool " + name + ".")
	}
	c := &call{ctx: ctx, client: client, args: arguments}
	result, err := h(t, c)
	if err != nil {
		result = failure(message(err))
	}
	t.record(name, c, result)
	return result
}

// failure is a refusal or an error, said to the client as it is.
func failure(text string) Result { return Result{Text: text, IsError: true} }

// refusal is a reason a tool did nothing, said as it is.
type refusal string

func (r refusal) Error() string { return string(r) }

func refuse(format string, args ...any) error { return refusal(fmt.Sprintf(format, args...)) }

// message says why a call failed: the app's refusal, Runnir's own words, or
// the Core's status message as a sentence.
func message(err error) string {
	var r refusal
	var app mcpbridge.Refusal
	switch {
	case errors.As(err, &r):
		return string(r)
	case errors.As(err, &app):
		return string(app)
	case errors.Is(err, mcpbridge.ErrNoApp), errors.Is(err, mcpbridge.ErrBusy), errors.Is(err, mcpbridge.ErrTimeout),
		errors.Is(err, mcpbridge.ErrSetTimeout):
		return err.Error()
	case errors.Is(err, context.Canceled):
		return "The call was cancelled."
	case errors.Is(err, context.DeadlineExceeded):
		return "Runnir did not answer in time."
	}
	if st, ok := status.FromError(err); ok && st.Code() != codes.Unknown && st.Message() != "" {
		return sentence(st.Message())
	}
	return "Runnir could not do it: " + sentence(err.Error())
}

// sentence starts with a capital and ends with a full stop.
func sentence(text string) string {
	text = strings.TrimSpace(text)
	if text == "" {
		return text
	}
	text = strings.ToUpper(text[:1]) + text[1:]
	if !strings.HasSuffix(text, ".") && !strings.HasSuffix(text, "?") && !strings.HasSuffix(text, "!") {
		text += "."
	}
	return text
}

// record writes one line per call: the tool, the client, what it acted on
// and the outcome. Never a value.
func (t *Tools) record(name string, c *call, result Result) {
	if t.log == nil {
		return
	}
	line := "mcp: " + strings.TrimPrefix(name, "runnir_")
	if c.client != "" {
		line += fmt.Sprintf(" client %q", c.client)
	}
	for _, note := range c.notes {
		line += " " + note
	}
	outcome := "ok"
	if result.IsError {
		outcome = "refused: " + firstLine(result.Text)
	}
	t.logMu.Lock()
	defer t.logMu.Unlock()
	fmt.Fprintf(t.log, "%s: %s\n", line, outcome)
}

func firstLine(text string) string {
	line, _, _ := strings.Cut(text, "\n")
	return clip(line, 300)
}

// decode reads a tool's arguments strictly: unknown keys and wrong types
// are refused, and the message never quotes a value.
func decode(arguments json.RawMessage, into any) error {
	if len(arguments) == 0 || string(arguments) == "null" {
		arguments = json.RawMessage("{}")
	}
	decoder := json.NewDecoder(strings.NewReader(string(arguments)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(into); err != nil {
		var typeErr *json.UnmarshalTypeError
		switch {
		case errors.As(err, &typeErr):
			return refuse("%s must be a %s.", strings.TrimPrefix(typeErr.Field, "."), typeErr.Type.String())
		case strings.HasPrefix(err.Error(), "json: unknown field "):
			return refuse("%s is not an argument of this tool.", strings.TrimPrefix(err.Error(), "json: unknown field "))
		default:
			return refuse("The arguments are not a JSON object.")
		}
	}
	return nil
}

// result is structured content with the same JSON as its text, after an
// optional sentence.
func result(summary string, structured any) (Result, error) {
	data, err := json.Marshal(structured)
	if err != nil {
		return Result{}, err
	}
	text := string(data)
	if summary != "" {
		text = summary + "\n" + text
	}
	return Result{Text: text, Structured: structured}, nil
}

// clip keeps at most n bytes of text, cut on a character boundary.
func clip(text string, n int) string {
	if len(text) <= n {
		return text
	}
	cut := n
	for cut > 0 && text[cut]&0xC0 == 0x80 {
		cut--
	}
	return text[:cut] + "…"
}

// bounded reads an optional count with its default and maximum.
func bounded(value *int, fallback, most int) int {
	if value == nil || *value <= 0 {
		return fallback
	}
	return min(*value, most)
}

// workspace is the opened workspace a tool works in.
type workspace struct {
	name, path, id, branch string
}

// open asks the app for the workspace a call names; action calls are
// refused while the user turned actions off.
func (t *Tools) open(c *call, repository *string, action bool) (workspace, error) {
	if repository == nil || strings.TrimSpace(*repository) == "" {
		return workspace{}, refuse("Name a repository: a registered workspace's folder or its name.")
	}
	opened, err := t.app.Open(c.ctx, c.client, *repository, action)
	if err != nil {
		c.note("%q", *repository)
		return workspace{}, err
	}
	w := workspace{name: opened.GetWorkspace().GetName(), path: opened.GetWorkspace().GetPath(), id: opened.GetRepositoryId(), branch: opened.GetBranch()}
	c.note("workspace %q", w.name)
	return w, nil
}
