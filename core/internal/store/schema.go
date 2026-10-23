package store

// migrations[i] moves a database from schema i to i+1. Each runs in one
// transaction together with the new user_version. A released entry is never
// edited; a change is a new entry. Tests may extend the list.
var migrations = []string{schemaV1}

// Times are Unix milliseconds, 0 for none. Tables marked cache can be
// downloaded again and Clear Cache empties them; local_runs exists only on
// this Mac.
const schemaV1 = `
-- cache: the GitHub repository the cached activity belongs to.
CREATE TABLE cache_source (
	id INTEGER PRIMARY KEY CHECK (id = 1),
	server_id TEXT NOT NULL,
	repository TEXT NOT NULL
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
	actor TEXT NOT NULL,
	html_url TEXT NOT NULL,
	created_at INTEGER NOT NULL,
	updated_at INTEGER NOT NULL
);
CREATE INDEX runs_created ON runs (created_at DESC, id DESC);
CREATE INDEX runs_workflow ON runs (workflow_id);
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
`
