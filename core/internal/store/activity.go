package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"runnir/core/internal/github"
)

const maxRuns = 200

// Source is the GitHub repository cached activity belongs to.
type Source struct {
	ServerID   string // "" is github.com
	Repository string // "owner/name", lowercased
}

// RunsUpdate is one read of the newest runs.
type RunsUpdate struct {
	NotModified bool
	Runs        []github.Run // newest first; empty when NotModified
	// Complete means the page held every run of the repository, so any
	// cached run missing from it was deleted.
	Complete bool
	ETag     string
}

// WorkflowsUpdate is one read of the repository's workflows.
type WorkflowsUpdate struct {
	NotModified bool
	Workflows   []github.Workflow
	ETag        string
}

// Pass is what one sync pass learned. Access is the caller's status code
// for the pass; the store keeps it without interpreting it. OK means every
// read got an answer (data or not modified).
type Pass struct {
	Source     Source
	At         time.Time
	OK         bool
	Access     int32
	RetryAfter time.Time
	Runs       *RunsUpdate
	Workflows  *WorkflowsUpdate
}

// Activity is the cached activity and what the last passes said.
type Activity struct {
	Source    Source
	HasSource bool
	Runs      []github.Run
	Workflows []github.Workflow
	CheckedAt time.Time
	SyncedAt  time.Time
	ChangedAt time.Time
	// Access and RetryAfter are the last pass's; Access is 0 before one.
	Access     int32
	RetryAfter time.Time
}

const (
	scopeActivity  = "activity"
	scopeRuns      = "runs"
	scopeWorkflows = "workflows"
)

// ApplySync stores a pass in one transaction and reports whether cached
// rows changed. Data for another repository than the cached one replaces
// the cache; a pass without data never does.
func (s *Store) ApplySync(ctx context.Context, p Pass) (bool, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	changed := false
	hasData := (p.Runs != nil && !p.Runs.NotModified) || (p.Workflows != nil && !p.Workflows.NotModified)
	if hasData {
		current, has, err := readSource(ctx, tx)
		if err != nil {
			return false, err
		}
		if !has || current != p.Source {
			if err := clearCache(ctx, tx); err != nil {
				return false, err
			}
			if _, err := tx.ExecContext(ctx, "INSERT INTO cache_source (id, server_id, repository) VALUES (1, ?, ?)", p.Source.ServerID, p.Source.Repository); err != nil {
				return false, err
			}
			changed = true
		}
	}
	if p.Runs != nil {
		if !p.Runs.NotModified {
			c, err := applyRuns(ctx, tx, p.Runs.Runs, p.Runs.Complete)
			if err != nil {
				return false, err
			}
			changed = changed || c
		}
		if err := setETag(ctx, tx, scopeRuns, p.Runs.ETag); err != nil {
			return false, err
		}
	}
	if p.Workflows != nil {
		if !p.Workflows.NotModified {
			c, err := applyWorkflows(ctx, tx, p.Workflows.Workflows)
			if err != nil {
				return false, err
			}
			changed = changed || c
		}
		if err := setETag(ctx, tx, scopeWorkflows, p.Workflows.ETag); err != nil {
			return false, err
		}
	}
	at := millis(p.At)
	if _, err := tx.ExecContext(ctx, `
INSERT INTO sync_state (scope, checked_at, synced_at, changed_at, access, retry_after) VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT (scope) DO UPDATE SET
	checked_at = excluded.checked_at,
	synced_at = CASE WHEN ? THEN excluded.checked_at ELSE sync_state.synced_at END,
	changed_at = CASE WHEN ? THEN excluded.checked_at ELSE sync_state.changed_at END,
	access = excluded.access, retry_after = excluded.retry_after`,
		scopeActivity, at, okMillis(p.OK, at), okMillis(changed, at), p.Access, millis(p.RetryAfter), p.OK, changed); err != nil {
		return false, err
	}
	return changed, tx.Commit()
}

func okMillis(ok bool, at int64) int64 {
	if ok {
		return at
	}
	return 0
}

func readSource(ctx context.Context, q interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}) (Source, bool, error) {
	var src Source
	err := q.QueryRowContext(ctx, "SELECT server_id, repository FROM cache_source WHERE id = 1").Scan(&src.ServerID, &src.Repository)
	if errors.Is(err, sql.ErrNoRows) {
		return Source{}, false, nil
	}
	return src, err == nil, err
}

