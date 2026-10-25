package store

import (
	"context"
	"database/sql"
	"time"
)

// Saving kinds, as stored: one running total for each thing Runnir counts
// as saved.
const (
	// SavingLocalRuns counts local runs that ended with a result, in the
	// minutes GitHub would have billed for their jobs.
	SavingLocalRuns = "local_runs"
)

const savingColumns = "kind, minutes, count, since"

// Saving is the running total of one kind.
type Saving struct {
	Kind    string
	Minutes int64
	Count   int64
	// Since is when the first one was counted.
	Since time.Time
}

// AddSaving adds minutes and one to the count of a kind's total. Like local
// runs, savings exist only on this Mac: they are backed up and Clear Cache
// keeps them.
func (s *Store) AddSaving(ctx context.Context, kind string, minutes int64, at time.Time) error {
	_, err := s.db.ExecContext(ctx, `
INSERT INTO savings (`+savingColumns+`) VALUES (?, ?, 1, ?)
ON CONFLICT (kind) DO UPDATE SET minutes = savings.minutes + excluded.minutes, count = savings.count + 1`,
		kind, minutes, millis(at))
	if err != nil {
		return err
	}
	return s.writeLocalBackup(ctx)
}

// Savings lists every kind with something counted, by kind.
func (s *Store) Savings(ctx context.Context) ([]Saving, error) {
	return scanSavings(s.db, "SELECT "+savingColumns+" FROM savings ORDER BY kind")
}

// scanSavings keeps the rows read before an error, like scanLocalRuns.
func scanSavings(db *sql.DB, query string) ([]Saving, error) {
	rows, err := db.Query(query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Saving
	for rows.Next() {
		var v Saving
		var since int64
		if err := rows.Scan(&v.Kind, &v.Minutes, &v.Count, &since); err != nil {
			return out, err
		}
		v.Since = fromMillis(since)
		out = append(out, v)
	}
	return out, rows.Err()
}
