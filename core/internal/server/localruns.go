package server

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path"
	"sort"
	"strings"
	"sync"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	"runnir/core/internal/approval"
	"runnir/core/internal/execution"
	"runnir/core/internal/flow"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/localrun"
	"runnir/core/internal/repository"
	"runnir/core/internal/scanner"
	"runnir/core/internal/store"
	"runnir/core/internal/tools"
)

// toolChecker is the part of tools.Detector the service uses.
type toolChecker interface {
	Check(ctx context.Context, refresh bool) tools.Report
	ImagePresent(ctx context.Context, dockerPath, dockerHost, reference string) bool
}

// localRunApproval is a reviewed plan waiting for confirmation.
type localRunApproval struct {
	RepositoryID  string
	Spec          *localrun.Spec
	ActVersion    string
	Installed     bool
	EngineName    string
	EngineContext string
}

func (s *service) GetToolReadiness(ctx context.Context, request *corev1.GetToolReadinessRequest) (*corev1.GetToolReadinessResponse, error) {
	report := s.tools.Check(ctx, request.GetRefresh())
	if err := ctx.Err(); err != nil {
		return nil, status.FromContextError(err).Err()
	}
	return &corev1.GetToolReadinessResponse{Readiness: readinessMessage(report)}, nil
}

func (s *service) PrepareLocalRun(ctx context.Context, request *corev1.PrepareLocalRunRequest) (*corev1.PrepareLocalRunResponse, error) {
	info, err := s.repositories.Get(request.GetRepositoryId())
	if err != nil {
		return nil, rpcError(err)
	}
	setup, err := s.planScenario(ctx, info, request.GetScenario())
	if err != nil {
		return nil, err
	}
	if !setup.planned {
		return nil, status.Error(codes.FailedPrecondition, "no workflow of this repository reacts to a push, a pull request, a tag, a manual start or the schedule")
	}
	known := map[string]bool{}
	for _, w := range setup.workflows {
		known[w.Path] = true
	}
	selection := map[string][]string{}
	for _, chosen := range request.GetSelection() {
		if !known[chosen.GetWorkflowId()] {
			return nil, status.Error(codes.NotFound, "workflow not found")
		}
		selection[chosen.GetWorkflowId()] = append(selection[chosen.GetWorkflowId()], chosen.GetJobIds()...)
	}
	lanes, err := laneInputs(info.Path, setup, selection)
	if err != nil {
		return nil, err
	}

	// A review always looks at the tools as they are now.
	report := s.tools.Check(ctx, true)
	if err := ctx.Err(); err != nil {
		return nil, status.FromContextError(err).Err()
	}
	useInstalled := request.GetUseInstalledAct()
	act, actSource := report.Act(useInstalled)
	var imagePresent func(string) bool
	if report.Ready(useInstalled) {
		imagePresent = func(reference string) bool {
			return s.tools.ImagePresent(ctx, report.DockerCLI.Path, report.Engine.Endpoint, reference)
		}
	}
	ceiling := localrun.CeilingFor(report.Engine)
	asked, own := s.askedLimits(ctx, info.ID, request)
	limits := localrun.Choose(asked, ceiling)
	plan, err := localrun.NewPlan(localrun.Request{
		Scenarios: setup.scenarios, Scenario: setup.chosen, Lanes: lanes, Chosen: len(selection) > 0,
		HostUnsandboxed: request.GetHostUnsandboxed(),
	}, report, useInstalled, imagePresent, limits)
	switch {
	case errors.Is(err, localrun.ErrUnknownJob):
		return nil, status.Error(codes.NotFound, "a ticked job is not in its workflow; review the run again")
	case err != nil:
		return nil, status.Error(codes.Internal, "the run could not be planned")
	}
	names := map[string]string{}
	for _, lane := range plan.Lanes {
		names[lane.WorkflowID] = lane.WorkflowName
	}
	upstream := ""
	if setup.chosen.Kind == flow.Push && setup.chosen.Target == setup.repo.CurrentBranch {
		upstream = setup.git.UpstreamHead(ctx)
	}
	for i := range plan.Lanes {
		if !plan.Lanes[i].Selected() {
			continue
		}
		if plan.Lanes[i].Payload, err = localrun.Payload(eventContext(setup, plan.Lanes[i], names, upstream)); err != nil {
			return nil, status.Error(codes.Internal, "the run could not be planned")
		}
	}

	if plan.EnvironmentChoice != "" {
		workflows, err := s.repositories.Workflows(info.ID)
		if err != nil {
			return nil, rpcError(err)
		}
		if plan.Environments, err = s.environments(ctx, info.ID, workflows, false); err != nil {
			return nil, err
		}
		if len(plan.Environments) == 0 {
			plan.Notes = append(plan.Notes, plan.EnvironmentChoice+" Runnir knows no environment of this repository, so this run gets the Repository's values.")
			plan.EnvironmentChoice = ""
		}
	}

	plan.Ceiling, plan.OwnLimits = ceiling, own
	plan.LimitWarnings = localrun.Warnings(limits, ceiling, own)
	plan.LimitNote = localrun.Note(ceiling, report.Engine.Name, own)

	// act fetches actions from the Enterprise server the repository is on.
	instance := ""
	if account, ok := s.accounts.ForHost(info.OriginHost); ok && account.Server.ID != "" {
		instance = account.Server.WebHost
	}
	// Jobs on this Mac run JavaScript actions with its Node.js.
	node := ""
	if len(plan.HostJobs) > 0 {
		node = tools.FindNode(s.home, os.Getenv("PATH"))
	}
	approved := localRunApproval{
		RepositoryID: info.ID,
		ActVersion:   act.Version, Installed: actSource == tools.ActInstalled,
		EngineName: report.Engine.Name, EngineContext: report.Engine.Context,
		Spec: &localrun.Spec{
			ActPath: act.Path, DockerPath: report.DockerCLI.Path, DockerHost: report.Engine.Endpoint,
			UserHome: s.home, RepositoryPath: info.Path, Plan: plan, CacheDir: s.actCache, GitHubInstance: instance,
			HostNode: node, ConcurrentJobs: localrun.HostConcurrentJobs(),
		},
	}
	out := &corev1.PrepareLocalRunResponse{Readiness: readinessMessage(report), Plan: planMessage(approved)}
	if !plan.Runnable() {
		return out, nil
	}
	pending, err := s.localRuns.Prepare(approved)
	if errors.Is(err, approval.ErrTooMany) {
		return nil, status.Error(codes.ResourceExhausted, err.Error())
	} else if err != nil {
		return nil, status.Error(codes.Internal, "could not prepare the run")
	}
	out.ConfirmationId = pending.ID
	out.ExpiresAt = timestamppb.New(pending.ExpiresAt)
	return out, nil
}

