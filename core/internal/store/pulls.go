package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"time"

	"runnir/core/internal/github"
)

// PullRequestsUpdate is one read of the repository's pull requests.
type PullRequestsUpdate struct {
	NotModified bool
	// Refused: GitHub did not allow reading pull requests; Access says why.
	Refused      bool
	PullRequests []github.RepositoryPullRequest
	ETag         string
	// Access is the read's outcome, kept uninterpreted like Pass.Access.
	Access int32
}

// Lookup is the answer to one lookup: the pull requests found and their
// numbers, under the lookup's key ("pr:<n>", "commit:<sha>",
// "head:<owner/name>:<branch>"). Numbers may be empty: nothing was found,
// and the lookup is not repeated.
type Lookup struct {
	Key          string
	Numbers      []int64
	PullRequests []github.RepositoryPullRequest
}

// LookupsUpdate is what a pass's lookups learned.
type LookupsUpdate struct {
	Source  Source
	At      time.Time
	Lookups []Lookup
	// Non-zero: GitHub refused a lookup; kept as the pull requests' access.
	Access int32
}

// History is what the cache holds of a repository's runs.
type History struct {
	// Oldest is the created_at of the oldest cached run.
	Oldest   time.Time
	Count    int
	Complete bool
}

// Tags are the stored ETags of the reads a pass makes conditionally.
type Tags struct{ Runs, Workflows, Pulls string }

const scopePulls = "pulls"

// maxPullRequests are kept besides those a cached run or lookup names. A
// variable so tests can lower it.
var maxPullRequests = 500

func applyPulls(ctx context.Context, tx *sql.Tx, u *PullRequestsUpdate) (bool, error) {
	changed := false
	if !u.NotModified && !u.Refused {
		c, err := upsertPulls(ctx, tx, u.PullRequests)
		if err != nil {
			return false, err
		}
		changed = c
	}
	_, err := tx.ExecContext(ctx, `INSERT INTO sync_state (scope, etag, access) VALUES (?, ?, ?)
ON CONFLICT (scope) DO UPDATE SET etag = excluded.etag, access = excluded.access`, scopePulls, u.ETag, u.Access)
	return changed, err
}

func upsertPulls(ctx context.Context, tx *sql.Tx, pulls []github.RepositoryPullRequest) (bool, error) {
	changed := false
	for _, p := range pulls {
		result, err := tx.ExecContext(ctx, `
INSERT INTO pull_requests (number, title, state, draft, author, html_url, head_ref, head_sha, head_repository, base_ref,
	merge_commit_sha, created_at, updated_at, closed_at, merged_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT (number) DO UPDATE SET
	title = excluded.title, state = excluded.state, draft = excluded.draft, author = excluded.author,
	html_url = excluded.html_url, head_ref = excluded.head_ref, head_sha = excluded.head_sha,
	head_repository = excluded.head_repository, base_ref = excluded.base_ref, merge_commit_sha = excluded.merge_commit_sha,
	created_at = excluded.created_at, updated_at = excluded.updated_at, closed_at = excluded.closed_at,
	merged_at = excluded.merged_at
WHERE (pull_requests.title, pull_requests.state, pull_requests.draft, pull_requests.author, pull_requests.html_url,
	pull_requests.head_ref, pull_requests.head_sha, pull_requests.head_repository, pull_requests.base_ref,
	pull_requests.merge_commit_sha, pull_requests.created_at, pull_requests.updated_at, pull_requests.closed_at,
	pull_requests.merged_at)
	<> (excluded.title, excluded.state, excluded.draft, excluded.author, excluded.html_url, excluded.head_ref,
	excluded.head_sha, excluded.head_repository, excluded.base_ref, excluded.merge_commit_sha, excluded.created_at,
	excluded.updated_at, excluded.closed_at, excluded.merged_at)`,
			p.Number, p.Title, p.State, p.Draft, p.Author, p.HTMLURL, p.HeadRef, p.HeadSHA, p.HeadRepository, p.BaseRef,
			p.MergeCommitSHA, millis(p.CreatedAt), millis(p.UpdatedAt), millis(p.ClosedAt), millis(p.MergedAt))
		if err != nil {
			return false, err
		}
		if n, _ := result.RowsAffected(); n > 0 {
			changed = true
		}
	}
	return changed, nil
}

// trimLinks drops lookups no cached run needs any more, then pull requests
// that no cached run or lookup names, beyond the most recently updated.
func trimLinks(ctx context.Context, tx *sql.Tx) (bool, error) {
	changed := false
	for _, statement := range []statement{
		{`DELETE FROM link_lookups WHERE NOT (
	(key LIKE 'pr:%' AND CAST(substr(key, 4) AS INTEGER) IN (SELECT number FROM run_pull_requests))
	OR (key LIKE 'commit:%' AND substr(key, 8) IN (SELECT head_sha FROM runs))
	OR (key LIKE 'head:%' AND substr(key, 6) IN (SELECT head_repository || ':' || branch FROM runs)))`, nil},
		{`DELETE FROM pull_requests WHERE number NOT IN (SELECT number FROM run_pull_requests)
	AND number NOT IN (SELECT j.value FROM link_lookups, json_each(link_lookups.numbers) AS j)
	AND number NOT IN (SELECT number FROM pull_requests ORDER BY updated_at DESC, number DESC LIMIT ?)`, []any{maxPullRequests}},
	} {
		result, err := tx.ExecContext(ctx, statement.query, statement.args...)
		if err != nil {
			return false, err
		}
		if n, _ := result.RowsAffected(); n > 0 {
			changed = true
		}
	}
	return changed, nil
}

