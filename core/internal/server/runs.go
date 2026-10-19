package server

import (
	"context"
	"errors"
	"fmt"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	"runnir/core/internal/approval"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/joblog"
)

// runAction is exactly what ConfirmRunAction sends to GitHub.
type runAction struct {
	RepositoryID string
	Owner        string
	Name         string
	RunID        int64
	Action       corev1.RunAction
}

func (s *service) GetJobLog(ctx context.Context, request *corev1.GetJobLogRequest) (*corev1.GetJobLogResponse, error) {
	if request.GetJobId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "job_id is required")
	}
	owner, name, problem, err := s.githubTarget(request.GetRepositoryId())
	if err != nil || problem != nil {
		return &corev1.GetJobLogResponse{Status: problem}, err
	}
	job, fetchErr := s.github.Job(ctx, owner, name, request.GetJobId())
	result, err := s.githubStatus(fetchErr)
	if err != nil {
		return nil, err
	}
	out := &corev1.GetJobLogResponse{Status: result}
	if fetchErr != nil {
		return out, nil
	}
	if job.Status != "completed" {
		out.Availability = corev1.JobLogAvailability_JOB_LOG_AVAILABILITY_NOT_READY
		return out, nil
	}
	log, logErr := s.github.JobLog(ctx, owner, name, request.GetJobId(), 0)
	if errors.Is(logErr, github.ErrLogUnavailable) {
		out.Availability = corev1.JobLogAvailability_JOB_LOG_AVAILABILITY_EXPIRED
		return out, nil
	}
	if out.Status, err = s.githubStatus(logErr); err != nil {
		return nil, err
	}
	if logErr != nil {
		return out, nil
	}
	steps := make([]joblog.Step, 0, len(job.Steps))
	for _, step := range job.Steps {
		if step.Conclusion != "skipped" {
			steps = append(steps, joblog.Step{Number: step.Number, StartedAt: step.StartedAt})
		}
	}
	out.Availability = corev1.JobLogAvailability_JOB_LOG_AVAILABILITY_AVAILABLE
	out.Truncated = log.Truncated
	for _, line := range joblog.Parse(log.Data, int64(log.DroppedLines)+1, steps) {
		out.Lines = append(out.Lines, &corev1.LogLine{Number: line.Number, Text: line.Text, Kind: lineKind(line.Kind), StepNumber: line.Step})
	}
	return out, nil
}

func (s *service) PrepareRunAction(ctx context.Context, request *corev1.PrepareRunActionRequest) (*corev1.PrepareRunActionResponse, error) {
	action := request.GetAction()
	if request.GetRunId() <= 0 || action == corev1.RunAction_RUN_ACTION_UNSPECIFIED || corev1.RunAction_name[int32(action)] == "" {
		return nil, status.Error(codes.InvalidArgument, "run_id and a known action are required")
	}
	owner, name, problem, err := s.githubTarget(request.GetRepositoryId())
	if err != nil || problem != nil {
		return &corev1.PrepareRunActionResponse{Status: problem}, err
	}
	run, fetchErr := s.github.Run(ctx, owner, name, request.GetRunId())
	result, err := s.githubStatus(fetchErr)
	if err != nil {
		return nil, err
	}
	out := &corev1.PrepareRunActionResponse{Status: result}
	if fetchErr != nil {
		return out, nil
	}
	out.Run = runMessage(run)
	if problem := runActionProblem(run, action); problem != "" {
		out.Problems = []string{problem}
		return out, nil
	}
	pending, err := s.runActions.Prepare(runAction{
		RepositoryID: request.GetRepositoryId(), Owner: owner, Name: name, RunID: run.ID, Action: action,
	})
	if errors.Is(err, approval.ErrTooMany) {
		return nil, status.Error(codes.ResourceExhausted, err.Error())
	} else if err != nil {
		return nil, status.Error(codes.Internal, "could not prepare the action")
	}
	out.ActionId = pending.ID
	out.ExpiresAt = timestamppb.New(pending.ExpiresAt)
	return out, nil
}