// laneInputs turns the scenario's plan into the lanes of a local run: its
// lanes in order, then every workflow it does not start, each with the jobs
// ticked in selection.
func laneInputs(root string, setup scenarioSetup, selection map[string][]string) ([]localrun.LaneInput, error) {
	sources := map[string][]byte{}
	events := map[string]map[string]flow.Event{}
	for _, w := range setup.workflows {
		source, err := scanner.ReadWorkflowFile(root, w.Path)
		if err != nil {
			return nil, status.Error(codes.FailedPrecondition, "the workflow file "+w.Path+" cannot be read; refresh the repository")
		}
		sources[w.Path], events[w.Path] = source, w.Events
	}
	var lanes []localrun.LaneInput
	in := map[string]bool{}
	for _, lane := range setup.plan.Lanes {
		input := localrun.LaneInput{
			WorkflowID: lane.Path, Source: sources[lane.Path], Kind: localrun.Direct, Event: lane.Event(), Why: lane.Why,
			ParseError: lane.ParseError, JobSkipped: map[string]string{}, Selected: selection[lane.Path],
		}
		switch lane.Kind {
		case flow.Chained:
			input.Kind, input.After = localrun.Chained, lane.AfterPath
		case flow.ByHand:
			input.Kind = localrun.Manual
		}
		jobs := append([]flow.PlannedJob(nil), lane.Jobs...)
		sort.SliceStable(jobs, func(i, j int) bool { return jobs[i].Column < jobs[j].Column })
		for _, job := range jobs {
			input.Order = append(input.Order, job.ID)
			if job.Skipped != "" {
				input.JobSkipped[job.ID] = job.Skipped
			}
		}
		in[lane.Path] = true
		lanes = append(lanes, input)
	}
	reasons := map[string]string{}
	for _, skipped := range setup.plan.Skipped {
		reasons[skipped.Path] = skipped.Reason
	}
	for _, w := range setup.workflows {
		if in[w.Path] {
			continue
		}
		lanes = append(lanes, localrun.LaneInput{
			WorkflowID: w.Path, Source: sources[w.Path], Kind: localrun.Outside, Event: outsideEvent(setup.chosen, events[w.Path]),
			Skipped: reasons[w.Path], ParseError: w.ParseError, Selected: selection[w.Path],
		})
	}
	return lanes, nil
}

