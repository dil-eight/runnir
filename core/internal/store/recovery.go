package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

const keptMigrationCopies = 3

const localColumns = "execution_id, workflow_path, job_id, event, started_at, finished_at, state, message, act_version, engine"

// writeLocalBackup copies the local tables to backups/local-data.sqlite:
// a temporary file is written, synced and renamed, then the folder synced.
func (s *Store) writeLocalBackup(ctx context.Context) error {
	if s.dir == "" {
		return nil
	}
	dir := filepath.Join(s.dir, backupsDir)
	if err := makePrivateDir(dir); err != nil {
		return err
	}
	temporary := filepath.Join(dir, localBackupName+".tmp")
	// Holding the store's only connection serializes backups: the shared
	// temporary file is removed and rewritten by one of them at a time.
	conn, err := s.db.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	_ = os.Remove(temporary)
	if _, err := conn.ExecContext(ctx, "ATTACH DATABASE ? AS backup", temporary); err != nil {
		return err
	}
	_, copyErr := conn.ExecContext(ctx, "CREATE TABLE backup.local_runs AS SELECT "+localColumns+" FROM main.local_runs")
	_, detachErr := conn.ExecContext(context.Background(), "DETACH DATABASE backup")
	if err := errors.Join(copyErr, detachErr); err != nil {
		_ = os.Remove(temporary)
		return err
	}
	if err := syncFile(temporary); err != nil {
		return err
	}
	if err := os.Rename(temporary, filepath.Join(dir, localBackupName)); err != nil {
		return err
	}
	syncDir(dir)
	return nil
}

func syncFile(path string) error {
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	_ = f.Chmod(0o600)
	syncErr := f.Sync()
	return errors.Join(syncErr, f.Close())
}

// readLocalBackup reads the local runs of a backup or of a salvage copy.
func readLocalBackup(path string) ([]LocalRun, error) {
	db, err := openDSN(fileURI(path, "mode=ro&_busy_timeout=1000"))
	if err != nil {
		return nil, err
	}
	defer db.Close()
	return scanLocalRuns(db, "SELECT "+localColumns+" FROM local_runs")
}

// scanLocalRuns keeps the rows read before an error: a damaged file may
// give some of them.
func scanLocalRuns(db *sql.DB, query string) ([]LocalRun, error) {
	rows, err := db.Query(query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []LocalRun
	for rows.Next() {
		var r LocalRun
		var started, finished int64
		if err := rows.Scan(&r.ExecutionID, &r.WorkflowPath, &r.JobID, &r.Event, &started, &finished, &r.State, &r.Message, &r.ActVersion, &r.Engine); err != nil {
			return out, err
		}
		r.StartedAt, r.FinishedAt = fromMillis(started), fromMillis(finished)
		out = append(out, r)
	}
	return out, rows.Err()
}

// quarantine moves the database files to recovery/<stamp>/, never deleting
// them, and salvages local runs from a copy so the evidence stays as found.
func (s *Store) quarantine() (string, []LocalRun, error) {
	stamp := s.now().UTC().Format("20060102T150405.000000000Z")
	if err := os.MkdirAll(filepath.Join(s.dir, recoveryDir), 0o700); err != nil {
		return "", nil, err
	}
	// A new folder every time: earlier evidence is never replaced, even
	// when two damages get the same stamp.
	target := filepath.Join(s.dir, recoveryDir, stamp)
	for n := 2; ; n++ {
		err := os.Mkdir(target, 0o700)
		if err == nil {
			break
		}
		if !errors.Is(err, os.ErrExist) || n > 1000 {
			return "", nil, err
		}
		target = filepath.Join(s.dir, recoveryDir, fmt.Sprintf("%s-%d", stamp, n))
	}
	moved := false
	for _, name := range []string{databaseName, databaseName + "-wal", databaseName + "-shm"} {
		from := filepath.Join(s.dir, name)
		if _, err := os.Lstat(from); errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err := os.Rename(from, filepath.Join(target, name)); err != nil {
			return "", nil, err
		}
		moved = true
	}
	syncDir(target)
	syncDir(s.dir)
	if !moved {
		_ = os.Remove(target)
		return "", nil, nil
	}
	return target, s.salvage(target), nil
}

func (s *Store) salvage(evidence string) []LocalRun {
	scratch, err := os.MkdirTemp(s.dir, ".salvage-")
	if err != nil {
		return nil
	}
	defer os.RemoveAll(scratch)
	for _, name := range []string{databaseName, databaseName + "-wal"} {
		if err := copyFile(filepath.Join(evidence, name), filepath.Join(scratch, name)); err != nil && name == databaseName {
			return nil
		}
	}
	db, err := openDSN(fileURI(filepath.Join(scratch, databaseName), "_busy_timeout=1000"))
	if err != nil {
		return nil
	}
	defer db.Close()
	runs, _ := scanLocalRuns(db, "SELECT "+localColumns+" FROM local_runs")
	return runs
}

func copyFile(from, to string) error {
	in, err := os.Open(from)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(to, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(out, in)
	return errors.Join(copyErr, out.Close())
}

// restoreLocal puts local runs back into a new database: the backup first,
// then rows salvaged from the damaged file, which are newer.
func (s *Store) restoreLocal(ctx context.Context, salvaged []LocalRun) (int, error) {
	byID := map[string]LocalRun{}
	backup, _ := readLocalBackup(filepath.Join(s.dir, backupsDir, localBackupName))
	for _, r := range backup {
		byID[r.ExecutionID] = r
	}
	for _, r := range salvaged {
		byID[r.ExecutionID] = r
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	for _, r := range byID {
		if _, err := tx.ExecContext(ctx, "INSERT OR REPLACE INTO local_runs ("+localColumns+") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
			r.ExecutionID, r.WorkflowPath, r.JobID, r.Event, millis(r.StartedAt), millis(r.FinishedAt), r.State, r.Message, r.ActVersion, r.Engine); err != nil {
			_ = tx.Rollback()
			return 0, err
		}
	}
	return len(byID), tx.Commit()
}

// backupBeforeMigration copies the database with VACUUM INTO and keeps the
// newest keptMigrationCopies copies.
func (s *Store) backupBeforeMigration(ctx context.Context, version int) error {
	dir := filepath.Join(s.dir, backupsDir)
	if err := makePrivateDir(dir); err != nil {
		return err
	}
	target := filepath.Join(dir, fmt.Sprintf("before-v%d.sqlite", version))
	_ = os.Remove(target)
	if _, err := s.db.ExecContext(ctx, "VACUUM INTO ?", target); err != nil {
		return err
	}
	if err := syncFile(target); err != nil {
		return err
	}
	entries, _ := os.ReadDir(dir)
	var versions []int
	for _, e := range entries {
		name := e.Name()
		if v, err := strconv.Atoi(strings.TrimSuffix(strings.TrimPrefix(name, "before-v"), ".sqlite")); err == nil && strings.HasPrefix(name, "before-v") {
			versions = append(versions, v)
		}
	}
	sort.Sort(sort.Reverse(sort.IntSlice(versions)))
	for _, v := range versions[min(len(versions), keptMigrationCopies):] {
		_ = os.Remove(filepath.Join(dir, fmt.Sprintf("before-v%d.sqlite", v)))
	}
	return nil
}

func (s *Store) markInterrupted(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, "UPDATE local_runs SET state = ? WHERE state IN (?, ?)", LocalInterrupted, LocalQueued, LocalRunning)
	return err
}
