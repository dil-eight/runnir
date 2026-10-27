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
	IndexedRuns    int
}

func (s *Store) Usage(ctx context.Context) (Usage, error) {
	var u Usage
	var logBytes int64
	if err := s.db.QueryRowContext(ctx, `SELECT (SELECT COUNT(*) FROM runs), (SELECT COUNT(*) FROM local_runs),
	(SELECT COALESCE(SUM(size), 0) FROM blobs), (SELECT COUNT(*) FROM run_index)`).Scan(&u.CachedRuns, &u.LocalRuns, &logBytes, &u.IndexedRuns); err != nil {
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

// Peek reports what a workspace that is not open keeps, without opening it
// for writing: no lock, no migration, no recovery, no backup. It reads the
// database as it is on disk (closed stores are checkpointed). ok is false
// when nothing is on disk; a database it cannot read reports its sizes
// with a note.
func Peek(dir string) (u Usage, report Report, ok bool) {
	if info, err := os.Lstat(dir); err != nil || !info.IsDir() {
		return Usage{}, Report{}, false
	}
	path := filepath.Join(dir, databaseName)
	info, statErr := os.Lstat(path)
	regular := statErr == nil && info.Mode().IsRegular()
	report = Report{State: Persistent}
	for _, name := range []string{databaseName, databaseName + "-wal"} {
		if info, err := os.Lstat(filepath.Join(dir, name)); err == nil && info.Mode().IsRegular() {
			u.DatabaseBytes += uint64(info.Size())
		}
	}
	if entries, err := os.ReadDir(filepath.Join(dir, recoveryDir)); err == nil {
		for _, e := range entries {
			if e.IsDir() {
				u.RecoveryCopies++
			}
		}
	}
	if !regular {
		return u, report, true // no database yet, or not a file Runnir made
	}
	db, err := openDSN(fileURI(path, "mode=ro&immutable=1"))
	if err == nil {
		defer db.Close()
		var logBytes int64
		err = db.QueryRow(`SELECT (SELECT COUNT(*) FROM runs), (SELECT COUNT(*) FROM local_runs),
	(SELECT COALESCE(SUM(size), 0) FROM blobs), (SELECT COUNT(*) FROM run_index)`).Scan(&u.CachedRuns, &u.LocalRuns, &logBytes, &u.IndexedRuns)
		u.LogBytes = uint64(logBytes)
	}
	if err != nil {
		report.Note = "Its database could not be read now; it is checked when the workspace opens."
	}
	return u, report, true
}
