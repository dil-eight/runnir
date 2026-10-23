// Package store keeps one workspace's data in SQLite: GitHub activity that
// can be downloaded again (the cache) and records that exist only on this
// Mac (local run history). A Store is one database behind one connection,
// so all of its reads and writes are serialized; a file lock keeps other
// processes out of the same directory.
package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"modernc.org/sqlite"
)

const (
	databaseName    = "state.sqlite"
	lockName        = "lock"
	blobsDir        = "blobs"
	backupsDir      = "backups"
	recoveryDir     = "recovery"
	localBackupName = "local-data.sqlite"
	// pragmas apply to every connection: WAL, a full fsync on commit,
	// foreign keys, and write transactions that take the lock at once.
	pragmas = "_busy_timeout=5000&_foreign_keys=1&_journal_mode=WAL&_synchronous=FULL&_txlock=immediate"
)

// State says where a store keeps its data.
type State int

const (
	// Persistent stores live in their workspace directory.
	Persistent State = iota + 1
	// MemoryOnly stores live in this process only; Report.Note says why.
	MemoryOnly
)

// Report says how a store was opened. Note never holds a credential.
type Report struct {
	State State
	Note  string
}

type Options struct {
	// Now is the clock for recorded times; nil is time.Now.
	Now func() time.Time
}

// Store is safe for concurrent use: database/sql serializes callers on the
// single connection.
type Store struct {
	db     *sql.DB
	dir    string // "" for a memory store
	lock   *fileLock
	now    func() time.Time
	report Report

	closeOnce sync.Once
	closeErr  error
}

// Open opens the workspace database in dir, creating dir and the database
// when needed. A problem that keeps the file from being used never fails
// the open: the store then lives in memory and Report says why. dir "" asks
// for a memory store. The error is set only when not even a memory database
// can be made.
func Open(dir string, options Options) (*Store, error) {
	now := options.Now
	if now == nil {
		now = time.Now
	}
	if dir == "" {
		return openMemory(now, Report{State: MemoryOnly})
	}
	s, note := openDisk(dir, now)
	if s != nil {
		return s, nil
	}
	return openMemory(now, Report{State: MemoryOnly, Note: note})
}