// scenarioEvent is the event a scenario sends.
func scenarioEvent(sc flow.Scenario) string {
	switch sc.Kind {
	case flow.PullRequest:
		return "pull_request"
	case flow.Manual:
		return "workflow_dispatch"
	case flow.Schedule:
		return "schedule"
	default:
		return "push"
	}
}

// outsideEvent is the event a workflow the scenario does not start runs
// with when ticked: the scenario's when it reacts to it, else its own first
// of push, pull_request and workflow_dispatch, else its first trigger.
func outsideEvent(sc flow.Scenario, events map[string]flow.Event) string {
	if _, ok := events[scenarioEvent(sc)]; ok {
		return scenarioEvent(sc)
	}
	for _, name := range []string{"push", "pull_request", "workflow_dispatch"} {
		if _, ok := events[name]; ok {
			return name
		}
	}
	names := make([]string, 0, len(events))
	for name := range events {
		names = append(names, name)
	}
	sort.Strings(names)
	if len(names) > 0 {
		return names[0]
	}
	return ""
}

// eventContext is what a lane's payload says: the scenario's refs as GitHub
// would send them for the lane's event.
func eventContext(setup scenarioSetup, lane localrun.Lane, names map[string]string, upstream string) localrun.EventContext {
	repo, sc := setup.repo, setup.chosen
	c := localrun.EventContext{Event: lane.Event, Branch: repo.CurrentBranch, HeadSHA: setup.head, DefaultBranch: repo.DefaultBranch}
	if setup.hasPullRequest {
		c.PullRequest, c.Draft = setup.pullRequest.Number, setup.pullRequest.Draft
	}
	switch lane.Event {
	case "pull_request", "pull_request_target":
		switch {
		case sc.Kind == flow.PullRequest:
			c.Base = sc.Target
		case repo.PullRequestBase != "":
			c.Base = repo.PullRequestBase
		default:
			c.Base = repo.DefaultBranch
		}
	case "push":
		switch sc.Kind {
		case flow.Push, flow.Merge:
			c.Ref = "refs/heads/" + sc.Target
		case flow.Tag:
			c.Ref = "refs/tags/" + tagName(sc.Target)
		default:
			c.Ref = "refs/heads/" + repo.CurrentBranch
		}
		c.Before = upstream
	case "release":
		if sc.Kind == flow.Tag {
			c.Tag = tagName(sc.Target)
		}
	case "workflow_dispatch":
		c.Ref = "refs/heads/" + repo.CurrentBranch
	case "workflow_run":
		c.Source, c.SourceEvent = names[lane.After], scenarioEvent(sc)
		if c.Source == "" {
			c.Source = path.Base(lane.After)
		}
	}
	return c
}

// tagName stands in for a tag pattern such as v*.*.* with a name it matches.
func tagName(target string) string {
	return strings.NewReplacer("**", "1", "*", "1", "?", "1").Replace(target)
}

