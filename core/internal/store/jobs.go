package store

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"runnir/core/internal/github"
)

// CachedJobs are a run's jobs as last read, for one attempt.
type CachedJobs struct {
	Attempt   int64
	FetchedAt time.Time
	Jobs      []github.Job
}

// Run returns a cached run.
func (s *Store) Run(ctx context.Context, runID int64) (github.Run, bool, error) {
	runs, err := s.runs(ctx, "WHERE id = ?", runID)
	if err != nil || len(runs) == 0 {
		return github.Run{}, false, err
	}
	return runs[0], true, nil
}

// PutJobs replaces a cached run's jobs. Jobs of a run that is not cached
// are not stored: they would have nothing to belong to.
func (s *Store) PutJobs(ctx context.Context, runID, attempt int64, at time.Time, jobs []github.Job) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var exists int
	if err := tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM runs WHERE id = ?", runID).Scan(&exists); err != nil || exists == 0 {
		return err
	}
	if _, err := tx.ExecContext(ctx, "DELETE FROM run_jobs WHERE run_id = ?", runID); err != nil {
		return err
	}
	for i, j := range jobs {
		if _, err := tx.ExecContext(ctx, `INSERT OR REPLACE INTO run_jobs
(id, run_id, attempt, position, name, status, conclusion, html_url, started_at, completed_at, fetched_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			j.ID, runID, attempt, i, j.Name, j.Status, j.Conclusion, j.HTMLURL, millis(j.StartedAt), millis(j.CompletedAt), millis(at)); err != nil {
			return err
		}
		for _, step := range j.Steps {
			if _, err := tx.ExecContext(ctx, `INSERT OR REPLACE INTO run_steps
(job_id, number, name, status, conclusion, started_at, completed_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
				j.ID, step.Number, step.Name, step.Status, step.Conclusion, millis(step.StartedAt), millis(step.CompletedAt)); err != nil {
				return err
			}
		}
	}
	return tx.Commit()
}

// Jobs returns a run's cached jobs.
func (s *Store) Jobs(ctx context.Context, runID int64) (CachedJobs, bool, error) {
	jobs, attempt, fetched, err := s.jobs(ctx, "WHERE run_id = ? ORDER BY position", runID)
	if err != nil || len(jobs) == 0 {
		return CachedJobs{}, false, err
	}
	return CachedJobs{Attempt: attempt, FetchedAt: fetched, Jobs: jobs}, true, nil
}

// Job returns one cached job with its steps.
func (s *Store) Job(ctx context.Context, jobID int64) (github.Job, bool, error) {
	jobs, _, _, err := s.jobs(ctx, "WHERE id = ?", jobID)
	if err != nil || len(jobs) == 0 {
		return github.Job{}, false, err
	}
	return jobs[0], true, nil
}

// jobs reads jobs and their steps; attempt and fetched are the first job's,
// which every job of a run shares.
func (s *Store) jobs(ctx context.Context, tail string, args ...any) ([]github.Job, int64, time.Time, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT id, attempt, name, status, conclusion, html_url, started_at, completed_at, fetched_at FROM run_jobs "+tail, args...)
	if err != nil {
		return nil, 0, time.Time{}, err
	}
	var jobs []github.Job
	var attempt, fetched int64
	for rows.Next() {
		var j github.Job
		var started, completed int64
		if err := rows.Scan(&j.ID, &attempt, &j.Name, &j.Status, &j.Conclusion, &j.HTMLURL, &started, &completed, &fetched); err != nil {
			rows.Close()
			return nil, 0, time.Time{}, err
		}
		j.StartedAt, j.CompletedAt = fromMillis(started), fromMillis(completed)
		jobs = append(jobs, j)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, 0, time.Time{}, err
	}
	for i := range jobs {
		steps, err := s.db.QueryContext(ctx, "SELECT number, name, status, conclusion, started_at, completed_at FROM run_steps WHERE job_id = ? ORDER BY number", jobs[i].ID)
		if err != nil {
			return nil, 0, time.Time{}, err
		}
		for steps.Next() {
			var step github.Step
			var started, completed int64
			if err := steps.Scan(&step.Number, &step.Name, &step.Status, &step.Conclusion, &started, &completed); err != nil {
				steps.Close()
				return nil, 0, time.Time{}, err
			}
			step.StartedAt, step.CompletedAt = fromMillis(started), fromMillis(completed)
			jobs[i].Steps = append(jobs[i].Steps, step)
		}
		steps.Close()
		if err := steps.Err(); err != nil && !errors.Is(err, sql.ErrNoRows) {
			return nil, 0, time.Time{}, err
		}
	}
	return jobs, attempt, fromMillis(fetched), nil
}
