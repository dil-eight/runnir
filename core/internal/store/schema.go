package store

// migrations[i] moves a database from schema i to i+1. Each runs in one
// transaction together with the new user_version. A released entry is never
// edited; a change is a new entry. Tests may extend the list.
var migrations = []string{schemaV1}

// Times are Unix milliseconds, 0 for none. Tables marked cache can be
// downloaded again and Clear Cache empties them; local tables exist only on
// this Mac.
const schemaV1 = `
-- cache: the GitHub repository the cached activity belongs to, its default
-- branch, and whether GitHub has no run older than the oldest cached one.
CREATE TABLE cache_source (
	id INTEGER PRIMARY KEY CHECK (id = 1),
	server_id TEXT NOT NULL,
	repository TEXT NOT NULL,
	default_branch TEXT NOT NULL DEFAULT '',
	history_complete INTEGER NOT NULL DEFAULT 0
);
-- cache: ETags per read, and the last pass's outcome (scope "activity").
CREATE TABLE sync_state (
	scope TEXT PRIMARY KEY,
	etag TEXT NOT NULL DEFAULT '',
	checked_at INTEGER NOT NULL DEFAULT 0,
	synced_at INTEGER NOT NULL DEFAULT 0,
	changed_at INTEGER NOT NULL DEFAULT 0,
	access INTEGER NOT NULL DEFAULT 0,
	retry_after INTEGER NOT NULL DEFAULT 0
);
-- cache
CREATE TABLE remote_workflows (
	id INTEGER PRIMARY KEY,
	position INTEGER NOT NULL,
	name TEXT NOT NULL,
	path TEXT NOT NULL,
	state TEXT NOT NULL,
	html_url TEXT NOT NULL
);
-- cache
CREATE TABLE runs (
	id INTEGER PRIMARY KEY,
	workflow_id INTEGER NOT NULL,
	name TEXT NOT NULL,
	display_title TEXT NOT NULL,
	run_number INTEGER NOT NULL,
	run_attempt INTEGER NOT NULL,
	event TEXT NOT NULL,
	status TEXT NOT NULL,
	conclusion TEXT NOT NULL,
	branch TEXT NOT NULL,
	head_sha TEXT NOT NULL,
	head_repository TEXT NOT NULL,
	commit_title TEXT NOT NULL,
	actor TEXT NOT NULL,
	html_url TEXT NOT NULL,
	created_at INTEGER NOT NULL,
	updated_at INTEGER NOT NULL
);
CREATE INDEX runs_created ON runs (created_at DESC, id DESC);
CREATE INDEX runs_workflow ON runs (workflow_id);
CREATE INDEX runs_head ON runs (head_sha);
-- cache: pull requests GitHub listed on a run, whose base is this
-- repository. Links only accumulate; they go with the run.
CREATE TABLE run_pull_requests (
	run_id INTEGER NOT NULL REFERENCES runs (id) ON DELETE CASCADE,
	number INTEGER NOT NULL,
	PRIMARY KEY (run_id, number)
);
-- cache
CREATE TABLE pull_requests (
	number INTEGER PRIMARY KEY,
	title TEXT NOT NULL,
	state TEXT NOT NULL,
	draft INTEGER NOT NULL,
	author TEXT NOT NULL,
	html_url TEXT NOT NULL,
	head_ref TEXT NOT NULL,
	head_sha TEXT NOT NULL,
	head_repository TEXT NOT NULL,
	base_ref TEXT NOT NULL,
	merge_commit_sha TEXT NOT NULL,
	created_at INTEGER NOT NULL,
	updated_at INTEGER NOT NULL,
	closed_at INTEGER NOT NULL,
	merged_at INTEGER NOT NULL
);
CREATE INDEX pull_requests_updated ON pull_requests (updated_at DESC);
-- cache: answers to lookups for pull requests the runs miss, by key
-- ("pr:<n>", "commit:<sha>", "head:<owner/name>:<branch>"); numbers is a
-- JSON array, possibly empty.
CREATE TABLE link_lookups (
	key TEXT PRIMARY KEY,
	numbers TEXT NOT NULL,
	fetched_at INTEGER NOT NULL
);
-- cache: the jobs of a run's latest attempt.
CREATE TABLE run_jobs (
	id INTEGER PRIMARY KEY,
	run_id INTEGER NOT NULL REFERENCES runs (id) ON DELETE CASCADE,
	attempt INTEGER NOT NULL,
	position INTEGER NOT NULL,
	name TEXT NOT NULL,
	status TEXT NOT NULL,
	conclusion TEXT NOT NULL,
	html_url TEXT NOT NULL,
	started_at INTEGER NOT NULL,
	completed_at INTEGER NOT NULL,
	fetched_at INTEGER NOT NULL
);
CREATE INDEX run_jobs_run ON run_jobs (run_id);
-- cache
CREATE TABLE run_steps (
	job_id INTEGER NOT NULL REFERENCES run_jobs (id) ON DELETE CASCADE,
	number INTEGER NOT NULL,
	name TEXT NOT NULL,
	status TEXT NOT NULL,
	conclusion TEXT NOT NULL,
	started_at INTEGER NOT NULL,
	completed_at INTEGER NOT NULL,
	PRIMARY KEY (job_id, number)
);
-- cache: kept job logs; the text is a file in blobs/.
CREATE TABLE blobs (
	job_id INTEGER PRIMARY KEY,
	name TEXT NOT NULL UNIQUE,
	size INTEGER NOT NULL,
	sha256 TEXT NOT NULL,
	dropped_lines INTEGER NOT NULL,
	truncated INTEGER NOT NULL,
	stopped_early INTEGER NOT NULL,
	created_at INTEGER NOT NULL,
	last_used_at INTEGER NOT NULL
);
CREATE INDEX blobs_used ON blobs (last_used_at);
-- local: one summary per local act run; its output is never stored.
CREATE TABLE local_runs (
	execution_id TEXT PRIMARY KEY,
	workflow_path TEXT NOT NULL DEFAULT '',
	job_id TEXT NOT NULL DEFAULT '',
	event TEXT NOT NULL DEFAULT '',
	started_at INTEGER NOT NULL DEFAULT 0,
	finished_at INTEGER NOT NULL DEFAULT 0,
	state TEXT NOT NULL,
	message TEXT NOT NULL DEFAULT '',
	act_version TEXT NOT NULL DEFAULT '',
	engine TEXT NOT NULL DEFAULT ''
);
CREATE INDEX local_runs_started ON local_runs (started_at DESC);
-- local: the dispatches GitHub accepted from this Mac, so their inputs can be
-- seen and sent again. inputs and omitted are JSON: the values sent except
-- those that look secret, and the names of those. run_id is 0 until known.
-- server_id and repository say which GitHub repository it was sent to, like
-- the cache's source: a relinked folder does not show another one's history.
CREATE TABLE dispatch_history (
	id INTEGER PRIMARY KEY,
	workflow_path TEXT NOT NULL,
	ref TEXT NOT NULL,
	inputs TEXT NOT NULL DEFAULT '{}',
	omitted TEXT NOT NULL DEFAULT '[]',
	sent_at INTEGER NOT NULL,
	run_id INTEGER NOT NULL DEFAULT 0,
	server_id TEXT NOT NULL DEFAULT '',
	repository TEXT NOT NULL DEFAULT ''
);
CREATE INDEX dispatch_history_sent ON dispatch_history (sent_at DESC);
CREATE INDEX dispatch_history_workflow ON dispatch_history (repository, workflow_path, sent_at DESC);
-- local: the attempts of runs Runnir started on this Mac, so the runs list
-- can mark them (B46): a dispatch once its run is known (attempt 1) and each
-- re-run GitHub accepted. kind is dispatch, rerun, rerun_failed or
-- rerun_job. server_id and repository work as in dispatch_history. The
-- newest 5000 stay; Clear Cache and Clear history keep them.
CREATE TABLE runnir_starts (
	server_id TEXT NOT NULL,
	repository TEXT NOT NULL,
	run_id INTEGER NOT NULL,
	attempt INTEGER NOT NULL,
	kind TEXT NOT NULL,
	sent_at INTEGER NOT NULL,
	PRIMARY KEY (server_id, repository, run_id, attempt)
);
CREATE INDEX runnir_starts_sent ON runnir_starts (sent_at DESC);
-- local: what is known of the runs of each repository, kept after the cache
-- drops them (the 5000-run budget, a run GitHub deleted), so a search can
-- still find them. Filled by everything the Core reads; the newest 50000 per
-- repository stay. Clear Cache keeps it, and it is not in the backup of local
-- data: the next reads fill it again. pulls is a JSON array of numbers.
CREATE TABLE run_index (
	server_id TEXT NOT NULL,
	repository TEXT NOT NULL,
	id INTEGER NOT NULL,
	workflow_id INTEGER NOT NULL,
	name TEXT NOT NULL,
	display_title TEXT NOT NULL,
	run_number INTEGER NOT NULL,
	run_attempt INTEGER NOT NULL,
	event TEXT NOT NULL,
	status TEXT NOT NULL,
	conclusion TEXT NOT NULL,
	branch TEXT NOT NULL,
	head_sha TEXT NOT NULL,
	head_repository TEXT NOT NULL,
	commit_title TEXT NOT NULL,
	actor TEXT NOT NULL,
	html_url TEXT NOT NULL,
	created_at INTEGER NOT NULL,
	updated_at INTEGER NOT NULL,
	pulls TEXT NOT NULL DEFAULT '[]',
	PRIMARY KEY (server_id, repository, id)
);
CREATE INDEX run_index_created ON run_index (server_id, repository, created_at DESC);
-- local: the limits the person chose for this workspace's local runs, one
-- row; none means the defaults. Clear Cache keeps it; it is a preference, so
-- it is not in the backup of local data.
CREATE TABLE local_run_limits (
	id INTEGER PRIMARY KEY CHECK (id = 1),
	cpus INTEGER NOT NULL,
	memory_bytes INTEGER NOT NULL,
	timeout_seconds INTEGER NOT NULL
);
-- local: running totals of what this Mac saved, one per kind ("local_runs").
-- They outlive local_runs, which keeps only the newest records.
CREATE TABLE savings (
	kind TEXT PRIMARY KEY,
	minutes INTEGER NOT NULL,
	count INTEGER NOT NULL,
	since INTEGER NOT NULL
);
`