// askedLimits are the limits a review asks for: those of the request, the
// workspace's own, or none (the defaults) after a reset or without either.
// own says they are not the defaults.
func (s *service) askedLimits(ctx context.Context, repositoryID string, request *corev1.PrepareLocalRunRequest) (*localrun.Limits, bool) {
	switch {
	case request.GetResetLimits():
		return nil, false
	case request.GetLimits() != nil:
		l := request.GetLimits()
		return &localrun.Limits{CPUs: int(l.GetCpus()), MemoryBytes: l.GetMemoryBytes(), Timeout: time.Duration(l.GetTimeoutSeconds()) * time.Second}, true
	}
	if saved, ok := s.workspaces.LocalRunLimits(ctx, repositoryID); ok {
		return &localrun.Limits{CPUs: saved.CPUs, MemoryBytes: saved.MemoryBytes, Timeout: saved.Timeout}, true
	}
	return nil, false
}

// The limits on values for one run; GitHub allows 48 KiB per secret.
const (
	maxRunValues    = 100
	maxRunValueSize = 48 << 10
)

// runValues checks values against the names the plan reads and upper-cases them.
func runValues(kind string, values map[string]string, names []string) (map[string]string, error) {
	if len(values) == 0 {
		return nil, nil
	}
	if len(values) > maxRunValues {
		return nil, fmt.Errorf("at most %d %ss can be passed", maxRunValues, kind)
	}
	allowed := map[string]bool{}
	for _, name := range names {
		allowed[name] = true
	}
	out := make(map[string]string, len(values))
	for name, value := range values {
		upper := strings.ToUpper(name)
		if !allowed[upper] {
			return nil, fmt.Errorf("the workflow does not read the %s %s", kind, upper)
		}
		if _, twice := out[upper]; twice {
			return nil, fmt.Errorf("the %s %s is given twice", kind, upper)
		}
		if len(value) > maxRunValueSize {
			return nil, fmt.Errorf("the value of %s is larger than 48 KiB", upper)
		}
		out[upper] = value
	}
	return out, nil
}

// valuesSupported refuses values where act cannot get them (Windows).
func valuesSupported(passesValues bool, request *corev1.ConfirmLocalRunRequest) error {
	if !passesValues && (len(request.GetSecrets()) > 0 || len(request.GetVariables()) > 0) {
		return status.Error(codes.FailedPrecondition, "secrets and variables reach act only on macOS and Linux")
	}
	return nil
}

