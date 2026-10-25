//go:build !windows

package store

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func record(t *testing.T, s *Store, id, state string) {
	t.Helper()
	if err := s.RecordLocalRun(context.Background(), LocalRun{ExecutionID: id, StartedAt: fixedNow(), State: state}); err != nil {
		t.Fatal(err)
	}
}

func recoveryDirs(t *testing.T, dir string) []string {
	t.Helper()
	entries, _ := os.ReadDir(filepath.Join(dir, "recovery"))
	var out []string
	for _, e := range entries {
		out = append(out, e.Name())
	}
	return out
}

func TestEveryLocalChangeIsBackedUp(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	record(t, s, "exec_1", LocalSucceeded)
	if err := s.AddSaving(context.Background(), SavingLocalRuns, 3, fixedNow()); err != nil {
		t.Fatal(err)
	}
	data, err := readLocalBackup(filepath.Join(dir, "backups", "local-data.sqlite"))
	if err != nil || len(data.runs) != 1 || data.runs[0].ExecutionID != "exec_1" ||
		len(data.savings) != 1 || data.savings[0].Minutes != 3 {
		t.Fatalf("backup = %+v, %v", data, err)
	}
	if _, err := os.Stat(filepath.Join(dir, "backups", "local-data.sqlite.tmp")); !os.IsNotExist(err) {
		t.Fatal("temporary backup left behind")
	}
}

func TestADamagedDatabaseIsKeptAsEvidenceAndLocalRunsSurvive(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	record(t, s, "exec_1", LocalSucceeded)
	record(t, s, "exec_2", LocalFailed)
	_ = s.Close()
	// Damage the header: SQLite then reports "file is not a database".
	path := filepath.Join(dir, "state.sqlite")
	data, _ := os.ReadFile(path)
	copy(data[:16], "garbage garbage!")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}

	again := openTest(t, dir)
	r := again.Report()
	if r.State != Persistent || !strings.Contains(r.Note, "damaged") || !strings.Contains(r.Note, "Restored 2 local run records") {
		t.Fatalf("report = %+v", r)
	}
	evidence := recoveryDirs(t, dir)
	if len(evidence) != 1 {
		t.Fatalf("recovery = %v", evidence)
	}
	kept, _ := os.ReadFile(filepath.Join(dir, "recovery", evidence[0], "state.sqlite"))
	if string(kept[:16]) != "garbage garbage!" {
		t.Fatal("evidence was changed")
	}
	runs, _ := again.LocalRuns(context.Background(), 10)
	if len(runs) != 2 {
		t.Fatalf("runs = %v", runs)
	}
}

func TestAMissingDatabaseIsRebuiltFromTheBackup(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	record(t, s, "exec_1", LocalSucceeded)
	_ = s.Close()
	for _, name := range []string{"state.sqlite", "state.sqlite-wal", "state.sqlite-shm"} {
		_ = os.Remove(filepath.Join(dir, name))
	}
	again := openTest(t, dir)
	if r := again.Report(); r.State != Persistent || r.Note != "The database was missing. Restored 1 local run records from the backup." {
		t.Fatalf("report = %+v", r)
	}
	if runs, _ := again.LocalRuns(context.Background(), 10); len(runs) != 1 {
		t.Fatalf("runs = %v", runs)
	}
}

func TestUnfinishedLocalRunsBecomeInterrupted(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	record(t, s, "exec_1", LocalRunning)
	record(t, s, "exec_2", LocalQueued)
	record(t, s, "exec_3", LocalSucceeded)
	_ = s.Close()
	again := openTest(t, dir)
	runs, _ := again.LocalRuns(context.Background(), 10)
	states := map[string]string{}
	for _, r := range runs {
		states[r.ExecutionID] = r.State
	}
	if states["exec_1"] != LocalInterrupted || states["exec_2"] != LocalInterrupted || states["exec_3"] != LocalSucceeded {
		t.Fatalf("states = %v", states)
	}
}