// ApplyLookups stores what lookups found, for the cached repository only,
// and reports whether rows changed.
func (s *Store) ApplyLookups(ctx context.Context, u LookupsUpdate) (bool, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	current, has, err := readSource(ctx, tx)
	if err != nil || !has || current != u.Source {
		return false, err
	}
	changed := false
	for _, l := range u.Lookups {
		c, err := upsertPulls(ctx, tx, l.PullRequests)
		if err != nil {
			return false, err
		}
		numbers := l.Numbers
		if numbers == nil {
			numbers = []int64{}
		}
		data, _ := json.Marshal(numbers)
		result, err := tx.ExecContext(ctx, `INSERT INTO link_lookups (key, numbers, fetched_at) VALUES (?, ?, ?)
ON CONFLICT (key) DO UPDATE SET numbers = excluded.numbers, fetched_at = excluded.fetched_at
WHERE link_lookups.numbers <> excluded.numbers`, l.Key, string(data), millis(u.At))
		if err != nil {
			return false, err
		}
		n, _ := result.RowsAffected()
		changed = changed || c || n > 0
	}
	if u.Access != 0 {
		if _, err := tx.ExecContext(ctx, `INSERT INTO sync_state (scope, access) VALUES (?, ?)
ON CONFLICT (scope) DO UPDATE SET access = excluded.access`, scopePulls, u.Access); err != nil {
			return false, err
		}
	}
	trimmed, err := trimLinks(ctx, tx)
	if err != nil {
		return false, err
	}
	return changed || trimmed, tx.Commit()
}

// History returns what is cached of src's runs; false when nothing is.
func (s *Store) History(ctx context.Context, src Source) (History, bool, error) {
	current, has, err := readSource(ctx, s.db)
	if err != nil || !has || current != src {
		return History{}, false, err
	}
	var h History
	var oldest sql.NullInt64
	if err := s.db.QueryRowContext(ctx, "SELECT MIN(created_at), COUNT(*) FROM runs").Scan(&oldest, &h.Count); err != nil {
		return History{}, false, err
	}
	if err := s.db.QueryRowContext(ctx, "SELECT history_complete FROM cache_source WHERE id = 1").Scan(&h.Complete); err != nil {
		return History{}, false, err
	}
	h.Oldest = fromMillis(oldest.Int64)
	return h, h.Count > 0, nil
}

// AddOlderRuns stores a page of src's runs created up to `before`, read to
// extend the history back. Cached runs after the page's oldest and up to
// `before` that the page lacks were deleted on GitHub. complete marks the
// history complete. It returns how many runs were not cached before.
func (s *Store) AddOlderRuns(ctx context.Context, src Source, before time.Time, runs []github.Run, complete bool) (int, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	current, has, err := readSource(ctx, tx)
	if err != nil || !has || current != src {
		return 0, err
	}
	added := 0
	for _, r := range runs {
		var cached int
		if err := tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM runs WHERE id = ?", r.ID).Scan(&cached); err != nil {
			return 0, err
		}
		if cached == 0 {
			added++
		}
		if _, err := upsertRun(ctx, tx, r); err != nil {
			return 0, err
		}
		if err := indexRun(ctx, tx, src, r); err != nil {
			return 0, err
		}
	}
	if err := evictIndex(ctx, tx, src); err != nil {
		return 0, err
	}
	if len(runs) > 0 {
		if _, err := tx.ExecContext(ctx, "DELETE FROM runs WHERE created_at > ? AND created_at <= ? AND id NOT IN (SELECT value FROM json_each(?))",
			millis(oldestCreated(runs)), millis(before), idsJSON(runs, func(r github.Run) int64 { return r.ID })); err != nil {
			return 0, err
		}
	}
	if complete {
		if _, err := setHistory(ctx, tx, true); err != nil {
			return 0, err
		}
	}
	trimmed, err := trimRuns(ctx, tx)
	if err != nil {
		return 0, err
	}
	if trimmed {
		if _, err := setHistory(ctx, tx, false); err != nil {
			return 0, err
		}
	}
	if _, err := trimLinks(ctx, tx); err != nil {
		return 0, err
	}
	return added, tx.Commit()
}

func (s *Store) pullRequests(ctx context.Context) ([]github.RepositoryPullRequest, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT number, title, state, draft, author, html_url, head_ref, head_sha, head_repository,
	base_ref, merge_commit_sha, created_at, updated_at, closed_at, merged_at FROM pull_requests ORDER BY updated_at DESC, number DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []github.RepositoryPullRequest
	for rows.Next() {
		var p github.RepositoryPullRequest
		var created, updated, closed, merged int64
		if err := rows.Scan(&p.Number, &p.Title, &p.State, &p.Draft, &p.Author, &p.HTMLURL, &p.HeadRef, &p.HeadSHA,
			&p.HeadRepository, &p.BaseRef, &p.MergeCommitSHA, &created, &updated, &closed, &merged); err != nil {
			return nil, err
		}
		p.CreatedAt, p.UpdatedAt, p.ClosedAt, p.MergedAt = fromMillis(created), fromMillis(updated), fromMillis(closed), fromMillis(merged)
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *Store) lookups(ctx context.Context) (map[string][]int64, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT key, numbers FROM link_lookups")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string][]int64{}
	for rows.Next() {
		var key, numbers string
		if err := rows.Scan(&key, &numbers); err != nil {
			return nil, err
		}
		var list []int64
		if err := json.Unmarshal([]byte(numbers), &list); err != nil {
			continue
		}
		out[key] = list
	}
	return out, rows.Err()
}
