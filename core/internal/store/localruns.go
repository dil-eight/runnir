package store

import (
	"context"
	"time"
)

// Local run states, as stored.
const (
	LocalQueued      = "queued"
	LocalRunning     = "running"
	LocalSucceeded   = "succeeded"
	LocalFailed      = "failed"
	LocalCancelled   = "cancelled"
	LocalInterrupted = "interrupted"
)

const maxLocalRuns = 200

// LocalRun is the summary of one local act run; its output is never stored.
type LocalRun struct {
	ExecutionID  string
	WorkflowPath string
	// JobID is the chosen job; empty ran every job.
	JobID      string
	Event      string
	StartedAt  time.Time
	FinishedAt time.Time
	State      string
	Message    string
	ActVersion string
	Engine     string
}

func terminal(state string) bool {
	switch state {
	case LocalSucceeded, LocalFailed, LocalCancelled, LocalInterrupted:
		return true
	}
	return false
}

// RecordLocalRun adds a run. When an event already created its row, only
// the details are filled in: the state and times events set are kept.
func (s *Store) RecordLocalRun(ctx context.Context, r LocalRun) error {
	_, err := s.db.ExecContext(ctx, `
INSERT INTO local_runs (execution_id, workflow_path, job_id, event, started_at, finished_at, state, message, act_version, engine)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT (execution_id) DO UPDATE SET
	workflow_path = excluded.workflow_path, job_id = excluded.job_id, event = excluded.event,
	started_at = CASE WHEN local_runs.started_at = 0 THEN excluded.started_at ELSE local_runs.started_at END,
	act_version = excluded.act_version, engine = excluded.engine`,
		r.ExecutionID, r.WorkflowPath, r.JobID, r.Event, millis(r.StartedAt), millis(r.FinishedAt), r.State, r.Message, r.ActVersion, r.Engine)
	if err != nil {
		return err
	}
	return s.localChanged(ctx)
}

// UpdateLocalRun records a run's new state; terminal states also set when it
// finished. A run not recorded yet gets a row.
func (s *Store) UpdateLocalRun(ctx context.Context, executionID, state string, at time.Time, message string) error {
	finished := int64(0)
	if terminal(state) {
		finished = millis(at)
	}
	_, err := s.db.ExecContext(ctx, `
INSERT INTO local_runs (execution_id, started_at, finished_at, state, message) VALUES (?, ?, ?, ?, ?)
ON CONFLICT (execution_id) DO UPDATE SET
	state = excluded.state,
	finished_at = CASE WHEN excluded.finished_at = 0 THEN local_runs.finished_at ELSE excluded.finished_at END,
	message = CASE WHEN excluded.message = '' THEN local_runs.message ELSE excluded.message END`,
		executionID, millis(at), finished, state, message)
	if err != nil {
		return err
	}
	return s.localChanged(ctx)
}

// LocalRuns lists recorded runs, newest first.
func (s *Store) LocalRuns(ctx context.Context, limit int) ([]LocalRun, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT execution_id, workflow_path, job_id, event, started_at, finished_at, state, message, act_version, engine
FROM local_runs ORDER BY started_at DESC, execution_id DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []LocalRun
	for rows.Next() {
		var r LocalRun
		var started, finished int64
		if err := rows.Scan(&r.ExecutionID, &r.WorkflowPath, &r.JobID, &r.Event, &started, &finished, &r.State, &r.Message, &r.ActVersion, &r.Engine); err != nil {
			return nil, err
		}
		r.StartedAt, r.FinishedAt = fromMillis(started), fromMillis(finished)
		out = append(out, r)
	}
	return out, rows.Err()
}

// localChanged enforces the budgets and writes the backup of local data.
func (s *Store) localChanged(ctx context.Context) error {
	if _, err := s.db.ExecContext(ctx, `
DELETE FROM local_runs WHERE execution_id IN (
	SELECT execution_id FROM local_runs ORDER BY started_at DESC, execution_id DESC LIMIT -1 OFFSET ?)`, maxLocalRuns); err != nil {
		return err
	}
	if _, err := s.db.ExecContext(ctx, `
DELETE FROM dispatch_history WHERE id IN (
	SELECT id FROM dispatch_history ORDER BY sent_at DESC, id DESC LIMIT -1 OFFSET ?)`, maxDispatchRecords); err != nil {
		return err
	}
	return s.writeLocalBackup(ctx)
}
