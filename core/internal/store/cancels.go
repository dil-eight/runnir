package store

import (
	"context"
	"time"
)

// ConcurrencySave is a workflow file this Mac first saved with Runnir's
// suggested concurrency block.
type ConcurrencySave struct {
	WorkflowPath string
	SavedAt      time.Time
}

// AddConcurrencySave keeps the first save of the block into a workflow
// file; later saves change nothing.
func (s *Store) AddConcurrencySave(ctx context.Context, workflowPath string, at time.Time) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO concurrency_saves (workflow_path, saved_at) VALUES (?, ?)
ON CONFLICT (workflow_path) DO NOTHING`, workflowPath, millis(at))
	return err
}

// ConcurrencySaves lists the workflow files saved with the block.
func (s *Store) ConcurrencySaves(ctx context.Context) ([]ConcurrencySave, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT workflow_path, saved_at FROM concurrency_saves ORDER BY workflow_path`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ConcurrencySave
	for rows.Next() {
		var v ConcurrencySave
		var at int64
		if err := rows.Scan(&v.WorkflowPath, &at); err != nil {
			return nil, err
		}
		v.SavedAt = fromMillis(at)
		out = append(out, v)
	}
	return out, rows.Err()
}

// MarkCountedCancels records runs counted as cancelled by the block and
// returns those not recorded before.
func (s *Store) MarkCountedCancels(ctx context.Context, ids []int64) (map[int64]bool, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	fresh := map[int64]bool{}
	for _, id := range ids {
		result, err := tx.ExecContext(ctx, `INSERT OR IGNORE INTO counted_cancels (run_id) VALUES (?)`, id)
		if err != nil {
			return nil, err
		}
		if n, _ := result.RowsAffected(); n == 1 {
			fresh[id] = true
		}
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM counted_cancels WHERE run_id NOT IN
(SELECT run_id FROM counted_cancels ORDER BY run_id DESC LIMIT 10000)`); err != nil {
		return nil, err
	}
	return fresh, tx.Commit()
}
