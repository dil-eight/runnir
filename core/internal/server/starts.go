package server

import (
	"context"
	"strings"
	"time"

	"google.golang.org/protobuf/types/known/timestamppb"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/store"
	"runnir/core/internal/workspace"
)

// startKind is the kind of start a confirmed run action records: a re-run
// starts the run's next attempt. Cancel and approve start none.
func startKind(action corev1.RunAction) (string, bool) {
	switch action {
	case corev1.RunAction_RUN_ACTION_RERUN:
		return store.StartRerun, true
	case corev1.RunAction_RUN_ACTION_RERUN_FAILED:
		return store.StartRerunFailed, true
	case corev1.RunAction_RUN_ACTION_RERUN_JOB:
		return store.StartRerunJob, true
	}
	return "", false
}

// recordRerun keeps a re-run GitHub accepted as the attempt after the one
// reviewed, in the repository's workspace; without one nothing is kept.
// GitHub refuses to re-run a run that is not finished, so the attempt is
// wrong only when another re-run starts and finishes between review and
// confirmation.
func (s *service) recordRerun(ctx context.Context, prepared runAction, sentAt time.Time) {
	kind, ok := startKind(prepared.Action)
	if !ok {
		return
	}
	rt, ok := s.workspaces.ForRepository(prepared.RepositoryID)
	if !ok {
		return
	}
	_ = rt.Store().RecordStart(ctx, store.RunStart{
		Source: store.Source{ServerID: prepared.ServerID, Repository: strings.ToLower(prepared.Owner + "/" + prepared.Name)},
		RunID:  prepared.RunID, Attempt: prepared.Attempt + 1, Kind: kind, SentAt: sentAt,
	})
}

// addStarts adds the attempts Runnir started to the messages of a
// workspace's runs (B46).
func addStarts(ctx context.Context, rt *workspace.Runtime, runs []*corev1.WorkflowRun) {
	if len(runs) == 0 {
		return
	}
	withStarts(runs, rt.RunStarts(ctx))
}

// withStarts adds to each run the attempts Runnir started, oldest first, up
// to the run's attempt: one recorded before GitHub reports it waits.
func withStarts(runs []*corev1.WorkflowRun, starts map[int64][]store.RunStart) {
	kinds := map[string]corev1.RunnirStartKind{
		store.StartDispatch: corev1.RunnirStartKind_RUNNIR_START_KIND_DISPATCH, store.StartRerun: corev1.RunnirStartKind_RUNNIR_START_KIND_RERUN,
		store.StartRerunFailed: corev1.RunnirStartKind_RUNNIR_START_KIND_RERUN_FAILED, store.StartRerunJob: corev1.RunnirStartKind_RUNNIR_START_KIND_RERUN_JOB,
	}
	for _, run := range runs {
		for _, start := range starts[run.GetId()] {
			if start.Attempt <= max(run.GetRunAttempt(), 1) {
				run.RunnirStarts = append(run.RunnirStarts, &corev1.RunnirStart{Attempt: start.Attempt, Kind: kinds[start.Kind], SentAt: timestamppb.New(start.SentAt)})
			}
		}
	}
}