func (s *service) ConfirmLocalRun(_ context.Context, request *corev1.ConfirmLocalRunRequest) (*corev1.ConfirmLocalRunResponse, error) {
	if err := valuesSupported(localrun.PassesValues, request); err != nil {
		return nil, err
	}
	approved, err := s.localRuns.Confirm(request.GetConfirmationId())
	if err != nil {
		return nil, status.Error(codes.FailedPrecondition, "this confirmation expired or was already used; review the run again")
	}
	info, err := s.repositories.Get(approved.RepositoryID)
	if err != nil {
		return nil, rpcError(err)
	}
	// act runs copies of the files made at the review, so each must still be
	// the file the user reviewed.
	plan := approved.Spec.Plan
	var workflows []string
	for _, lane := range plan.Selected() {
		source, err := scanner.ReadWorkflowFile(info.Path, lane.WorkflowID)
		digest := sha256.Sum256(source)
		if err != nil || hex.EncodeToString(digest[:]) != lane.Digest {
			return nil, status.Error(codes.FailedPrecondition, lane.WorkflowID+" changed after the review; review the run again")
		}
		workflows = append(workflows, lane.WorkflowID)
	}
	secrets, err := runValues("secret", request.GetSecrets(), plan.Secrets)
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, err.Error()+"; review the run again")
	}
	variables, err := runValues("variable", request.GetVariables(), plan.Variables)
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, err.Error()+"; review the run again")
	}
	spec := *approved.Spec
	spec.Secrets, spec.Variables = secrets, variables

	id, err := execution.NewID()
	if err != nil {
		return nil, status.Error(codes.Internal, "could not start the run")
	}
	// Recorded before it starts, so the run's events are written after it.
	s.workspaces.RecordLocalRun(info.ID, store.LocalRun{
		ExecutionID: id, Scenario: plan.Scenario.Title(), Workflows: workflows,
		StartedAt: time.Now(), State: store.LocalQueued, ActVersion: approved.ActVersion, Engine: approved.EngineName,
	})
	s.localOutputs.Create(id, info.ID, plan, approved.ActVersion, approved.Installed, approved.EngineName)
	if request.GetStartedBy() != "" {
		s.localOutputs.MarkStartedBy(id, request.GetStartedBy())
	}
	// The limits of a confirmed run are the workspace's from now on; a run
	// with the defaults forgets them.
	var keep *store.RunLimits
	if plan.OwnLimits {
		keep = &store.RunLimits{CPUs: plan.Limits.CPUs, MemoryBytes: plan.Limits.MemoryBytes, Timeout: plan.Limits.Timeout}
	}
	_ = s.workspaces.SetLocalRunLimits(context.Background(), info.ID, keep)
	started, err := s.executions.StartJob(execution.Job{
		ExecutionID: id, RepositoryID: info.ID, RepositoryPath: info.Path, Spec: &spec,
	})
	if err != nil {
		s.localOutputs.Remove(id)
		s.workspaces.LocalRunNotStarted(id, "The run could not start.")
		return nil, rpcError(err)
	}
	s.recordUsage(corev1.UsageEvent_USAGE_EVENT_ACTION_LOCAL_RUN_RUN)
	return &corev1.ConfirmLocalRunResponse{Execution: &corev1.ExecutionResponse{
		ExecutionId: started.ID, RepositoryId: started.RepositoryID, State: started.State,
	}}, nil
}

// maxOutputAnswerBytes bounds the lines of one GetLocalRunOutput answer,
// well under what the app takes in one message; the app asks again for the
// rest (more_lines).
const maxOutputAnswerBytes = 8 << 20

// answerLines puts lines into an answer up to about room bytes, at least
// one; the rest wait for the next call (more_lines, last_sequence).
func answerLines(out *corev1.GetLocalRunOutputResponse, lines []localrun.Line, room int) {
	for i, line := range lines {
		if room -= len(line.Text) + len(line.Workflow) + len(line.JobID) + 32; room < 0 && i > 0 {
			out.MoreLines, out.LastSequence = true, lines[i-1].Sequence
			return
		}
		out.Lines = append(out.Lines, &corev1.LocalRunLine{Sequence: line.Sequence, WorkflowId: line.Workflow, JobId: line.JobID, Text: line.Text, Error: line.Error})
	}
}

func (s *service) GetLocalRunOutput(_ context.Context, request *corev1.GetLocalRunOutputRequest) (*corev1.GetLocalRunOutputResponse, error) {
	snap, ok := s.localOutputs.Since(request.GetExecutionId(), request.GetAfterSequence())
	if !ok {
		return nil, status.Error(codes.NotFound, "no local run with this id")
	}
	out := &corev1.GetLocalRunOutputResponse{
		ExecutionId: snap.ExecutionID, RepositoryId: snap.RepositoryID, State: snap.State,
		Phase: phaseMessage(snap.Phase), Discarded: snap.Discarded, LastSequence: snap.LastSequence,
		Plan: planMessage(localRunApproval{Spec: &localrun.Spec{Plan: snap.Plan}, ActVersion: snap.ActVersion,
			Installed: snap.ActInstalled, EngineName: snap.EngineName}),
		StartedAt: timestamp(snap.StartedAt), FinishedAt: timestamp(snap.FinishedAt),
		ExitCode: int32(snap.ExitCode), Message: snap.Message, CleanupProblem: snap.CleanupProblem,
		StartedBy: snap.StartedBy,
	}
	answerLines(out, snap.Lines, maxOutputAnswerBytes)
	for _, source := range snap.DiscardedJobs {
		out.DiscardedJobs = append(out.DiscardedJobs, &corev1.LocalRunLineSource{WorkflowId: source.Workflow, JobId: source.JobID})
	}
	for _, job := range snap.Jobs {
		out.Jobs = append(out.Jobs, &corev1.LocalRunJobStatus{
			WorkflowId: job.Workflow, Id: job.ID, Name: job.Name, State: jobStateMessage(job.State), Reason: job.Reason,
			StartedAt: timestamp(job.StartedAt), FinishedAt: timestamp(job.FinishedAt),
		})
	}
	return out, nil
}

