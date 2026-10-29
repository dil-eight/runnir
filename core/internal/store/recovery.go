package store

import (
	"context"
	"database/sql"
	"encoding/json"
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

// localData is what exists only on this Mac.
type localData struct {
	runs       []LocalRun
	savings    []Saving
	dispatches []DispatchRecord
	starts     []RunStart
}

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
	if copyErr == nil {
		_, copyErr = conn.ExecContext(ctx, "CREATE TABLE backup.savings AS SELECT "+savingColumns+" FROM main.savings")
	}
	if copyErr == nil {
		_, copyErr = conn.ExecContext(ctx, "CREATE TABLE backup.dispatch_history AS SELECT "+dispatchColumns+" FROM main.dispatch_history")
	}
	if copyErr == nil {
		_, copyErr = conn.ExecContext(ctx, "CREATE TABLE backup.runnir_starts AS SELECT "+startColumns+" FROM main.runnir_starts")
	}
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

// readLocalBackup reads the local data of a backup.
func readLocalBackup(path string) (localData, error) {
	db, err := openDSN(fileURI(path, "mode=ro&_busy_timeout=1000"))
	if err != nil {
		return localData{}, err
	}
	defer db.Close()
	return scanLocal(db)
}

// scanLocal reads the local tables; a table that fails still gives the
// rows read before the error, and the others are read anyway.
func scanLocal(db *sql.DB) (localData, error) {
	runs, runsErr := scanLocalRuns(db, "SELECT "+localColumns+" FROM local_runs")
	savings, savingsErr := scanSavings(db, "SELECT "+savingColumns+" FROM savings")
	dispatches, dispatchesErr := scanDispatches(context.Background(), db, "SELECT "+dispatchColumns+" FROM dispatch_history")
	starts, startsErr := scanStarts(context.Background(), db, "SELECT "+startColumns+" FROM runnir_starts")
	return localData{runs: runs, savings: savings, dispatches: dispatches, starts: starts},
		errors.Join(runsErr, savingsErr, dispatchesErr, startsErr)
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
// them, and salvages local data from a copy so the evidence stays as found.
func (s *Store) quarantine() (string, localData, error) {
	stamp := s.now().UTC().Format("20060102T150405.000000000Z")
	if err := os.MkdirAll(filepath.Join(s.dir, recoveryDir), 0o700); err != nil {
		return "", localData{}, err
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
			return "", localData{}, err
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
			return "", localData{}, err
		}
		moved = true
	}
	syncDir(target)
	syncDir(s.dir)
	if !moved {
		_ = os.Remove(target)
		return "", localData{}, nil
	}
	return target, s.salvage(target), nil
}

func (s *Store) salvage(evidence string) localData {
	scratch, err := os.MkdirTemp(s.dir, ".salvage-")
	if err != nil {
		return localData{}
	}
	defer os.RemoveAll(scratch)
	for _, name := range []string{databaseName, databaseName + "-wal"} {
		if err := copyFile(filepath.Join(evidence, name), filepath.Join(scratch, name)); err != nil && name == databaseName {
			return localData{}
		}
	}
	db, err := openDSN(fileURI(filepath.Join(scratch, databaseName), "_busy_timeout=1000"))
	if err != nil {
		return localData{}
	}
	defer db.Close()
	data, _ := scanLocal(db)
	return data
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

// restoreLocal puts local data back into a new database and returns how
// many local run records it restored. Runs come from the backup first, then
// from rows salvaged from the damaged file, which are newer. A saving total
// only grows, so of the two the one with the higher count is kept.
func (s *Store) restoreLocal(ctx context.Context, salvaged localData) (int, error) {
	byID := map[string]LocalRun{}
	byKind := map[string]Saving{}
	byDispatch := map[int64]DispatchRecord{}
	var starts []RunStart
	backup, _ := readLocalBackup(filepath.Join(s.dir, backupsDir, localBackupName))
	for _, data := range []localData{backup, salvaged} {
		for _, r := range data.runs {
			byID[r.ExecutionID] = r
		}
		for _, v := range data.savings {
			if kept, ok := byKind[v.Kind]; !ok || v.Count >= kept.Count {
				byKind[v.Kind] = v
			}
		}
		for _, d := range data.dispatches {
			byDispatch[d.ID] = d
		}
		starts = append(starts, data.starts...)
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
	for _, v := range byKind {
		if _, err := tx.ExecContext(ctx, "INSERT OR REPLACE INTO savings ("+savingColumns+") VALUES (?, ?, ?, ?)",
			v.Kind, v.Minutes, v.Count, millis(v.Since)); err != nil {
			_ = tx.Rollback()
			return 0, err
		}
	}
	for _, d := range byDispatch {
		inputs, _ := json.Marshal(nonNilInputs(d.Inputs))
		omitted, _ := json.Marshal(nonNilNames(d.Omitted))
		if _, err := tx.ExecContext(ctx, "INSERT OR REPLACE INTO dispatch_history ("+dispatchColumns+") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
			d.ID, d.WorkflowPath, d.Ref, string(inputs), string(omitted), millis(d.SentAt), d.RunID, d.Source.ServerID, d.Source.Repository); err != nil {
			_ = tx.Rollback()
			return 0, err
		}
	}
	for _, r := range starts {
		if _, err := tx.ExecContext(ctx, "INSERT OR IGNORE INTO runnir_starts ("+startColumns+") VALUES (?, ?, ?, ?, ?, ?)",
			r.Source.ServerID, r.Source.Repository, r.RunID, r.Attempt, r.Kind, millis(r.SentAt)); err != nil {
			_ = tx.Rollback()
			return 0, err
		}
	}
	// The backup and the damaged file together may hold more than the budget.
	if err := keepNewestStarts(ctx, tx); err != nil {
		_ = tx.Rollback()
		return 0, err
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
