package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// JobReferences finds, for each name, the GitHub duration of the latest
// completed job with that name (succeeded or failed) in a cached run of the
// workflow at path. Names without one are absent.
func (s *Store) JobReferences(ctx context.Context, workflowPath string, names []string) (map[string]time.Duration, error) {
	out := map[string]time.Duration{}
	if len(names) == 0 {
		return out, nil
	}
	want := map[string]bool{}
	for _, name := range names {
		want[name] = true
	}
	rows, err := s.db.QueryContext(ctx, `SELECT j.name, j.started_at, j.completed_at FROM run_jobs j
JOIN runs r ON r.id = j.run_id
JOIN remote_workflows w ON w.id = r.workflow_id
WHERE w.path = ? AND j.status = 'completed' AND j.conclusion IN ('success', 'failure')
	AND j.started_at > 0 AND j.completed_at >= j.started_at
ORDER BY j.completed_at DESC, j.id DESC`, workflowPath)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var name string
		var started, completed int64
		if err := rows.Scan(&name, &started, &completed); err != nil {
			return nil, err
		}
		if _, seen := out[name]; want[name] && !seen {
			out[name] = time.Duration(completed-started) * time.Millisecond
		}
	}
	return out, rows.Err()
}

// RunReference is the latest completed run (succeeded or failed) of the
// workflow at path: from its creation to its last update, queue included.
func (s *Store) RunReference(ctx context.Context, workflowPath string) (time.Duration, bool, error) {
	var created, updated int64
	err := s.db.QueryRowContext(ctx, `SELECT r.created_at, r.updated_at FROM runs r
JOIN remote_workflows w ON w.id = r.workflow_id
WHERE w.path = ? AND r.status = 'completed' AND r.conclusion IN ('success', 'failure') AND r.updated_at >= r.created_at
ORDER BY r.created_at DESC, r.id DESC LIMIT 1`, workflowPath).Scan(&created, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	return time.Duration(updated-created) * time.Millisecond, true, nil
}
