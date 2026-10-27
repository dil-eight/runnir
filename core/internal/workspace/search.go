package workspace

import (
	"context"
	"net/url"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/runsearch"
	"runnir/core/internal/store"
)

// SavedSearch is what a search over this Mac's data found.
type SavedSearch struct {
	// Cached are the ids of the matching runs of the activity cache, newest first.
	Cached []int64
	// Indexed are the matching runs only the search index knows: older than
	// the cache, dropped from it, or deleted on GitHub.
	Indexed []github.Run
	// CachedSearched and IndexedSearched count the runs looked at.
	CachedSearched, IndexedSearched int
}

// record is a run as a query is matched against it: with the pull requests
// it is linked to and their text.
func record(run github.Run, extra []int64, text map[int64][]string) runsearch.Record {
	numbers := append([]int64(nil), run.PullRequests...)
	numbers = append(numbers, extra...)
	rec := runsearch.Record{
		ID: run.ID, RunNumber: run.RunNumber, Title: run.DisplayTitle, Workflow: run.Name, CommitTitle: run.CommitTitle,
		Branch: run.Branch, SHA: run.HeadSHA, Author: run.Actor, Event: run.Event, Status: run.Status, Conclusion: run.Conclusion,
		CreatedAt: run.CreatedAt, PullRequests: numbers,
	}
	for _, number := range numbers {
		rec.PullRequestText = append(rec.PullRequestText, text[number]...)
	}
	return rec
}

// SearchSaved searches the activity cache and the search index. Both are
// read from this Mac: nothing goes to GitHub, so it works offline.
func (r *Runtime) SearchSaved(ctx context.Context, q runsearch.Query, limit int) (SavedSearch, error) {
	var out SavedSearch
	if !q.Active() {
		return out, nil
	}
	snap, err := r.Snapshot(ctx, store.MaxRuns)
	if err != nil {
		return out, err
	}
	text := map[int64][]string{}
	for _, p := range snap.PullRequests {
		text[p.Number] = []string{p.Title, p.Author, p.HeadRef, p.BaseRef, p.State}
	}
	skip := make(map[int64]bool, len(snap.Runs))
	for _, run := range snap.Runs {
		skip[run.ID] = true
		var extra []int64
		if link := snap.Analysis.Links[run.ID]; link.PullRequest > 0 {
			extra = []int64{link.PullRequest}
		}
		if q.Matches(record(run, extra, text)) {
			out.Cached = append(out.Cached, run.ID)
		}
	}
	out.CachedSearched = len(snap.Runs)
	source, ok := r.searchSource(ctx)
	if !ok {
		return out, nil
	}
	indexed, looked, err := r.cfg.store.SearchIndex(ctx, source, skip, limit, func(run github.Run) bool {
		return q.Matches(record(run, nil, text))
	})
	if err != nil {
		return out, err
	}
	out.Indexed, out.IndexedSearched = indexed, looked
	return out, nil
}

// searchSource is the repository the search is about: the origin's now, or
// the one the cache holds when the origin names none.
func (r *Runtime) searchSource(ctx context.Context) (store.Source, bool) {
	r.mu.Lock()
	resolve := r.resolve
	r.mu.Unlock()
	if target, problem := resolve(); problem == corev1.GithubAccess_GITHUB_ACCESS_OK {
		return target.Source(), true
	}
	source, has, err := r.cfg.store.CacheSource(ctx)
	return source, has && err == nil
}

// GitHubSearchStop says why a step of a deep search ended.
type GitHubSearchStop int

const (
	// SearchDone: GitHub has no older run for the query.
	SearchDone GitHubSearchStop = iota
	// SearchBudget: the pages of this step are read; ask again to go on.
	SearchBudget
	// SearchRateLimited and SearchUnavailable: GitHub stopped answering.
	SearchRateLimited
	SearchUnavailable
	// SearchBusy: another deep search of this repository is running.
	SearchBusy
)

// GitHubSearch is one step of a deep search.
type GitHubSearch struct {
	Access     corev1.GithubAccess
	RetryAfter time.Time
	Stop       GitHubSearchStop
	// Runs are the matches of this step.
	Runs []github.Run
	// Next is where the next step starts; zero when the search is done.
	Next time.Time
	// LookedBack is the creation time of the oldest run read so far.
	LookedBack  time.Time
	Pages, Read int
}

// MaxSearchPages bounds the pages of 100 runs one step reads.
const MaxSearchPages = 10

// SearchGitHub reads pages of runs from GitHub, newest first, for a query:
// what GitHub can filter is sent, the rest is matched here on every page.
// A step reads up to `pages` pages starting at `cursor` (the creation time
// the previous step ended on; zero for the newest runs). Every run read is
// added to the search index, matching or not.
func (r *Runtime) SearchGitHub(ctx context.Context, q runsearch.Query, cursor time.Time, pages int) (GitHubSearch, error) {
	if !r.searchMu.TryLock() {
		return GitHubSearch{Stop: SearchBusy}, nil
	}
	defer r.searchMu.Unlock()
	r.mu.Lock()
	resolve := r.resolve
	r.mu.Unlock()
	target, problem := resolve()
	if problem != corev1.GithubAccess_GITHUB_ACCESS_OK {
		return GitHubSearch{Access: problem, Stop: SearchUnavailable}, nil
	}
	if pages <= 0 || pages > MaxSearchPages {
		pages = MaxSearchPages
	}
	source := target.Source()
	out := GitHubSearch{Access: corev1.GithubAccess_GITHUB_ACCESS_OK, LookedBack: cursor}
	seen := map[int64]bool{}
	before := cursor
	for out.Pages < pages {
		fetchCtx, cancel := context.WithTimeout(ctx, r.cfg.intervals.FetchTimeout)
		runs, err := target.Account.Client.RunsQuery(fetchCtx, target.Owner, target.Name, filterValues(q.GitHub(before)))
		cancel()
		if err != nil {
			access, retry, cancelled := Access(target.Account, err)
			if cancelled != nil {
				return out, cancelled
			}
			out.Access, out.RetryAfter = access, retry
			out.Stop = SearchUnavailable
			if access == corev1.GithubAccess_GITHUB_ACCESS_RATE_LIMITED {
				out.Stop = SearchRateLimited
			}
			return out, nil
		}
		out.Pages++
		fresh := runs[:0:0]
		for _, run := range runs {
			if !seen[run.ID] {
				seen[run.ID] = true
				fresh = append(fresh, run)
			}
		}
		out.Read += len(fresh)
		if err := r.cfg.store.IndexRuns(ctx, source, fresh); err != nil {
			return out, err
		}
		for _, run := range fresh {
			if q.Matches(record(run, nil, nil)) {
				out.Runs = append(out.Runs, run)
			}
			if out.LookedBack.IsZero() || run.CreatedAt.Before(out.LookedBack) {
				out.LookedBack = run.CreatedAt
			}
		}
		// A short page, or one that only repeats runs read, is the end.
		if len(runs) < 100 || len(fresh) == 0 {
			out.Stop = SearchDone
			return out, nil
		}
		before = out.LookedBack
	}
	out.Stop, out.Next = SearchBudget, out.LookedBack
	return out, nil
}

func filterValues(f runsearch.GitHubFilter) url.Values {
	values := url.Values{}
	set := func(key, value string) {
		if value != "" {
			values.Set(key, value)
		}
	}
	set("branch", f.Branch)
	set("actor", f.Actor)
	set("event", f.Event)
	set("status", f.Status)
	set("head_sha", f.HeadSHA)
	set("created", f.Created)
	return values
}