func TestAMigrationIsPrecededByACopyAndRolledBackOnFailure(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	record(t, s, "exec_1", LocalSucceeded)
	record(t, s, "exec_2", LocalSucceeded)
	_ = s.Close()

	saved := migrations
	t.Cleanup(func() { migrations = saved })
	// Fails on this database's rows only; a new memory store migrates fine.
	migrations = append(append([]string(nil), saved...), "CREATE TABLE extra (x INTEGER); CREATE UNIQUE INDEX one_state ON local_runs (state);")
	failed := openTest(t, dir)
	if r := failed.Report(); r.State != MemoryOnly || r.Note != "The workspace database could not be upgraded." {
		t.Fatalf("report = %+v", r)
	}
	_ = failed.Close()
	if _, err := os.Stat(filepath.Join(dir, "backups", "before-v1.sqlite")); err != nil {
		t.Fatal("no copy before the migration")
	}

	migrations = append(append([]string(nil), saved...), "CREATE TABLE extra (x INTEGER);")
	upgraded := openTest(t, dir)
	if v, _ := upgraded.userVersion(); v != len(saved)+1 || upgraded.Report().State != Persistent {
		t.Fatalf("version = %d, %+v", v, upgraded.Report())
	}
	if _, err := upgraded.db.Exec("SELECT x FROM extra"); err != nil {
		t.Fatal("the upgrade did not run:", err)
	}
	if runs, _ := upgraded.LocalRuns(context.Background(), 10); len(runs) != 2 {
		t.Fatal("local runs lost in the migration")
	}
}

func TestFoldersWithSpacesWork(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "Application Support", "Runnir", "ws")
	s := openTest(t, dir)
	record(t, s, "exec_1", LocalSucceeded)
	_ = s.Close()
	_ = os.Remove(filepath.Join(dir, "state.sqlite"))
	again := openTest(t, dir)
	if r := again.Report(); r.State != Persistent || !strings.Contains(r.Note, "Restored 1 local run records") {
		t.Fatalf("report = %+v", r)
	}
}

func TestAnEmptyDatabaseFileIsRebuiltFromTheBackup(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	record(t, s, "exec_1", LocalSucceeded)
	_ = s.Close()
	// A crash or a full disk can leave the file empty.
	if err := os.WriteFile(filepath.Join(dir, "state.sqlite"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	again := openTest(t, dir)
	if r := again.Report(); r.State != Persistent || r.Note != "The database was empty. Restored 1 local run records from the backup." {
		t.Fatalf("report = %+v", r)
	}
	if runs, _ := again.LocalRuns(context.Background(), 10); len(runs) != 1 {
		t.Fatalf("runs = %v", runs)
	}
	if backup, _ := readLocalBackup(filepath.Join(dir, "backups", "local-data.sqlite")); len(backup.runs) != 1 {
		t.Fatalf("backup replaced: %v", backup)
	}
}

func TestBackupsWrittenAtOnceAllSucceed(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	record(t, s, "exec_1", LocalSucceeded)
	var wg sync.WaitGroup
	errs := make(chan error, 8)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); errs <- s.writeLocalBackup(context.Background()) }()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	if backup, err := readLocalBackup(filepath.Join(dir, "backups", "local-data.sqlite")); err != nil || len(backup.runs) != 1 {
		t.Fatalf("backup = %v, %v", backup, err)
	}
}

func TestEveryDamageKeepsItsOwnEvidence(t *testing.T) {
	dir := t.TempDir()
	damage := func() {
		t.Helper()
		path := filepath.Join(dir, "state.sqlite")
		data, _ := os.ReadFile(path)
		copy(data[:16], "garbage garbage!")
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	s := openTest(t, dir) // the fixed clock gives both quarantines one stamp
	_ = s.Close()
	damage()
	_ = openTest(t, dir).Close()
	damage()
	_ = openTest(t, dir).Close()
	evidence := recoveryDirs(t, dir)
	if len(evidence) != 2 {
		t.Fatalf("recovery = %v", evidence)
	}
	for _, name := range evidence {
		if _, err := os.Stat(filepath.Join(dir, "recovery", name, "state.sqlite")); err != nil {
			t.Fatalf("%s lost its database: %v", name, err)
		}
	}
}

func TestADatabaseFromAnEarlierBuildIsReplacedAndLocalRunsSurvive(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	record(t, s, "exec_1", LocalSucceeded)
	record(t, s, "exec_2", LocalFailed)
	_ = s.Close()
	// An earlier development build made the same schema version without
	// the savings table.
	db, err := openFile(filepath.Join(dir, "state.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec("DROP TABLE savings"); err != nil {
		t.Fatal(err)
	}
	_ = db.Close()

	again := openTest(t, dir)
	r := again.Report()
	if r.State != Persistent || !strings.Contains(r.Note, "earlier build") || !strings.Contains(r.Note, "Restored 2 local run records") ||
		strings.Contains(r.Note, "backup of local data could not be written") {
		t.Fatalf("report = %+v", r)
	}
	if len(recoveryDirs(t, dir)) != 1 {
		t.Fatal("the earlier database was not kept")
	}
	runs, _ := again.LocalRuns(context.Background(), 10)
	if len(runs) != 2 {
		t.Fatalf("runs = %v", runs)
	}
	if err := again.writeLocalBackup(context.Background()); err != nil {
		t.Fatalf("backup = %v", err)
	}
}
