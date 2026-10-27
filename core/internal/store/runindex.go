package store

import (
	"context"
	"database/sql"
	"encoding/json"

	"runnir/core/internal/github"
)

// MaxIndexedRuns is how many runs of one repository the search index keeps,
// the newest first.
var MaxIndexedRuns = 50000

const indexColumns = `id, workflow_id, name, display_title, run_number, run_attempt, event, status, conclusion, branch, head_sha,
	head_repository, commit_title, actor, html_url, created_at, updated_at, pulls`

// indexRun adds or refreshes a run in the search index.
func indexRun(ctx context.Context, tx *sql.Tx, src Source, r github.Run) error {
	pulls, err := json.Marshal(append([]int64{}, r.PullRequests...))
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `
INSERT INTO run_index (server_id, repository, `+indexColumns+`)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT (server_id, repository, id) DO UPDATE SET
	workflow_id = excluded.workflow_id, name = excluded.name, display_title = excluded.display_title,
	run_number = excluded.run_number, run_attempt = excluded.run_attempt, event = excluded.event, status = excluded.status,
	conclusion = excluded.conclusion, branch = excluded.branch, head_sha = excluded.head_sha,
	head_repository = excluded.head_repository, commit_title = excluded.commit_title, actor = excluded.actor,
	html_url = excluded.html_url, created_at = excluded.created_at, updated_at = excluded.updated_at,
	pulls = CASE WHEN excluded.pulls = '[]' THEN run_index.pulls ELSE excluded.pulls END`,
		src.ServerID, src.Repository, r.ID, r.WorkflowID, r.Name, r.DisplayTitle, r.RunNumber, r.RunAttempt, r.Event, r.Status,
		r.Conclusion, r.Branch, r.HeadSHA, r.HeadRepository, r.CommitTitle, r.Actor, r.HTMLURL, millis(r.CreatedAt), millis(r.UpdatedAt),
		string(pulls))
	return err
}

// evictIndex drops the oldest runs of a repository beyond the budget.
func evictIndex(ctx context.Context, tx *sql.Tx, src Source) error {
	_, err := tx.ExecContext(ctx, `
DELETE FROM run_index WHERE server_id = ? AND repository = ? AND id IN (
	SELECT id FROM run_index WHERE server_id = ? AND repository = ? ORDER BY created_at DESC, id DESC LIMIT -1 OFFSET ?)`,
		src.ServerID, src.Repository, src.ServerID, src.Repository, MaxIndexedRuns)
	return err
}

// IndexRuns adds runs read for a search to the index of src's repository.
func (s *Store) IndexRuns(ctx context.Context, src Source, runs []github.Run) error {
	if len(runs) == 0 {
		return nil
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, r := range runs {
		if err := indexRun(ctx, tx, src, r); err != nil {
			return err
		}
	}
	if err := evictIndex(ctx, tx, src); err != nil {
		return err
	}
	return tx.Commit()
}

// IndexSearch is what a search of the index found.
type IndexSearch struct {
	// Runs are the first matches, newest first, at most the limit asked for.
	Runs []github.Run
	// Looked counts the indexed runs looked at; Matched every match, also
	// those beyond the limit.
	Looked, Matched int
}

// SearchIndex returns the indexed runs of src's repository, newest first,
// that match accepts and that are not in skip (the runs of the activity
// cache, which are searched there).
func (s *Store) SearchIndex(ctx context.Context, src Source, skip map[int64]bool, limit int, match func(github.Run) bool) (IndexSearch, error) {
	var out IndexSearch
	rows, err := s.db.QueryContext(ctx, "SELECT "+indexColumns+" FROM run_index WHERE server_id = ? AND repository = ? ORDER BY created_at DESC, id DESC",
		src.ServerID, src.Repository)
	if err != nil {
		return out, err
	}
	defer rows.Close()
	for rows.Next() {
		var r github.Run
		var created, updated int64
		var pulls string
		if err := rows.Scan(&r.ID, &r.WorkflowID, &r.Name, &r.DisplayTitle, &r.RunNumber, &r.RunAttempt, &r.Event, &r.Status, &r.Conclusion,
			&r.Branch, &r.HeadSHA, &r.HeadRepository, &r.CommitTitle, &r.Actor, &r.HTMLURL, &created, &updated, &pulls); err != nil {
			return out, err
		}
		out.Looked++
		if skip[r.ID] {
			continue
		}
		r.CreatedAt, r.UpdatedAt = fromMillis(created), fromMillis(updated)
		_ = json.Unmarshal([]byte(pulls), &r.PullRequests)
		if !match(r) {
			continue
		}
		out.Matched++
		if limit <= 0 || len(out.Runs) < limit {
			out.Runs = append(out.Runs, r)
		}
	}
	return out, rows.Err()
}

// IndexedRuns counts the runs of every repository in the index.
func (s *Store) IndexedRuns(ctx context.Context) (int, error) {
	var n int
	err := s.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM run_index").Scan(&n)
	return n, err
}

// ClearRunIndex forgets every indexed run. The activity cache stays.
func (s *Store) ClearRunIndex(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, "DELETE FROM run_index")
	return err
}