func (s *service) ConfirmRunAction(ctx context.Context, request *corev1.ConfirmRunActionRequest) (*corev1.ConfirmRunActionResponse, error) {
	prepared, err := s.runActions.Confirm(request.GetActionId())
	if err != nil {
		return nil, status.Error(codes.FailedPrecondition, "this confirmation expired or was already used; review the run again")
	}
	if _, err := s.repositories.Get(prepared.RepositoryID); err != nil {
		return nil, rpcError(err)
	}
	var sendErr error
	switch prepared.Action {
	case corev1.RunAction_RUN_ACTION_CANCEL:
		sendErr = s.github.CancelRun(ctx, prepared.Owner, prepared.Name, prepared.RunID)
	case corev1.RunAction_RUN_ACTION_RERUN:
		sendErr = s.github.RerunRun(ctx, prepared.Owner, prepared.Name, prepared.RunID, false)
	case corev1.RunAction_RUN_ACTION_RERUN_FAILED:
		sendErr = s.github.RerunRun(ctx, prepared.Owner, prepared.Name, prepared.RunID, true)
	}
	acceptedAt := time.Now()
	var rejected *github.RejectedError
	if errors.As(sendErr, &rejected) {
		return &corev1.ConfirmRunActionResponse{
			Status:    &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_OK},
			Rejection: rejected.Message,
		}, nil
	}
	result, err := s.githubStatus(sendErr)
	if err != nil {
		return nil, err
	}
	out := &corev1.ConfirmRunActionResponse{Status: result}
	if sendErr == nil {
		out.AcceptedAt = timestamppb.New(acceptedAt)
	}
	return out, nil
}

// runActionProblem says why an action does not fit the run's current state,
// the same way GitHub would refuse it.
func runActionProblem(run github.Run, action corev1.RunAction) string {
	finished := run.Status == "completed"
	switch action {
	case corev1.RunAction_RUN_ACTION_CANCEL:
		if finished {
			return fmt.Sprintf("Run #%d already finished (%s), so it cannot be cancelled.", run.RunNumber, run.Conclusion)
		}
	case corev1.RunAction_RUN_ACTION_RERUN:
		if !finished {
			return fmt.Sprintf("Run #%d is still %s. Only finished runs can be re-run.", run.RunNumber, humanStatus(run.Status))
		}
	case corev1.RunAction_RUN_ACTION_RERUN_FAILED:
		if !finished {
			return fmt.Sprintf("Run #%d is still %s. Only finished runs can be re-run.", run.RunNumber, humanStatus(run.Status))
		}
		switch run.Conclusion {
		case "failure", "cancelled", "timed_out":
		default:
			return fmt.Sprintf("Run #%d has no failed or cancelled jobs to re-run.", run.RunNumber)
		}
	}
	return ""
}

func humanStatus(status string) string {
	switch status {
	case "in_progress":
		return "in progress"
	case "":
		return "running"
	default:
		return status
	}
}

func runMessage(r github.Run) *corev1.WorkflowRun {
	return &corev1.WorkflowRun{
		Id: r.ID, WorkflowId: r.WorkflowID, Name: r.Name, DisplayTitle: r.DisplayTitle, RunNumber: r.RunNumber,
		RunAttempt: r.RunAttempt, Event: r.Event, Status: r.Status, Conclusion: r.Conclusion, Branch: r.Branch,
		HeadSha: r.HeadSHA, Actor: r.Actor, HtmlUrl: r.HTMLURL, CreatedAt: timestamp(r.CreatedAt), UpdatedAt: timestamp(r.UpdatedAt),
	}
}

func lineKind(kind joblog.Kind) corev1.LogLineKind {
	switch kind {
	case joblog.Error:
		return corev1.LogLineKind_LOG_LINE_KIND_ERROR
	case joblog.Warning:
		return corev1.LogLineKind_LOG_LINE_KIND_WARNING
	case joblog.Notice:
		return corev1.LogLineKind_LOG_LINE_KIND_NOTICE
	case joblog.Command:
		return corev1.LogLineKind_LOG_LINE_KIND_COMMAND
	case joblog.Group:
		return corev1.LogLineKind_LOG_LINE_KIND_GROUP
	case joblog.EndGroup:
		return corev1.LogLineKind_LOG_LINE_KIND_END_GROUP
	case joblog.Debug:
		return corev1.LogLineKind_LOG_LINE_KIND_DEBUG
	default:
		return corev1.LogLineKind_LOG_LINE_KIND_PLAIN
	}
}
