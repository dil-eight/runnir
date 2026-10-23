package store

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
)

const maxBlobBytes = 3 << 20

// logBudgetBytes bounds a workspace's kept logs; a variable for tests.
var logBudgetBytes int64 = 100 << 20

var ErrBlobTooLarge = errors.New("log is too large to keep")

var blobNamePattern = regexp.MustCompile(`^[0-9a-f]{64}\.log$`)

// LogMeta is what a kept log needs besides its text.
type LogMeta struct {
	DroppedLines int
	Truncated    bool
	StoppedEarly bool
}

func (s *Store) blobDir() string { return filepath.Join(s.dir, blobsDir) }

// PutLog keeps a completed job's log. The file is named by the SHA-256 of
// the job id and the content, written to a temporary file, synced and
// renamed; then the row is written and the budget enforced.
func (s *Store) PutLog(ctx context.Context, jobID int64, data []byte, meta LogMeta) error {
	if s.dir == "" {
		return nil
	}
	if len(data) > maxBlobBytes {
		return ErrBlobTooLarge
	}
	dir := s.blobDir()
	if err := makePrivateDir(dir); err != nil {
		return err
	}
	content := sha256.Sum256(data)
	nameSum := sha256.Sum256(append([]byte(fmt.Sprintf("%d\n", jobID)), data...))
	name := hex.EncodeToString(nameSum[:]) + ".log"
	temporary, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return err
	}
	_, writeErr := temporary.Write(data)
	syncErr := temporary.Sync()
	closeErr := temporary.Close()
	if err := errors.Join(writeErr, syncErr, closeErr, os.Chmod(temporary.Name(), 0o600)); err != nil {
		_ = os.Remove(temporary.Name())
		return err
	}
	if err := os.Rename(temporary.Name(), filepath.Join(dir, name)); err != nil {
		_ = os.Remove(temporary.Name())
		return err
	}
	syncDir(dir)

	var previous string
	_ = s.db.QueryRowContext(ctx, "SELECT name FROM blobs WHERE job_id = ?", jobID).Scan(&previous)
	now := millis(s.now())
	if _, err := s.db.ExecContext(ctx, `INSERT OR REPLACE INTO blobs
(job_id, name, size, sha256, dropped_lines, truncated, stopped_early, created_at, last_used_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		jobID, name, len(data), hex.EncodeToString(content[:]), meta.DroppedLines, meta.Truncated, meta.StoppedEarly, now, now); err != nil {
		return err
	}
	if previous != "" && previous != name {
		s.removeBlobFile(previous)
	}
	return s.enforceLogBudget(ctx)
}

func (s *Store) enforceLogBudget(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, "SELECT job_id, name, size FROM blobs ORDER BY last_used_at DESC, job_id DESC")
	if err != nil {
		return err
	}
	type entry struct {
		job  int64
		name string
	}
	var total int64
	var drop []entry
	for rows.Next() {
		var e entry
		var size int64
		if err := rows.Scan(&e.job, &e.name, &size); err != nil {
			rows.Close()
			return err
		}
		total += size
		if total > logBudgetBytes {
			drop = append(drop, e)
		}
	}
	rows.Close()
	for _, e := range drop {
		if _, err := s.db.ExecContext(ctx, "DELETE FROM blobs WHERE job_id = ?", e.job); err != nil {
			return err
		}
		s.removeBlobFile(e.name)
	}
	return rows.Err()
}

// Log returns a kept log. A row whose file is missing, not a regular file,
// or no longer matches its size and checksum is dropped and not served.
func (s *Store) Log(ctx context.Context, jobID int64) ([]byte, LogMeta, bool, error) {
	if s.dir == "" {
		return nil, LogMeta{}, false, nil
	}
	var name, sum string
	var size int64
	var meta LogMeta
	err := s.db.QueryRowContext(ctx, "SELECT name, size, sha256, dropped_lines, truncated, stopped_early FROM blobs WHERE job_id = ?", jobID).
		Scan(&name, &size, &sum, &meta.DroppedLines, &meta.Truncated, &meta.StoppedEarly)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, LogMeta{}, false, nil
	}
	if err != nil {
		return nil, LogMeta{}, false, err
	}
	data, ok := s.readBlob(name, size, sum)
	if !ok {
		_, _ = s.db.ExecContext(ctx, "DELETE FROM blobs WHERE job_id = ?", jobID)
		s.removeBlobFile(name)
		return nil, LogMeta{}, false, nil
	}
	_, _ = s.db.ExecContext(ctx, "UPDATE blobs SET last_used_at = ? WHERE job_id = ?", millis(s.now()), jobID)
	return data, meta, true, nil
}

func (s *Store) readBlob(name string, size int64, sum string) ([]byte, bool) {
	if !blobNamePattern.MatchString(name) || size > maxBlobBytes {
		return nil, false
	}
	path := filepath.Join(s.blobDir(), name)
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() != size {
		return nil, false
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, false
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, maxBlobBytes+1))
	if err != nil || int64(len(data)) != size {
		return nil, false
	}
	actual := sha256.Sum256(data)
	return data, hex.EncodeToString(actual[:]) == sum
}

// removeBlobFile removes a file in blobs/ by name; anything that is not a
// plain name of that folder is ignored.
func (s *Store) removeBlobFile(name string) {
	if name == "" || filepath.Base(name) != name || name == "." || name == ".." {
		return
	}
	_ = os.Remove(filepath.Join(s.blobDir(), name))
}

// DeleteLogs removes every kept log.
func (s *Store) DeleteLogs(ctx context.Context) error {
	if _, err := s.db.ExecContext(ctx, "DELETE FROM blobs"); err != nil {
		return err
	}
	if s.dir == "" {
		return nil
	}
	entries, err := os.ReadDir(s.blobDir())
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	for _, e := range entries {
		s.removeBlobFile(e.Name())
	}
	return err
}

// cleanBlobs drops rows whose files are gone and files without rows.
func (s *Store) cleanBlobs(ctx context.Context) error {
	if s.dir == "" {
		return nil
	}
	rows, err := s.db.QueryContext(ctx, "SELECT job_id, name, size FROM blobs")
	if err != nil {
		return err
	}
	known := map[string]bool{}
	var missing []int64
	for rows.Next() {
		var job, size int64
		var name string
		if err := rows.Scan(&job, &name, &size); err != nil {
			rows.Close()
			return err
		}
		info, statErr := os.Lstat(filepath.Join(s.blobDir(), name))
		if !blobNamePattern.MatchString(name) || statErr != nil || !info.Mode().IsRegular() || info.Size() != size {
			missing = append(missing, job)
			continue
		}
		known[name] = true
	}
	rows.Close()
	for _, job := range missing {
		if _, err := s.db.ExecContext(ctx, "DELETE FROM blobs WHERE job_id = ?", job); err != nil {
			return err
		}
	}
	entries, err := os.ReadDir(s.blobDir())
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	for _, e := range entries {
		if !known[e.Name()] {
			s.removeBlobFile(e.Name())
		}
	}
	return err
}

// DeleteKeptLogs removes the kept log files of a workspace that is not
// open; its rows are dropped when its store opens next.
func DeleteKeptLogs(dataDir, id string) error {
	id, ok := NormalizeWorkspaceID(id)
	if !ok {
		return ErrInvalidWorkspace
	}
	dir := filepath.Join(WorkspaceDir(dataDir, id), blobsDir)
	info, err := os.Lstat(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil || !info.IsDir() {
		return err
	}
	entries, err := os.ReadDir(dir)
	for _, e := range entries {
		if filepath.Base(e.Name()) == e.Name() {
			_ = os.Remove(filepath.Join(dir, e.Name()))
		}
	}
	return err
}