func (s *service) CancelExecution(_ context.Context, request *corev1.CancelExecutionRequest) (*corev1.CancelExecutionResponse, error) {
	err := s.executions.Cancel(request.GetExecutionId())
	if errors.Is(err, execution.ErrNotFound) {
		// A run that already finished needs no cancel.
		if snap, ok := s.localOutputs.Since(request.GetExecutionId(), ^uint64(0)); ok && snap.Phase == localrun.PhaseFinished {
			return &corev1.CancelExecutionResponse{}, nil
		}
		return nil, status.Error(codes.NotFound, "no queued or running execution with this id")
	}
	if err != nil {
		return nil, rpcError(err)
	}
	return &corev1.CancelExecutionResponse{}, nil
}

// ListEnvironments lists the environments whose values a local run can take.
func (s *service) ListEnvironments(ctx context.Context, request *corev1.ListEnvironmentsRequest) (*corev1.ListEnvironmentsResponse, error) {
	workflows, err := s.repositories.Workflows(request.GetRepositoryId())
	if err != nil {
		return nil, rpcError(err)
	}
	names, err := s.environments(ctx, request.GetRepositoryId(), workflows, true)
	if err != nil {
		return nil, err
	}
	return &corev1.ListEnvironmentsResponse{Names: names}, nil
}

// environments are the workflows' environments and, when a job picks its
// own with an expression, the repository's on GitHub: asked again when
// fresh, else as read in the last few minutes. GitHub out of reach leaves
// its own out; only a cancelled call is an error.
func (s *service) environments(ctx context.Context, repositoryID string, workflows []repository.Workflow, fresh bool) ([]string, error) {
	var callErr error
	names := localrun.Environments(workflows, func() []string {
		if cached, ok := s.gitHubEnvironments.get(repositoryID, time.Now()); ok && !fresh {
			return cached
		}
		target, problem, err := s.githubTarget(repositoryID, "", "")
		if err != nil || problem != nil {
			return nil
		}
		onGitHub, fetchErr := target.account.Client.Environments(ctx, target.owner, target.name)
		if _, callErr = s.githubStatus(target.account, fetchErr); fetchErr == nil {
			s.gitHubEnvironments.put(repositoryID, onGitHub, time.Now())
		}
		return onGitHub
	})
	return names, callErr
}

// environmentCache keeps the environments GitHub listed per repository.
type environmentCache struct {
	mu      sync.Mutex
	entries map[string]cachedEnvironments
}

type cachedEnvironments struct {
	names []string
	read  time.Time
}

// environmentsKept is how long a review reuses GitHub's environments.
const environmentsKept = 5 * time.Minute

func (c *environmentCache) get(repositoryID string, now time.Time) ([]string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	entry, ok := c.entries[repositoryID]
	if !ok || now.Sub(entry.read) > environmentsKept {
		return nil, false
	}
	return entry.names, true
}

func (c *environmentCache) put(repositoryID string, names []string, now time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.entries == nil {
		c.entries = map[string]cachedEnvironments{}
	}
	c.entries[repositoryID] = cachedEnvironments{names: names, read: now}
}

func (s *service) workflow(repositoryID, workflowID string) (repository.Workflow, error) {
	workflows, err := s.repositories.Workflows(repositoryID)
	if err != nil {
		return repository.Workflow{}, rpcError(err)
	}
	for _, w := range workflows {
		if w.ID == workflowID {
			return w, nil
		}
	}
	return repository.Workflow{}, status.Error(codes.NotFound, "workflow not found")
}