func setETag(ctx context.Context, tx *sql.Tx, scope, etag string) error {
	_, err := tx.ExecContext(ctx, `INSERT INTO sync_state (scope, etag) VALUES (?, ?)
ON CONFLICT (scope) DO UPDATE SET etag = excluded.etag`, scope, etag)
	return err
}

func idsJSON[T any](items []T, id func(T) int64) string {
	ids := make([]int64, 0, len(items))
	for _, item := range items {
		ids = append(ids, id(item))
	}
	data, _ := json.Marshal(ids)
	return string(data)
}

func applyRuns(ctx context.Context, tx *sql.Tx, runs []github.Run, complete bool) (bool, error) {
	changed := false
	for _, r := range runs {
		result, err := tx.ExecContext(ctx, `
INSERT INTO runs (id, workflow_id, name, display_title, run_number, run_attempt, event, status, conclusion, branch, head_sha, actor, html_url, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT (id) DO UPDATE SET
	workflow_id = excluded.workflow_id, name = excluded.name, display_title = excluded.display_title,
	run_number = excluded.run_number, run_attempt = excluded.run_attempt, event = excluded.event,
	status = excluded.status, conclusion = excluded.conclusion, branch = excluded.branch,
	head_sha = excluded.head_sha, actor = excluded.actor, html_url = excluded.html_url,
	created_at = excluded.created_at, updated_at = excluded.updated_at
WHERE (runs.workflow_id, runs.name, runs.display_title, runs.run_number, runs.run_attempt, runs.event, runs.status,
	runs.conclusion, runs.branch, runs.head_sha, runs.actor, runs.html_url, runs.created_at, runs.updated_at)
	<> (excluded.workflow_id, excluded.name, excluded.display_title, excluded.run_number, excluded.run_attempt, excluded.event,
	excluded.status, excluded.conclusion, excluded.branch, excluded.head_sha, excluded.actor, excluded.html_url,
	excluded.created_at, excluded.updated_at)`,
			r.ID, r.WorkflowID, r.Name, r.DisplayTitle, r.RunNumber, r.RunAttempt, r.Event, r.Status, r.Conclusion,
			r.Branch, r.HeadSHA, r.Actor, r.HTMLURL, millis(r.CreatedAt), millis(r.UpdatedAt))
		if err != nil {
			return false, err
		}
		if n, _ := result.RowsAffected(); n > 0 {
			changed = true
		}
	}
	ids := idsJSON(runs, func(r github.Run) int64 { return r.ID })
	var result sql.Result
	var err error
	switch {
	case complete:
		result, err = tx.ExecContext(ctx, "DELETE FROM runs WHERE id NOT IN (SELECT value FROM json_each(?))", ids)
	case len(runs) > 0:
		oldest := runs[0].CreatedAt
		for _, r := range runs {
			if r.CreatedAt.Before(oldest) {
				oldest = r.CreatedAt
			}
		}
		result, err = tx.ExecContext(ctx, "DELETE FROM runs WHERE created_at > ? AND id NOT IN (SELECT value FROM json_each(?))", millis(oldest), ids)
	}
	if err != nil {
		return false, err
	}
	if result != nil {
		if n, _ := result.RowsAffected(); n > 0 {
			changed = true
		}
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM runs WHERE id IN (
	SELECT id FROM runs ORDER BY created_at DESC, id DESC LIMIT -1 OFFSET ?)`, maxRuns); err != nil {
		return false, err
	}
	return changed, nil
}

func applyWorkflows(ctx context.Context, tx *sql.Tx, workflows []github.Workflow) (bool, error) {
	changed := false
	for i, w := range workflows {
		result, err := tx.ExecContext(ctx, `
INSERT INTO remote_workflows (id, position, name, path, state, html_url) VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT (id) DO UPDATE SET position = excluded.position, name = excluded.name, path = excluded.path,
	state = excluded.state, html_url = excluded.html_url
WHERE (remote_workflows.position, remote_workflows.name, remote_workflows.path, remote_workflows.state, remote_workflows.html_url)
	<> (excluded.position, excluded.name, excluded.path, excluded.state, excluded.html_url)`,
			w.ID, i, w.Name, w.Path, w.State, w.HTMLURL)
		if err != nil {
			return false, err
		}
		if n, _ := result.RowsAffected(); n > 0 {
			changed = true
		}
	}
	result, err := tx.ExecContext(ctx, "DELETE FROM remote_workflows WHERE id NOT IN (SELECT value FROM json_each(?))",
		idsJSON(workflows, func(w github.Workflow) int64 { return w.ID }))
	if err != nil {
		return false, err
	}
	if n, _ := result.RowsAffected(); n > 0 {
		changed = true
	}
	return changed, nil
}

// Activity reads the cached activity: up to limit newest runs.
func (s *Store) Activity(ctx context.Context, limit int) (Activity, error) {
	var a Activity
	var err error
	if a.Source, a.HasSource, err = readSource(ctx, s.db); err != nil {
		return Activity{}, err
	}
	if a.Runs, err = s.runs(ctx, "ORDER BY created_at DESC, id DESC LIMIT ?", limit); err != nil {
		return Activity{}, err
	}
	rows, err := s.db.QueryContext(ctx, "SELECT id, name, path, state, html_url FROM remote_workflows ORDER BY position, id")
	if err != nil {
		return Activity{}, err
	}
	defer rows.Close()
	for rows.Next() {
		var w github.Workflow
		if err := rows.Scan(&w.ID, &w.Name, &w.Path, &w.State, &w.HTMLURL); err != nil {
			return Activity{}, err
		}
		a.Workflows = append(a.Workflows, w)
	}
	if err := rows.Err(); err != nil {
		return Activity{}, err
	}
	var checked, synced, changed, retry int64
	err = s.db.QueryRowContext(ctx, "SELECT checked_at, synced_at, changed_at, access, retry_after FROM sync_state WHERE scope = ?", scopeActivity).
		Scan(&checked, &synced, &changed, &a.Access, &retry)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return Activity{}, err
	}
	a.CheckedAt, a.SyncedAt, a.ChangedAt, a.RetryAfter = fromMillis(checked), fromMillis(synced), fromMillis(changed), fromMillis(retry)
	return a, nil
}

const runColumns = "id, workflow_id, name, display_title, run_number, run_attempt, event, status, conclusion, branch, head_sha, actor, html_url, created_at, updated_at"

func (s *Store) runs(ctx context.Context, tail string, args ...any) ([]github.Run, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT "+runColumns+" FROM runs "+tail, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []github.Run
	for rows.Next() {
		var r github.Run
		var created, updated int64
		if err := rows.Scan(&r.ID, &r.WorkflowID, &r.Name, &r.DisplayTitle, &r.RunNumber, &r.RunAttempt, &r.Event, &r.Status,
			&r.Conclusion, &r.Branch, &r.HeadSHA, &r.Actor, &r.HTMLURL, &created, &updated); err != nil {
			return nil, err
		}
		r.CreatedAt, r.UpdatedAt = fromMillis(created), fromMillis(updated)
		out = append(out, r)
	}
	return out, rows.Err()
}

// ETags returns the stored ETags when the cache holds this repository's
// data, otherwise empty strings, so another repository's never match.
func (s *Store) ETags(ctx context.Context, src Source) (string, string, error) {
	current, has, err := readSource(ctx, s.db)
	if err != nil || !has || current != src {
		return "", "", err
	}
	tags := map[string]string{}
	rows, err := s.db.QueryContext(ctx, "SELECT scope, etag FROM sync_state WHERE scope IN (?, ?)", scopeRuns, scopeWorkflows)
	if err != nil {
		return "", "", err
	}
	defer rows.Close()
	for rows.Next() {
		var scope, etag string
		if err := rows.Scan(&scope, &etag); err != nil {
			return "", "", err
		}
		tags[scope] = etag
	}
	return tags[scopeRuns], tags[scopeWorkflows], rows.Err()
}

func clearCache(ctx context.Context, tx *sql.Tx) error {
	for _, statement := range []string{"DELETE FROM runs", "DELETE FROM remote_workflows", "DELETE FROM sync_state", "DELETE FROM cache_source"} {
		if _, err := tx.ExecContext(ctx, statement); err != nil {
			return err
		}
	}
	return nil
}

// CacheSource returns the repository the cached activity belongs to.
func (s *Store) CacheSource(ctx context.Context) (Source, bool, error) { return readSource(ctx, s.db) }
