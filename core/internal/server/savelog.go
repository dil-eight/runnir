package server

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
)

// saveLogBudget bounds SaveJobLog's download, which reads the whole log; the
// app waits a little longer. A variable so tests can shorten it.
var saveLogBudget = 5 * time.Minute

var unsafeName = regexp.MustCompile(`[^A-Za-z0-9._-]+`)

// SaveJobLog writes a job's whole log to runnir-logs in the user's temporary
// folder, named after the repository and job, for the app to open in an
// editor. The file is written whole before it replaces an earlier one.
func (s *service) SaveJobLog(ctx context.Context, request *corev1.SaveJobLogRequest) (*corev1.SaveJobLogResponse, error) {
	jobID := request.GetJobId()
	if jobID <= 0 {
		return nil, status.Error(codes.InvalidArgument, "job_id is required")
	}
	target, problem, err := s.githubTarget(request.GetRepositoryId(), "", "")
	if err != nil || problem != nil {
		return &corev1.SaveJobLogResponse{Status: problem}, err
	}
	dir := filepath.Join(os.TempDir(), "runnir-logs")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, status.Error(codes.Internal, "the log folder could not be created")
	}
	file, err := os.CreateTemp(dir, ".job-*.log")
	if err != nil {
		return nil, status.Error(codes.Internal, "the log file could not be created")
	}
	temporary := file.Name()
	written := false
	defer func() {
		if !written {
			_ = os.Remove(temporary)
		}
	}()

	logCtx, cancel := context.WithTimeout(ctx, saveLogBudget)
	saved, saveErr := target.account.Client.SaveJobLog(logCtx, target.owner, target.name, jobID, file)
	cancel()
	closeErr := file.Close()
	if errors.Is(saveErr, context.DeadlineExceeded) && ctx.Err() == nil {
		saveErr = github.ErrUnavailable
	}
	if errors.Is(saveErr, github.ErrLogUnavailable) {
		return &corev1.SaveJobLogResponse{
			Status:       statusMessage(corev1.GithubAccess_GITHUB_ACCESS_OK, time.Time{}),
			Availability: corev1.JobLogAvailability_JOB_LOG_AVAILABILITY_EXPIRED,
		}, nil
	}
	result, err := s.githubStatus(target.account, saveErr)
	if err != nil {
		return nil, err
	}
	if saveErr != nil {
		return &corev1.SaveJobLogResponse{Status: result}, nil
	}
	if closeErr != nil {
		return nil, status.Error(codes.Internal, "the log file could not be written")
	}
	name := fmt.Sprintf("%s-%s-job-%d.log", unsafeName.ReplaceAllString(target.owner, "-"), unsafeName.ReplaceAllString(target.name, "-"), jobID)
	path := filepath.Join(dir, name)
	if err := os.Rename(temporary, path); err != nil {
		return nil, status.Error(codes.Internal, "the log file could not be written")
	}
	written = true
	return &corev1.SaveJobLogResponse{
		Status:       result,
		Availability: corev1.JobLogAvailability_JOB_LOG_AVAILABILITY_AVAILABLE,
		Path:         path,
		StoppedEarly: saved.StoppedEarly,
	}, nil
}
