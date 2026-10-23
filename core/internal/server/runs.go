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
	"runnir/core/internal/store"
)

const maxLogLines = 50_000

// jobLogBudget bounds GetJobLog's download; the app waits 150 seconds. A
// variable so tests can shorten it.
var jobLogBudget = 2 * time.Minute

// runAction is exactly what ConfirmRunAction sends to GitHub.
type runAction struct {
	RepositoryID string
	// ServerID is the GitHub server the repository is on; "" is github.com.
	ServerID string
	Owner    string
	Name     string
	RunID    int64
	Action   corev1.RunAction
}

func (s *service) GetJobLog(ctx context.Context, request *corev1.GetJobLogRequest) (*corev1.GetJobLogResponse, error) {
	jobID := request.GetJobId()
	if jobID <= 0 {
		return nil, status.Error(codes.InvalidArgument, "job_id is required")
	}
	target, problem, err := s.githubTarget(request.GetRepositoryId(), "", "")
	if err != nil || problem != nil {
		return &corev1.GetJobLogResponse{Status: problem}, err
	}
	rt, shared := s.workspaces.ForRepository(request.GetRepositoryId())
	job, cached := github.Job{}, false
	if shared {
		job, cached = rt.CompletedJob(ctx, jobID)
	}
	if !cached {
		fetched, fetchErr := target.account.Client.Job(ctx, target.owner, target.name, jobID)
		result, err := s.githubStatus(target.account, fetchErr)
		if err != nil {
			return nil, err
		}
		if fetchErr != nil {
			return &corev1.GetJobLogResponse{Status: result}, nil
		}
		job = fetched
	}
	out := &corev1.GetJobLogResponse{Status: statusMessage(corev1.GithubAccess_GITHUB_ACCESS_OK, time.Time{})}
	if job.Status != "completed" {
		out.Availability = corev1.JobLogAvailability_JOB_LOG_AVAILABILITY_NOT_READY
		return out, nil
	}
	if shared {
		if data, meta, ok := rt.KeptLog(ctx, jobID); ok {
			fillLog(out, job, github.JobLog{Data: data, DroppedLines: meta.DroppedLines, Truncated: meta.Truncated, StoppedEarly: meta.StoppedEarly})
			return out, nil
		}
	}
	download := func(c context.Context) (github.JobLog, error) {
		return target.account.Client.JobLog(c, target.owner, target.name, jobID, 0)
	}
	var log github.JobLog
	var logErr error
	if shared {
		log, logErr = rt.SharedLog(ctx, jobID, jobLogBudget, download)
	} else {
		// Bound the whole download so the Core answers before the app gives up.
		logCtx, cancel := context.WithTimeout(ctx, jobLogBudget)
		log, logErr = download(logCtx)
		cancel()
	}
	if errors.Is(logErr, context.DeadlineExceeded) && ctx.Err() == nil {
		logErr = github.ErrUnavailable
	}
	if errors.Is(logErr, github.ErrLogUnavailable) {
		out.Availability = missingLogAvailability(job, time.Now())
		return out, nil
	}
	if out.Status, err = s.githubStatus(target.account, logErr); err != nil {
		return nil, err
	}
	if logErr != nil {
		return out, nil
	}
	if shared {
		rt.KeepLog(ctx, jobID, log.Data, store.LogMeta{DroppedLines: log.DroppedLines, Truncated: log.Truncated, StoppedEarly: log.StoppedEarly})
	}
	fillLog(out, job, log)
	return out, nil
}