func openMemory(now func() time.Time, report Report) (*Store, error) {
	db, err := openDSN("file::memory:?_busy_timeout=5000&_foreign_keys=1")
	if err != nil {
		return nil, err
	}
	s := &Store{db: db, now: now, report: report}
	if err := s.migrate(context.Background(), 0); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

func openDisk(dir string, now func() time.Time) (*Store, string) {
	if err := makePrivateDir(dir); err != nil {
		return nil, "The workspace folder could not be created."
	}
	lock, err := acquireLock(filepath.Join(dir, lockName))
	if errors.Is(err, errLocked) {
		return nil, "In use by another copy of Runnir."
	}
	if err != nil {
		return nil, "The workspace folder could not be locked."
	}
	s := &Store{dir: dir, lock: lock, now: now, report: Report{State: Persistent}}
	if note, ok := s.openDatabase(context.Background()); !ok {
		if s.db != nil {
			_ = s.db.Close()
		}
		lock.release()
		return nil, note
	}
	return s, ""
}

// openDatabase opens, checks, recovers and migrates state.sqlite.
func (s *Store) openDatabase(ctx context.Context) (string, bool) {
	path := filepath.Join(s.dir, databaseName)
	info, statErr := os.Lstat(path)
	if statErr == nil && !info.Mode().IsRegular() {
		return "The workspace database is not a regular file.", false
	}
	missing := errors.Is(statErr, os.ErrNotExist)
	var notes []string
	var salvaged []LocalRun
	damaged := false
	if missing {
		// A WAL without its database cannot be applied; keep it as evidence.
		if _, err := os.Lstat(path + "-wal"); err == nil {
			if _, _, err := s.quarantine(); err != nil {
				return "Leftover database files could not be moved aside.", false
			}
		}
	} else {
		db, err := openFile(path)
		if err == nil {
			err = quickCheck(db)
		}
		switch {
		case err == nil:
			s.db = db
		case isDamaged(err):
			if db != nil {
				_ = db.Close()
			}
			evidence, rows, moveErr := s.quarantine()
			if moveErr != nil {
				return "The damaged workspace database could not be moved aside.", false
			}
			salvaged, damaged = rows, true
			notes = append(notes, fmt.Sprintf("The database was damaged; it was kept in %s and a new one was made.",
				filepath.Join(recoveryDir, filepath.Base(evidence))))
		default:
			if db != nil {
				_ = db.Close()
			}
			return "The workspace database could not be opened.", false
		}
	}
	fresh := s.db == nil
	if fresh {
		db, err := openFile(path)
		if err != nil {
			return "The workspace database could not be created.", false
		}
		s.db = db
	}
	_ = os.Chmod(path, 0o600)
	version, err := s.userVersion()
	if err != nil {
		return "The workspace database could not be read.", false
	}
	if version > len(migrations) {
		return fmt.Sprintf("Made by a newer version of Runnir (schema %d).", version), false
	}
	if version > 0 && version < len(migrations) {
		if err := s.backupBeforeMigration(ctx, version); err != nil {
			return "A copy of the workspace database could not be made before upgrading it.", false
		}
	}
	if err := s.migrate(ctx, version); err != nil {
		return "The workspace database could not be upgraded.", false
	}
	if fresh {
		restored, err := s.restoreLocal(ctx, salvaged)
		if err != nil {
			return "Local run records could not be restored.", false
		}
		switch {
		case damaged && restored > 0:
			notes = append(notes, fmt.Sprintf("Restored %d local run records.", restored))
		case missing && restored > 0:
			notes = append(notes, fmt.Sprintf("The database was missing. Restored %d local run records from the backup.", restored))
		}
	}
	if err := s.markInterrupted(ctx); err != nil {
		return "The workspace database could not be updated.", false
	}
	if err := s.cleanBlobs(ctx); err != nil {
		return "The workspace database could not be updated.", false
	}
	if err := s.writeLocalBackup(ctx); err != nil {
		notes = append(notes, "The backup of local data could not be written.")
	}
	s.report.Note = joinNotes(notes)
	return "", true
}

// Report says how the store was opened.
func (s *Store) Report() Report { return s.report }

// Dir is the workspace directory; "" for a memory store.
func (s *Store) Dir() string { return s.dir }

// Close checkpoints the WAL, closes the database and releases the lock.
// Calling it again does nothing.
func (s *Store) Close() error {
	s.closeOnce.Do(func() {
		if s.dir != "" {
			_ = s.writeLocalBackup(context.Background())
			_, _ = s.db.Exec("PRAGMA wal_checkpoint(TRUNCATE)")
		}
		s.closeErr = s.db.Close()
		if s.lock != nil {
			s.lock.release()
		}
	})
	return s.closeErr
}

// fileURI is a file: URI for path, so folders such as "Application Support"
// are escaped, with SQLite or driver parameters in query.
func fileURI(path, query string) string {
	return (&url.URL{Scheme: "file", Path: filepath.ToSlash(path), RawQuery: query}).String()
}

func openFile(path string) (*sql.DB, error) { return openDSN(fileURI(path, pragmas)) }

// openDSN opens a pool of exactly one long-lived connection, which is what
// makes the store a single serialized writer.
func openDSN(dsn string) (*sql.DB, error) {
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(0)
	db.SetConnMaxIdleTime(0)
	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, err
	}
	return db, nil
}

var errDamaged = errors.New("database is damaged")

func quickCheck(db *sql.DB) error {
	var result string
	if err := db.QueryRow("PRAGMA quick_check").Scan(&result); err != nil {
		return err
	}
	if result != "ok" {
		return errDamaged
	}
	return nil
}

// isDamaged recognizes SQLite's corrupt and not-a-database errors.
func isDamaged(err error) bool {
	if errors.Is(err, errDamaged) {
		return true
	}
	var sqliteErr *sqlite.Error
	if errors.As(err, &sqliteErr) {
		switch sqliteErr.Code() & 0xff {
		case 11, 26: // SQLITE_CORRUPT, SQLITE_NOTADB
			return true
		}
	}
	return false
}

func (s *Store) userVersion() (int, error) {
	var version int
	err := s.db.QueryRow("PRAGMA user_version").Scan(&version)
	return version, err
}

func (s *Store) migrate(ctx context.Context, from int) error {
	for version := from; version < len(migrations); version++ {
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, migrations[version]); err != nil {
			_ = tx.Rollback()
			return err
		}
		if _, err := tx.ExecContext(ctx, fmt.Sprintf("PRAGMA user_version = %d", version+1)); err != nil {
			_ = tx.Rollback()
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
	}
	return nil
}

// makePrivateDir creates dir with mode 0700 and refuses a symlink or a file.
func makePrivateDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("%s is not a directory", filepath.Base(dir))
	}
	return os.Chmod(dir, 0o700)
}

// syncDir makes a rename in dir durable.
func syncDir(dir string) {
	if f, err := os.Open(dir); err == nil {
		_ = f.Sync()
		_ = f.Close()
	}
}

func millis(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.UnixMilli()
}

func fromMillis(ms int64) time.Time {
	if ms == 0 {
		return time.Time{}
	}
	return time.UnixMilli(ms).UTC()
}

// joinNotes joins the sentences of a Report note.
func joinNotes(notes []string) string { return strings.Join(notes, " ") }