func readinessMessage(report tools.Report) *corev1.ToolReadiness {
	e := report.Engine
	return &corev1.ToolReadiness{
		BundledAct: toolMessage(report.BundledAct), InstalledAct: toolMessage(report.InstalledAct),
		DockerCli: toolMessage(report.DockerCLI),
		Engine: &corev1.ContainerEngine{
			State: toolStateMessage(e.State), Name: e.Name, Context: e.Context, Endpoint: e.Endpoint, Local: e.Local,
			Version: e.Version, ApiVersion: e.APIVersion, Architecture: e.Architecture,
			Cpus: uint32(max(e.CPUs, 0)), MemoryBytes: e.MemoryBytes, Detail: e.Detail,
		},
		CheckedAt:         timestamp(report.CheckedAt),
		TestedActVersion:  tools.TestedActVersion.String(),
		MinimumActVersion: tools.MinActVersion.String(),
	}
}

func toolMessage(t tools.Tool) *corev1.ToolStatus {
	return &corev1.ToolStatus{State: toolStateMessage(t.State), Version: t.Version, Path: t.Path, Detail: t.Detail, Untested: t.Untested}
}

func toolStateMessage(state tools.State) corev1.ToolState {
	switch state {
	case tools.Found:
		return corev1.ToolState_TOOL_STATE_FOUND
	case tools.Missing:
		return corev1.ToolState_TOOL_STATE_MISSING
	case tools.Stopped:
		return corev1.ToolState_TOOL_STATE_STOPPED
	case tools.Unsupported:
		return corev1.ToolState_TOOL_STATE_UNSUPPORTED
	case tools.Failed:
		return corev1.ToolState_TOOL_STATE_FAILED
	default:
		return corev1.ToolState_TOOL_STATE_UNSPECIFIED
	}
}

func planMessage(approved localRunApproval) *corev1.LocalRunPlan {
	plan := approved.Spec.Plan
	out := &corev1.LocalRunPlan{
		Scenario: scenarioMessage(plan.Scenario), Secrets: plan.Secrets, Variables: plan.Variables, UnnamedSecrets: plan.UnnamedSecrets,
		Notes: plan.Notes, Blockers: plan.Blockers,
		Cpus: uint32(max(plan.Limits.CPUs, 0)), MemoryBytes: plan.Limits.MemoryBytes,
		TimeoutSeconds: uint32(plan.Limits.Timeout / time.Second),
		MaxCpus:        uint32(max(plan.Ceiling.CPUs, 0)), MaxMemoryBytes: plan.Ceiling.MemoryBytes,
		MaxTimeoutSeconds: uint32(plan.Ceiling.Timeout / time.Second),
		OwnLimits:         plan.OwnLimits, LimitWarnings: plan.LimitWarnings, LimitNote: plan.LimitNote, Environment: plan.Environment,
		EnvironmentChoice: plan.EnvironmentChoice, Environments: plan.Environments, HostJobs: plan.HostJobs, HostUnsandboxed: plan.HostUnsandboxed,
		ActVersion: approved.ActVersion, InstalledAct: approved.Installed,
		EngineName: approved.EngineName, EngineContext: approved.EngineContext,
	}
	for _, sc := range plan.Scenarios {
		out.Scenarios = append(out.Scenarios, scenarioMessage(sc))
	}
	for _, lane := range plan.Lanes {
		message := &corev1.LocalRunLane{
			WorkflowId: lane.WorkflowID, WorkflowName: lane.WorkflowName, Kind: localLaneKindMessage(lane.Kind), Event: lane.Event,
			Why: lane.Why, Skipped: lane.Skipped, After: lane.After, Selected: lane.Selected(), ParseError: lane.ParseError,
		}
		for _, job := range lane.Jobs {
			message.Jobs = append(message.Jobs, &corev1.LocalRunJob{
				Id: job.ID, Name: job.Name, RunsOn: job.RunsOn, Image: job.Image,
				Support: supportMessage(job.Support), Reason: job.Reason, Needs: job.Needs, Selected: job.Selected, Skipped: job.Skipped,
			})
		}
		out.Lanes = append(out.Lanes, message)
	}
	for _, image := range plan.Images {
		out.Images = append(out.Images, &corev1.LocalRunImage{Reference: image.Ref, Present: image.Present})
	}
	return out
}

