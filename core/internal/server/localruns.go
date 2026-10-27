package server

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	"runnir/core/internal/approval"
	"runnir/core/internal/execution"
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
	Workflow      repository.Workflow
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
	workflow, err := s.workflow(info.ID, request.GetWorkflowId())
	if err != nil {
		return nil, err
	}
	source, err := scanner.ReadWorkflowFile(info.Path, workflow.ID)
	if err != nil {
		return nil, status.Error(codes.FailedPrecondition, "the workflow file cannot be read; refresh the repository")
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
	plan, err := localrun.NewPlan(localrun.Request{
		WorkflowID: workflow.ID, Source: source, JobID: request.GetJobId(), Event: request.GetEvent(),
	}, report, useInstalled, imagePresent, localrun.Choose(nil, localrun.CeilingFor(report.Engine)))
	switch {
	case errors.Is(err, localrun.ErrUnknownJob):
		return nil, status.Error(codes.NotFound, "the workflow has no job with this id")
	case errors.Is(err, localrun.ErrUnknownEvent):
		return nil, status.Error(codes.InvalidArgument, "the workflow is not triggered by this event")
	case err != nil:
		return nil, status.Error(codes.Internal, "the run could not be planned")
	}

	// act fetches actions from the Enterprise server the repository is on.
	instance := ""
	if account, ok := s.accounts.ForHost(info.OriginHost); ok && account.Server.ID != "" {
		instance = account.Server.WebHost
	}
	approved := localRunApproval{
		RepositoryID: info.ID, Workflow: workflow,
		ActVersion: act.Version, Installed: actSource == tools.ActInstalled,
		EngineName: report.Engine.Name, EngineContext: report.Engine.Context,
		Spec: &localrun.Spec{
			ActPath: act.Path, DockerPath: report.DockerCLI.Path, DockerHost: report.Engine.Endpoint,
			UserHome: s.home, RepositoryPath: info.Path, Plan: plan, CacheDir: s.actCache, GitHubInstance: instance,
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
	// act reads the file when it starts, so it must still be the file the
	// user reviewed.
	source, err := scanner.ReadWorkflowFile(info.Path, approved.Workflow.ID)
	digest := sha256.Sum256(source)
	if err != nil || hex.EncodeToString(digest[:]) != approved.Spec.Plan.Digest {
		return nil, status.Error(codes.FailedPrecondition, "the workflow file changed after the review; review the run again")
	}
	secrets, err := runValues("secret", request.GetSecrets(), approved.Spec.Plan.Secrets)
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, err.Error()+"; review the run again")
	}
	variables, err := runValues("variable", request.GetVariables(), approved.Spec.Plan.Variables)
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
		ExecutionID: id, WorkflowPath: approved.Workflow.ID, JobID: approved.Spec.Plan.JobID, Event: approved.Spec.Plan.Event,
		StartedAt: time.Now(), State: store.LocalQueued, ActVersion: approved.ActVersion, Engine: approved.EngineName,
	})
	s.localOutputs.Create(id, info.ID, approved.Spec.Plan, approved.ActVersion, approved.Installed, approved.EngineName)
	started, err := s.executions.StartJob(execution.Job{
		ExecutionID: id, RepositoryID: info.ID, RepositoryPath: info.Path,
		Workflow: approved.Workflow, Spec: &spec,
	})
	if err != nil {
		s.localOutputs.Remove(id)
		s.workspaces.LocalRunNotStarted(id, "The run could not start.")
		return nil, rpcError(err)
	}
	return &corev1.ConfirmLocalRunResponse{Execution: &corev1.ExecutionResponse{
		ExecutionId: started.ID, RepositoryId: started.RepositoryID, State: started.State,
	}}, nil
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
	}
	for _, line := range snap.Lines {
		out.Lines = append(out.Lines, &corev1.LocalRunLine{Sequence: line.Sequence, JobId: line.JobID, Text: line.Text, Error: line.Error})
	}
	for _, job := range snap.Jobs {
		out.Jobs = append(out.Jobs, &corev1.LocalRunJobStatus{
			Id: job.ID, Name: job.Name, State: jobStateMessage(job.State), Reason: job.Reason,
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
		WorkflowId: plan.WorkflowID, WorkflowName: plan.WorkflowName, Events: plan.Events, Event: plan.Event,
		JobId: plan.JobID, Secrets: plan.Secrets, Variables: plan.Variables, UnnamedSecrets: plan.UnnamedSecrets,
		Notes: plan.Notes, Blockers: plan.Blockers,
		Cpus: uint32(max(plan.Limits.CPUs, 0)), MemoryBytes: plan.Limits.MemoryBytes,
		TimeoutSeconds: uint32(plan.Limits.Timeout / time.Second),
		ActVersion:     approved.ActVersion, InstalledAct: approved.Installed,
		EngineName: approved.EngineName, EngineContext: approved.EngineContext,
	}
	for _, job := range plan.Jobs {
		out.Jobs = append(out.Jobs, &corev1.LocalRunJob{
			Id: job.ID, Name: job.Name, RunsOn: job.RunsOn, Image: job.Image,
			Support: supportMessage(job.Support), Reason: job.Reason,
		})
	}
	for _, image := range plan.Images {
		out.Images = append(out.Images, &corev1.LocalRunImage{Reference: image.Ref, Present: image.Present})
	}
	return out
}

func supportMessage(support localrun.Support) corev1.LocalJobSupport {
	switch support {
	case localrun.Supported:
		return corev1.LocalJobSupport_LOCAL_JOB_SUPPORT_SUPPORTED
	case localrun.Unsupported:
		return corev1.LocalJobSupport_LOCAL_JOB_SUPPORT_UNSUPPORTED
	case localrun.Unknown:
		return corev1.LocalJobSupport_LOCAL_JOB_SUPPORT_UNKNOWN
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
