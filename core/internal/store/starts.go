package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// maxRunStarts bounds the attempts kept. A variable so tests can lower it.
var maxRunStarts = 5000

const startColumns = "server_id, repository, run_id, attempt, kind, sent_at"

// The kinds of RunStart.
const (
	StartDispatch    = "dispatch"
	StartRerun       = "rerun"
	StartRerunFailed = "rerun_failed"
	StartRerunJob    = "rerun_job"
)

// RunStart is an attempt of a run that Runnir started from this Mac: a
// dispatch starts attempt 1 of its run, a re-run GitHub accepted the next
// attempt. GitHub keeps no mark of it, so only this Mac knows.
type RunStart struct {
	Source  Source
	RunID   int64
	Attempt int64
	Kind    string
	SentAt  time.Time
}

// RecordStart keeps an attempt Runnir started. The first record of an
// attempt stands; only the newest maxRunStarts are kept.
func (s *Store) RecordStart(ctx context.Context, r RunStart) error {
	if r.RunID <= 0 || r.Attempt <= 0 {
		return errors.New("a run and an attempt are required")
	}
	result, err := s.db.ExecContext(ctx, "INSERT OR IGNORE INTO runnir_starts ("+startColumns+") VALUES (?, ?, ?, ?, ?, ?)",
		r.Source.ServerID, r.Source.Repository, r.RunID, r.Attempt, r.Kind, millis(r.SentAt))
	if err != nil {
		return err
	}
	if added, _ := result.RowsAffected(); added == 0 {
		return nil
	}
	return s.localChanged(ctx)
}

// RunStarts lists the attempts Runnir started of one repository's runs, by
// run, oldest attempt first.
func (s *Store) RunStarts(ctx context.Context, source Source) (map[int64][]RunStart, error) {
	starts, err := scanStarts(ctx, s.db, "SELECT "+startColumns+" FROM runnir_starts WHERE server_id = ? AND repository = ? ORDER BY run_id, attempt",
		source.ServerID, source.Repository)
	out := make(map[int64][]RunStart, len(starts))
	for _, r := range starts {
		out[r.RunID] = append(out[r.RunID], r)
	}
	return out, err
}

// keepNewestStarts drops the starts beyond maxRunStarts, oldest first.
func keepNewestStarts(ctx context.Context, db interface {
	ExecContext(context.Context, string, ...any) (sql.Result, error)
}) error {
	_, err := db.ExecContext(ctx, `
DELETE FROM runnir_starts WHERE rowid IN (
	SELECT rowid FROM runnir_starts ORDER BY sent_at DESC, rowid DESC LIMIT -1 OFFSET ?)`, maxRunStarts)
	return err
}

// dispatchStarted records the run of dispatch id as its attempt 1 that
// Runnir started, once the dispatch has its run.
func dispatchStarted(ctx context.Context, tx *sql.Tx, id int64) error {
	_, err := tx.ExecContext(ctx, `
INSERT OR IGNORE INTO runnir_starts (`+startColumns+`)
SELECT server_id, repository, run_id, 1, ?, sent_at FROM dispatch_history WHERE id = ? AND run_id > 0`, StartDispatch, id)
	return err
}

// scanStarts keeps the rows read before an error, like scanLocalRuns.
func scanStarts(ctx context.Context, db *sql.DB, query string, args ...any) ([]RunStart, error) {
	rows, err := db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []RunStart
	for rows.Next() {
		var r RunStart
		var sent int64
		if err := rows.Scan(&r.Source.ServerID, &r.Source.Repository, &r.RunID, &r.Attempt, &r.Kind, &sent); err != nil {
			return out, err
		}
		r.SentAt = fromMillis(sent)
		out = append(out, r)
	}
	return out, rows.Err()
}
