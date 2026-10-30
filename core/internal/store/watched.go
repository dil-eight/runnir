package store

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"runnir/core/internal/github"
)

// Watched is what the watcher of B39 reads of an open workspace.
type Watched struct {
	Source    Source
	HasSource bool
	// SyncedAt is when a pass last reached GitHub; zero for never.
	SyncedAt time.Time
	// Runs are the actor's newest saved runs, newest first.
	Runs []github.Run
}

// WatchedRuns reads the newest limit saved runs actor started, matched
// without case, and when a pass last reached GitHub.
func (s *Store) WatchedRuns(ctx context.Context, actor string, limit int) (Watched, error) {
	var w Watched
	var err error
	if w.Source, w.HasSource, err = readSource(ctx, s.db); err != nil || !w.HasSource {
		return w, err
	}
	var synced int64
	err = s.db.QueryRowContext(ctx, "SELECT synced_at FROM sync_state WHERE scope = ?", scopeActivity).Scan(&synced)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return Watched{}, err
	}
	w.SyncedAt = fromMillis(synced)
	w.Runs, err = s.scanRuns(ctx, "WHERE actor = ? COLLATE NOCASE ORDER BY created_at DESC, id DESC LIMIT ?", actor, limit)
	return w, err
}