func localLaneKindMessage(kind localrun.LaneKind) corev1.LocalRunLaneKind {
	switch kind {
	case localrun.Direct:
		return corev1.LocalRunLaneKind_LOCAL_RUN_LANE_KIND_DIRECT
	case localrun.Chained:
		return corev1.LocalRunLaneKind_LOCAL_RUN_LANE_KIND_CHAINED
	case localrun.Manual:
		return corev1.LocalRunLaneKind_LOCAL_RUN_LANE_KIND_MANUAL
	case localrun.Outside:
		return corev1.LocalRunLaneKind_LOCAL_RUN_LANE_KIND_OUTSIDE
	default:
		return corev1.LocalRunLaneKind_LOCAL_RUN_LANE_KIND_UNSPECIFIED
	}
}

func supportMessage(support localrun.Support) corev1.LocalJobSupport {
	switch support {
	case localrun.Supported:
		return corev1.LocalJobSupport_LOCAL_JOB_SUPPORT_SUPPORTED
	case localrun.Unsupported:
		return corev1.LocalJobSupport_LOCAL_JOB_SUPPORT_UNSUPPORTED
	case localrun.Unknown:
		return corev1.LocalJobSupport_LOCAL_JOB_SUPPORT_UNKNOWN
	case localrun.Host:
		return corev1.LocalJobSupport_LOCAL_JOB_SUPPORT_HOST
	default:
		return corev1.LocalJobSupport_LOCAL_JOB_SUPPORT_UNSPECIFIED
	}
}

func phaseMessage(phase localrun.Phase) corev1.LocalRunPhase {
	switch phase {
	case localrun.PhaseQueued:
		return corev1.LocalRunPhase_LOCAL_RUN_PHASE_QUEUED
	case localrun.PhaseRunning:
		return corev1.LocalRunPhase_LOCAL_RUN_PHASE_RUNNING
	case localrun.PhaseStopping:
		return corev1.LocalRunPhase_LOCAL_RUN_PHASE_STOPPING
	case localrun.PhaseCleaningUp:
		return corev1.LocalRunPhase_LOCAL_RUN_PHASE_CLEANING_UP
	case localrun.PhaseFinished:
		return corev1.LocalRunPhase_LOCAL_RUN_PHASE_FINISHED
	default:
		return corev1.LocalRunPhase_LOCAL_RUN_PHASE_UNSPECIFIED
	}
}

func jobStateMessage(state localrun.JobState) corev1.LocalJobState {
	switch state {
	case localrun.JobWaiting:
		return corev1.LocalJobState_LOCAL_JOB_STATE_WAITING
	case localrun.JobRunning:
		return corev1.LocalJobState_LOCAL_JOB_STATE_RUNNING
	case localrun.JobSucceeded:
		return corev1.LocalJobState_LOCAL_JOB_STATE_SUCCEEDED
	case localrun.JobFailed:
		return corev1.LocalJobState_LOCAL_JOB_STATE_FAILED
	case localrun.JobSkipped:
		return corev1.LocalJobState_LOCAL_JOB_STATE_SKIPPED
	case localrun.JobUnsupported:
		return corev1.LocalJobState_LOCAL_JOB_STATE_UNSUPPORTED
	case localrun.JobCancelled:
		return corev1.LocalJobState_LOCAL_JOB_STATE_CANCELLED
	case localrun.JobNotRun:
		return corev1.LocalJobState_LOCAL_JOB_STATE_NOT_RUN
	default:
		return corev1.LocalJobState_LOCAL_JOB_STATE_UNSPECIFIED
	}
}