// fillLog parses a log tail into the response's lines.
func fillLog(out *corev1.GetJobLogResponse, job github.Job, log github.JobLog) {
	steps := make([]joblog.Step, 0, len(job.Steps))
	for _, step := range job.Steps {
		if step.Conclusion != "skipped" {
			steps = append(steps, joblog.Step{Number: step.Number, StartedAt: step.StartedAt})
		}
	}
	// Many short lines cost more on the wire and in memory than their text:
	// cut to the last maxLogLines before parsing, which keeps the response
	// well under the client's 4 MiB message limit.
	data, skipped := joblog.Tail(log.Data, maxLogLines)
	lines := joblog.Parse(data, int64(log.DroppedLines+skipped)+1, steps)
	out.Availability = corev1.JobLogAvailability_JOB_LOG_AVAILABILITY_AVAILABLE
	out.Truncated = log.Truncated || skipped > 0
	out.StoppedEarly = log.StoppedEarly
	for _, line := range lines {
		out.Lines = append(out.Lines, &corev1.LogLine{Number: line.Number, Text: line.Text, Kind: lineKind(line.Kind), StepNumber: line.Step})
	}
}

func (s *service) PrepareRunAction(ctx context.Context, request *corev1.PrepareRunActionRequest) (*corev1.PrepareRunActionResponse, error) {
	action := request.GetAction()
	if request.GetRunId() <= 0 || action == corev1.RunAction_RUN_ACTION_UNSPECIFIED || corev1.RunAction_name[int32(action)] == "" {
		return nil, status.Error(codes.InvalidArgument, "run_id and a known action are required")
	}
	target, problem, err := s.githubTarget(request.GetRepositoryId(), "", "")
	if err != nil || problem != nil {
		return &corev1.PrepareRunActionResponse{Status: problem}, err
	}
	run, fetchErr := target.account.Client.Run(ctx, target.owner, target.name, request.GetRunId())
	result, err := s.githubStatus(target.account, fetchErr)
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
		RepositoryID: request.GetRepositoryId(), ServerID: target.account.Server.ID, Owner: target.owner, Name: target.name,
		RunID: run.ID, Action: action,
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
	// The server it was prepared for; one removed since is signed out.
	account, ok := s.accounts.Get(prepared.ServerID)
	if !ok {
		return &corev1.ConfirmRunActionResponse{Status: &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT}}, nil
	}
	var sendErr error
	switch prepared.Action {
	case corev1.RunAction_RUN_ACTION_CANCEL:
		sendErr = account.Client.CancelRun(ctx, prepared.Owner, prepared.Name, prepared.RunID)
	case corev1.RunAction_RUN_ACTION_RERUN:
		sendErr = account.Client.RerunRun(ctx, prepared.Owner, prepared.Name, prepared.RunID, false)
	case corev1.RunAction_RUN_ACTION_RERUN_FAILED:
		sendErr = account.Client.RerunRun(ctx, prepared.Owner, prepared.Name, prepared.RunID, true)
	}
	acceptedAt := time.Now()
	var rejected *github.RejectedError
	if errors.As(sendErr, &rejected) {
		return &corev1.ConfirmRunActionResponse{
			Status:    &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_OK},
			Rejection: rejected.Message,
		}, nil
	}
	result, err := s.githubStatus(account, sendErr)
	if err != nil {
		return nil, err
	}
	out := &corev1.ConfirmRunActionResponse{Status: result}
	if sendErr == nil {
		out.AcceptedAt = timestamppb.New(acceptedAt)
	}
	return out, nil
}

// logSettleTime is how long after a job finishes GitHub may still answer
// 404 for its log while storing it.
const logSettleTime = 2 * time.Minute

// missingLogAvailability explains a log GitHub does not have: a job that
// never ran wrote none (an empty log), a job that just finished may not be
// stored yet, and otherwise the log expired or was deleted.
func missingLogAvailability(job github.Job, now time.Time) corev1.JobLogAvailability {
	ran := false
	for _, step := range job.Steps {
		if step.Conclusion != "skipped" && !step.StartedAt.IsZero() {
			ran = true
			break
		}
	}
	switch {
	case job.Conclusion == "skipped" || !ran:
		return corev1.JobLogAvailability_JOB_LOG_AVAILABILITY_AVAILABLE
	case !job.CompletedAt.IsZero() && now.Sub(job.CompletedAt) < logSettleTime:
		return corev1.JobLogAvailability_JOB_LOG_AVAILABILITY_NOT_READY
	default:
		return corev1.JobLogAvailability_JOB_LOG_AVAILABILITY_EXPIRED
	}
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
