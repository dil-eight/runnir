package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// RunLimits are the limits chosen for a workspace's local runs.
type RunLimits struct {
	CPUs        int
	MemoryBytes uint64
	Timeout     time.Duration
}

// RunLimits reads the workspace's limits; false when none were chosen.
func (s *Store) RunLimits(ctx context.Context) (RunLimits, bool, error) {
	var l RunLimits
	var memory, seconds int64
	err := s.db.QueryRowContext(ctx, "SELECT cpus, memory_bytes, timeout_seconds FROM local_run_limits WHERE id = 1").Scan(&l.CPUs, &memory, &seconds)
	if errors.Is(err, sql.ErrNoRows) {
		return RunLimits{}, false, nil
	}
	if err != nil {
		return RunLimits{}, false, err
	}
	l.MemoryBytes, l.Timeout = uint64(memory), time.Duration(seconds)*time.Second
	return l, true, nil
}

// SetRunLimits keeps the workspace's limits; nil forgets them.
func (s *Store) SetRunLimits(ctx context.Context, l *RunLimits) error {
	if l == nil {
		_, err := s.db.ExecContext(ctx, "DELETE FROM local_run_limits")
		return err
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO local_run_limits (id, cpus, memory_bytes, timeout_seconds) VALUES (1, ?, ?, ?)
ON CONFLICT (id) DO UPDATE SET cpus = excluded.cpus, memory_bytes = excluded.memory_bytes, timeout_seconds = excluded.timeout_seconds`,
		l.CPUs, int64(l.MemoryBytes), int64(l.Timeout/time.Second))
	return err
}
