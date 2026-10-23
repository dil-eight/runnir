package store

import (
	"context"
	"os"
	"path/filepath"
)

// Usage is what a workspace keeps on this Mac.
type Usage struct {
	DatabaseBytes  uint64 // state.sqlite and its WAL; the in-memory size for a memory store
	LogBytes       uint64
	CachedRuns     int
	LocalRuns      int
	RecoveryCopies int
}

func (s *Store) Usage(ctx context.Context) (Usage, error) {
	var u Usage
	var logBytes int64
	if err := s.db.QueryRowContext(ctx, `SELECT (SELECT COUNT(*) FROM runs), (SELECT COUNT(*) FROM local_runs),
	(SELECT COALESCE(SUM(size), 0) FROM blobs)`).Scan(&u.CachedRuns, &u.LocalRuns, &logBytes); err != nil {
		return Usage{}, err
	}
	u.LogBytes = uint64(logBytes)
	if s.dir == "" {
		var pages, size int64
		_ = s.db.QueryRowContext(ctx, "PRAGMA page_count").Scan(&pages)
		_ = s.db.QueryRowContext(ctx, "PRAGMA page_size").Scan(&size)
		u.DatabaseBytes = uint64(pages * size)
		return u, nil
	}
	for _, name := range []string{databaseName, databaseName + "-wal"} {
		if info, err := os.Lstat(filepath.Join(s.dir, name)); err == nil {
			u.DatabaseBytes += uint64(info.Size())
		}
	}
	if entries, err := os.ReadDir(filepath.Join(s.dir, recoveryDir)); err == nil {
		for _, e := range entries {
			if e.IsDir() {
				u.RecoveryCopies++
			}
		}
	}
	return u, nil
}

// ClearCache deletes everything that can be downloaded again: runs, jobs,
// steps, workflows, sync state and kept logs. Local runs, backups and
// recovery copies stay.
func (s *Store) ClearCache(ctx context.Context) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := clearCache(ctx, tx); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	return s.DeleteLogs(ctx)
}

// DeleteLogs is replaced by the blob store.
func (s *Store) DeleteLogs(context.Context) error { return nil }
