package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"
)

const maxDispatchRecords = 200

const dispatchColumns = "id, workflow_path, ref, inputs, omitted, sent_at, run_id, server_id, repository"

// DispatchRecord is one workflow dispatch that GitHub accepted from this
// Mac, to the repository Source names. Inputs holds the values that were sent except those that look secret,
// whose names are in Omitted: a value like that is never written down.
type DispatchRecord struct {
	ID           int64
	Source       Source
	WorkflowPath string
	Ref          string
	Inputs       map[string]string
	Omitted      []string
	SentAt       time.Time
	// RunID is the run the dispatch started, 0 until it is known.
	RunID int64
}

// RecordDispatch adds an accepted dispatch, with its run when GitHub named
// it, and returns its id. A dispatch with its run is also attempt 1 Runnir
// started. Only the newest maxDispatchRecords are kept.
func (s *Store) RecordDispatch(ctx context.Context, r DispatchRecord) (int64, error) {
	inputs, err := json.Marshal(nonNilInputs(r.Inputs))
	if err != nil {
		return 0, err
	}
	omitted, err := json.Marshal(nonNilNames(r.Omitted))
	if err != nil {
		return 0, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
INSERT INTO dispatch_history (workflow_path, ref, inputs, omitted, sent_at, run_id, server_id, repository) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		r.WorkflowPath, r.Ref, string(inputs), string(omitted), millis(r.SentAt), max(r.RunID, 0), r.Source.ServerID, r.Source.Repository)
	if err != nil {
		return 0, err
	}
	id, err := result.LastInsertId()
	if err != nil {
		return 0, err
	}
	if err := dispatchStarted(ctx, tx, id); err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return id, s.localChanged(ctx)
}

// LinkDispatchRun says which run a dispatch started, which makes it attempt
// 1 Runnir started. The first answer is kept: a run found later by guessing
// must not replace one GitHub named.
func (s *Store) LinkDispatchRun(ctx context.Context, id, runID int64) error {
	if runID <= 0 {
		return errors.New("a run id is required")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, "UPDATE dispatch_history SET run_id = ? WHERE id = ? AND run_id = 0", runID, id)
	if err != nil {
		return err
	}
	if changed, _ := result.RowsAffected(); changed == 0 {
		return nil
	}
	if err := dispatchStarted(ctx, tx, id); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	return s.localChanged(ctx)
}

// ClearDispatchHistory forgets the dispatches sent to one repository and
// returns how many there were.
func (s *Store) ClearDispatchHistory(ctx context.Context, source Source) (int, error) {
	result, err := s.db.ExecContext(ctx, "DELETE FROM dispatch_history WHERE server_id = ? AND repository = ?", source.ServerID, source.Repository)
	if err != nil {
		return 0, err
	}
	removed, _ := result.RowsAffected()
	return int(removed), s.localChanged(ctx)
}

// DispatchHistory lists the dispatches sent to one repository, newest first,
// of one workflow or, for an empty path, of every workflow.
func (s *Store) DispatchHistory(ctx context.Context, source Source, workflowPath string, limit int) ([]DispatchRecord, error) {
	if limit <= 0 || limit > maxDispatchRecords {
		limit = maxDispatchRecords
	}
	query := "SELECT " + dispatchColumns + " FROM dispatch_history WHERE server_id = ? AND repository = ?"
	args := []any{source.ServerID, source.Repository}
	if workflowPath != "" {
		query += " AND workflow_path = ?"
		args = append(args, workflowPath)
	}
	query += " ORDER BY sent_at DESC, id DESC LIMIT ?"
	args = append(args, limit)
	return scanDispatches(ctx, s.db, query, args...)
}

// scanDispatches keeps the rows read before an error, like scanLocalRuns.
func scanDispatches(ctx context.Context, db *sql.DB, query string, args ...any) ([]DispatchRecord, error) {
	rows, err := db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []DispatchRecord
	for rows.Next() {
		var r DispatchRecord
		var inputs, omitted string
		var sent int64
		if err := rows.Scan(&r.ID, &r.WorkflowPath, &r.Ref, &inputs, &omitted, &sent, &r.RunID, &r.Source.ServerID, &r.Source.Repository); err != nil {
			return out, err
		}
		r.SentAt = fromMillis(sent)
		// A value that does not read back is shown as none rather than
		// hiding the rest of the history.
		_ = json.Unmarshal([]byte(inputs), &r.Inputs)
		_ = json.Unmarshal([]byte(omitted), &r.Omitted)
		if r.Inputs == nil {
			r.Inputs = map[string]string{}
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func nonNilInputs(m map[string]string) map[string]string {
	if m == nil {
		return map[string]string{}
	}
	return m
}

func nonNilNames(n []string) []string {
	if n == nil {
		return []string{}
	}
	return n
}
