package server

import (
	"context"
	"sort"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"runnir/core/internal/analytics"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

func (s *service) GetAnalytics(context.Context, *corev1.GetAnalyticsRequest) (*corev1.Analytics, error) {
	if s.analytics == nil {
		return nil, status.Error(codes.Unavailable, "analytics are not available")
	}
	// Sealing first leaves only today's counts unsealed, as Settings says.
	if err := s.analytics.Seal(); err != nil {
		return nil, status.Error(codes.Internal, "the analytics ledger could not be read")
	}
	return s.analyticsMessage()
}

func (s *service) SetAnalyticsLevel(_ context.Context, request *corev1.SetAnalyticsLevelRequest) (*corev1.Analytics, error) {
	if s.analytics == nil {
		return nil, status.Error(codes.Unavailable, "analytics are not available")
	}
	var level analytics.Level
	switch request.GetLevel() {
	case corev1.AnalyticsLevel_ANALYTICS_LEVEL_OFF:
		level = analytics.Off
	case corev1.AnalyticsLevel_ANALYTICS_LEVEL_BASIC:
		level = analytics.Basic
	case corev1.AnalyticsLevel_ANALYTICS_LEVEL_FULL:
		level = analytics.Full
	default:
		return nil, status.Error(codes.InvalidArgument, "a known analytics level is required")
	}
	if err := s.analytics.SetLevel(level, request.GetFromPrompt()); err != nil {
		return nil, status.Error(codes.Internal, "the analytics level could not be changed")
	}
	return s.analyticsMessage()
}

func (s *service) RecordUsage(_ context.Context, request *corev1.RecordUsageRequest) (*corev1.RecordUsageResponse, error) {
	if analytics.UsageCounter(request.GetEvent()) == "" {
		return nil, status.Error(codes.InvalidArgument, "a known usage event is required")
	}
	s.recordUsage(request.GetEvent())
	return &corev1.RecordUsageResponse{}, nil
}

// recordUsage counts a usage event the Core sees itself; counted only at
// Full, and a failure to count never fails the work.
func (s *service) recordUsage(event corev1.UsageEvent) {
	if s.analytics != nil {
		_ = s.analytics.Record(time.Now(), event)
	}
}

func (s *service) analyticsMessage() (*corev1.Analytics, error) {
	state, err := s.analytics.State()
	if err != nil {
		return nil, status.Error(codes.Internal, "the analytics ledger could not be read")
	}
	out := &corev1.Analytics{PromptAnswered: state.PromptAnswered, AnalyticsId: state.ID,
		Persistent: state.Persistent, SendingAvailable: s.analyticsSending,
		Sealed: analyticsCounters(state.Sealed), Today: analyticsCounters(state.Unsealed)}
	switch state.Level {
	case analytics.Off:
		out.Level = corev1.AnalyticsLevel_ANALYTICS_LEVEL_OFF
	case analytics.Full:
		out.Level = corev1.AnalyticsLevel_ANALYTICS_LEVEL_FULL
	default:
		out.Level = corev1.AnalyticsLevel_ANALYTICS_LEVEL_BASIC
	}
	return out, nil
}

// analyticsCounters are counts above zero, sorted by name.
func analyticsCounters(counts analytics.Counts) []*corev1.AnalyticsCounter {
	names := make([]string, 0, len(counts))
	for name, value := range counts {
		if value > 0 {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	out := make([]*corev1.AnalyticsCounter, 0, len(names))
	for _, name := range names {
		out = append(out, &corev1.AnalyticsCounter{Name: name, Value: uint64(counts[name])})
	}
	return out
}

// countSupersededCancel counts a cancel GitHub accepted for a superseded
// run, with the minutes it saved by the workflow's median run.
func (s *service) countSupersededCancel(ctx context.Context, repositoryID string, runID int64, at time.Time) {
	if s.analytics == nil || s.workspaces == nil {
		return
	}
	rt, ok := s.workspaces.ForRepository(repositoryID)
	if !ok {
		return
	}
	superseded, minutes, err := rt.CancelEstimate(ctx, runID, at)
	if err != nil || !superseded {
		return
	}
	_ = s.analytics.Add(at, analytics.Counts{analytics.SupersededCancels: 1, analytics.SupersededCancelMinutesEst: minutes})
}

// noteConcurrencySaved counts a save that added Runnir's suggested
// concurrency block to a workflow file that had none.
func (s *service) noteConcurrencySaved(ctx context.Context, repositoryID, workflowPath string, at time.Time) {
	if s.analytics == nil || s.workspaces == nil {
		return
	}
	rt, ok := s.workspaces.ForRepository(repositoryID)
	if !ok || rt.NoteConcurrencySaved(ctx, workflowPath, at) != nil {
		return
	}
	_ = s.analytics.Add(at, analytics.Counts{analytics.ConcurrencyInserted: 1})
}
