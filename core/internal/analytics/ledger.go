// Package analytics keeps this Mac's analytics ledger and sends it to
// PostHog. Counts are added per UTC day and sealed, once the day is over,
// into batches with a random batch id; a batch is sent until PostHog
// accepts it and keeps its id when resent, so every count is read once
// (docs/superpowers/specs/2026-10-25-anonymous-analytics-design.md).
package analytics

import (
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"sync"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"

	_ "modernc.org/sqlite"
)

// Level is what the ledger counts and sends.
type Level int

const (
	// Off counts and sends nothing.
	Off Level = iota + 1
	// Basic counts first_launch and minute counters, without an id.
	Basic
	// Full adds usage counters and the analytics id.
	Full
)

func (l Level) String() string {
	switch l {
	case Off:
		return "off"
	case Basic:
		return "basic"
	case Full:
		return "full"
	}
	return "unknown"
}

// The kinds of batch: an install's first launch, or one day's counts.
const (
	eventFirstLaunch = "first_launch"
	eventDay         = "day"
)

const (
	ledgerName = "analytics.sqlite"
	lockName   = "analytics.lock"
	dayLayout  = "2006-01-02"
	// keepDays: older days are dropped, sent or not.
	keepDays = 7
	pragmas  = "_busy_timeout=5000&_journal_mode=WAL&_synchronous=FULL&_txlock=immediate"
)

// maxOutboxBytes bounds the outbox; tests lower it.
var maxOutboxBytes = 256 << 10

// ErrNotAllowed: a counter outside the allowlist, or a negative value.
var ErrNotAllowed = errors.New("not an allowed analytics count")

// schema is version 1 of analytics.sqlite. Before the first release tag it
// changes in place; a ledger with another user_version is replaced.
const schema = `
CREATE TABLE IF NOT EXISTS state (
	id INTEGER PRIMARY KEY CHECK (id = 1),
	level INTEGER NOT NULL,
	analytics_id TEXT NOT NULL DEFAULT '',
	prompt_answered INTEGER NOT NULL DEFAULT 0
);
-- Unsealed counts; day is the UTC date.
CREATE TABLE IF NOT EXISTS counters (
	day TEXT NOT NULL,
	name TEXT NOT NULL,
	value INTEGER NOT NULL,
	PRIMARY KEY (day, name)
);
-- Sealed batches, sent until accepted. counts is a JSON object; size
-- approximates the bytes a batch takes; next_attempt is Unix milliseconds.
CREATE TABLE IF NOT EXISTS outbox (
	batch_id TEXT PRIMARY KEY,
	day TEXT NOT NULL,
	event TEXT NOT NULL,
	level INTEGER NOT NULL,
	analytics_id TEXT NOT NULL,
	counts TEXT NOT NULL,
	size INTEGER NOT NULL,
	attempts INTEGER NOT NULL DEFAULT 0,
	next_attempt INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS outbox_order ON outbox (day, batch_id);
PRAGMA user_version = 1;
`

const schemaVersion = 1

// Options are for tests; the zero value uses the clock and random ids.
type Options struct {
	Now   func() time.Time
	NewID func() string
}

// Ledger is safe for concurrent use: one connection serializes the
// database, and mu serializes read-modify-write changes.
type Ledger struct {
	db         *sql.DB
	lock       *fileLock
	persistent bool
	now        func() time.Time
	newID      func() string

	mu        sync.Mutex
	closeOnce sync.Once
	closeErr  error
}

// State is what GetAnalytics reports.
type State struct {
	Level          Level
	PromptAnswered bool
	// ID is the analytics id; "" unless Full.
	ID         string
	Persistent bool
	// Sealed sums the outbox by counter; an unsent first_launch is
	// "first_launch": 1.
	Sealed Counts
	// Unsealed sums the counters not sealed yet: today's, once Seal ran.
	Unsealed Counts
}

// Batch is one sealed batch waiting in the outbox.
type Batch struct {
	ID          string
	Day         string
	Event       string
	Level       Level
	AnalyticsID string
	Counts      Counts
}

type start int

const (
	startFresh    start = iota + 1 // no ledger file: this is the first launch
	startReplaced                  // a damaged ledger or another schema, replaced
	startExisting
	startMemory
)

// Open opens the ledger in dir, creating it at Basic with a sealed
// first_launch when there is none. A damaged ledger is replaced at Off with
// the question unanswered. Without dir, or when another process holds the
// ledger, it lives in memory, never sends and Persistent is false. The error
// is set only when not even a memory database can be made.
func Open(dir string, options Options) (*Ledger, error) {
	l := &Ledger{now: options.Now, newID: options.NewID}
	if l.now == nil {
		l.now = time.Now
	}
	if l.newID == nil {
		l.newID = newUUID
	}
	if dir != "" {
		if db, lock, how, ok := openDisk(dir); ok {
			l.db, l.lock, l.persistent = db, lock, true
			if err := l.initialize(how); err == nil {
				return l, nil
			}
			_ = db.Close()
			lock.release()
			l.db, l.lock, l.persistent = nil, nil, false
		}
	}
	db, err := sql.Open("sqlite", "file::memory:")
	if err != nil {
		return nil, err
	}
	configurePool(db)
	if _, err := db.Exec(schema); err != nil {
		_ = db.Close()
		return nil, err
	}
	l.db = db
	if err := l.initialize(startMemory); err != nil {
		_ = db.Close()
		return nil, err
	}
	return l, nil
}

func openDisk(dir string) (*sql.DB, *fileLock, start, bool) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, nil, 0, false
	}
	lock, err := acquireLock(filepath.Join(dir, lockName))
	if err != nil {
		return nil, nil, 0, false
	}
	path := filepath.Join(dir, ledgerName)
	how := startExisting
	info, err := os.Lstat(path)
	switch {
	case errors.Is(err, os.ErrNotExist):
		how = startFresh
	case err != nil || !info.Mode().IsRegular():
		lock.release()
		return nil, nil, 0, false
	}
	if how == startExisting {
		if db, err := openFile(path); err == nil {
			if usable(db) {
				return db, lock, startExisting, true
			}
			_ = db.Close()
		}
		// Damaged, or made by another schema: what it held can go.
		for _, suffix := range []string{"", "-wal", "-shm"} {
			_ = os.Remove(path + suffix)
		}
		how = startReplaced
	}
	db, err := openFile(path)
	if err == nil {
		_, err = db.Exec(schema)
	}
	if err != nil {
		if db != nil {
			_ = db.Close()
		}
		lock.release()
		return nil, nil, 0, false
	}
	_ = os.Chmod(path, 0o600)
	return db, lock, how, true
}

func openFile(path string) (*sql.DB, error) {
	dsn := (&url.URL{Scheme: "file", Path: filepath.ToSlash(path), RawQuery: pragmas}).String()
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	configurePool(db)
	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, err
	}
	return db, nil
}

// configurePool keeps exactly one long-lived connection: a memory database
// lives with its connection, and one connection serializes the writes.
func configurePool(db *sql.DB) {
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(0)
	db.SetConnMaxIdleTime(0)
}

func usable(db *sql.DB) bool {
	var check string
	if err := db.QueryRow("PRAGMA quick_check").Scan(&check); err != nil || check != "ok" {
		return false
	}
	var version int
	if err := db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return false
	}
	return version == schemaVersion
}

func (l *Ledger) initialize(how start) error {
	if how == startExisting {
		return nil
	}
	level := Basic
	if how == startReplaced {
		// The user's choice went with the file: nothing is sent until they
		// choose again.
		level = Off
	}
	return l.tx(func(tx *sql.Tx) error {
		if _, err := tx.Exec(`INSERT INTO state (id, level) VALUES (1, ?)`, level); err != nil {
			return err
		}
		if how != startFresh {
			return nil
		}
		return insertBatch(tx, Batch{ID: l.newID(), Day: l.day(l.now()), Event: eventFirstLaunch, Level: Basic})
	})
}

// Persistent reports a ledger kept on disk, which alone can send.
func (l *Ledger) Persistent() bool { return l.persistent }

// Close closes the database and releases the lock; calling it again does
// nothing.
func (l *Ledger) Close() error {
	l.closeOnce.Do(func() {
		l.closeErr = l.db.Close()
		if l.lock != nil {
			l.lock.release()
		}
	})
	return l.closeErr
}

// Add adds counts to the UTC day of at. A name outside the allowlist or a
// negative value refuses the whole call. Usage counters count only at Full,
// minute counters at Basic and Full, nothing at Off.
func (l *Ledger) Add(at time.Time, counts Counts) error {
	for name, value := range counts {
		if value < 0 || (!IsMinuteCounter(name) && !IsUsageCounter(name)) {
			return fmt.Errorf("%w: %q", ErrNotAllowed, name)
		}
	}
	day := l.day(at)
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.tx(func(tx *sql.Tx) error {
		s, err := readState(tx)
		if err != nil || s.level == Off {
			return err
		}
		for name, value := range counts {
			if value == 0 || (IsUsageCounter(name) && s.level != Full) {
				continue
			}
			if _, err := tx.Exec(`INSERT INTO counters (day, name, value) VALUES (?, ?, ?)
ON CONFLICT (day, name) DO UPDATE SET value = counters.value + excluded.value`, day, name, value); err != nil {
				return err
			}
		}
		return nil
	})
}

// Record adds one of a usage event to the UTC day of at; counted only at
// Full.
func (l *Ledger) Record(at time.Time, event corev1.UsageEvent) error {
	counter := UsageCounter(event)
	if counter == "" {
		return fmt.Errorf("%w: usage event %d", ErrNotAllowed, event)
	}
	return l.Add(at, Counts{counter: 1})
}

// Seal turns each UTC day before today into one outbox batch, then drops
// what is older than seven days, and the oldest batches beyond the outbox's
// size.
func (l *Ledger) Seal() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.tx(func(tx *sql.Tx) error {
		s, err := readState(tx)
		if err != nil {
			return err
		}
		if err := l.sealBefore(tx, s, l.day(l.now())); err != nil {
			return err
		}
		return trim(tx, l.now())
	})
}

// SetLevel changes the level as the spec's Level Changes say; fromPrompt
// marks the consent question answered.
func (l *Ledger) SetLevel(level Level, fromPrompt bool) error {
	if level < Off || level > Full {
		return fmt.Errorf("unknown analytics level %d", level)
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.tx(func(tx *sql.Tx) error {
		s, err := readState(tx)
		if err != nil {
			return err
		}
		id := s.id
		if level != s.level {
			switch level {
			case Off:
				for _, statement := range []string{`DELETE FROM counters`, `DELETE FROM outbox`} {
					if _, err := tx.Exec(statement); err != nil {
						return err
					}
				}
				id = ""
			case Basic:
				if s.level == Full {
					if err := stripUsage(tx); err != nil {
						return err
					}
				}
				id = ""
			case Full:
				// What was counted without an id is sealed now, so the new id
				// never goes with it.
				if err := l.sealBefore(tx, s, ""); err != nil {
					return err
				}
				id = l.newID()
			}
		}
		_, err = tx.Exec(`UPDATE state SET level = ?, analytics_id = ?, prompt_answered = ? WHERE id = 1`,
			level, id, s.answered || fromPrompt)
		return err
	})
}

// State reads the level, the id and what waits to be sent.
func (l *Ledger) State() (State, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	s, err := readState(l.db)
	if err != nil {
		return State{}, err
	}
	out := State{Level: s.level, PromptAnswered: s.answered, ID: s.id, Persistent: l.persistent,
		Sealed: Counts{}, Unsealed: Counts{}}
	rows, err := l.db.Query(`SELECT name, SUM(value) FROM counters GROUP BY name`)
	if err != nil {
		return State{}, err
	}
	for rows.Next() {
		var name string
		var value int64
		if err := rows.Scan(&name, &value); err != nil {
			_ = rows.Close()
			return State{}, err
		}
		out.Unsealed[name] += value
	}
	if err := rows.Close(); err != nil {
		return State{}, err
	}
	batches, err := queryBatches(l.db, "")
	if err != nil {
		return State{}, err
	}
	for _, b := range batches {
		if b.Event == eventFirstLaunch {
			out.Sealed[eventFirstLaunch]++
		}
		for name, value := range b.Counts {
			out.Sealed[name] += value
		}
	}
	return out, nil
}

// Due lists up to limit batches whose next attempt has come, oldest first.
func (l *Ledger) Due(limit int) ([]Batch, error) {
	return queryBatches(l.db, `WHERE next_attempt <= ? ORDER BY day, batch_id LIMIT ?`, l.now().UnixMilli(), limit)
}

// Remove deletes batches: sent, or never sendable.
func (l *Ledger) Remove(ids []string) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.tx(func(tx *sql.Tx) error {
		for _, id := range ids {
			if _, err := tx.Exec(`DELETE FROM outbox WHERE batch_id = ?`, id); err != nil {
				return err
			}
		}
		return nil
	})
}

// Failed counts an attempt on each batch and delays its next one.
func (l *Ledger) Failed(ids []string) error {
	now := l.now()
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.tx(func(tx *sql.Tx) error {
		for _, id := range ids {
			var attempts int
			err := tx.QueryRow(`SELECT attempts FROM outbox WHERE batch_id = ?`, id).Scan(&attempts)
			if errors.Is(err, sql.ErrNoRows) {
				continue
			} else if err != nil {
				return err
			}
			attempts++
			if _, err := tx.Exec(`UPDATE outbox SET attempts = ?, next_attempt = ? WHERE batch_id = ?`,
				attempts, now.Add(RetryDelay(attempts)).UnixMilli(), id); err != nil {
				return err
			}
		}
		return nil
	})
}

// RetryDelay is the wait after a batch's attempts-th failure: 1 minute,
// 5 minutes, 30 minutes, then 6 hours.
func RetryDelay(attempts int) time.Duration {
	switch {
	case attempts <= 1:
		return time.Minute
	case attempts == 2:
		return 5 * time.Minute
	case attempts == 3:
		return 30 * time.Minute
	}
	return 6 * time.Hour
}

// NextAttempt is the earliest next attempt in the outbox; false when empty.
func (l *Ledger) NextAttempt() (time.Time, bool, error) {
	var next sql.NullInt64
	if err := l.db.QueryRow(`SELECT MIN(next_attempt) FROM outbox`).Scan(&next); err != nil || !next.Valid {
		return time.Time{}, false, err
	}
	return time.UnixMilli(next.Int64), true, nil
}

func (l *Ledger) day(t time.Time) string { return t.UTC().Format(dayLayout) }

func (l *Ledger) tx(f func(*sql.Tx) error) error {
	tx, err := l.db.Begin()
	if err != nil {
		return err
	}
	if err := f(tx); err != nil {
		_ = tx.Rollback()
		return err
	}
	return tx.Commit()
}

// sealBefore seals the counters of days before limit, every day for "".
func (l *Ledger) sealBefore(tx *sql.Tx, s stateRow, limit string) error {
	where, args := "", []any{}
	if limit != "" {
		where, args = `WHERE day < ?`, []any{limit}
	}
	rows, err := tx.Query(`SELECT day, name, value FROM counters `+where+` ORDER BY day, name`, args...)
	if err != nil {
		return err
	}
	byDay := map[string]Counts{}
	var days []string
	for rows.Next() {
		var day, name string
		var value int64
		if err := rows.Scan(&day, &name, &value); err != nil {
			_ = rows.Close()
			return err
		}
		if byDay[day] == nil {
			byDay[day] = Counts{}
			days = append(days, day)
		}
		byDay[day][name] = value
	}
	if err := rows.Close(); err != nil {
		return err
	}
	if s.level != Off {
		for _, day := range days {
			b := Batch{ID: l.newID(), Day: day, Event: eventDay, Level: s.level, Counts: byDay[day]}
			if s.level == Full {
				b.AnalyticsID = s.id
			}
			if err := insertBatch(tx, b); err != nil {
				return err
			}
		}
	}
	_, err = tx.Exec(`DELETE FROM counters `+where, args...)
	return err
}

// stripUsage removes usage counts and the id: from counters, and from
// batches sealed at Full, which keep their batch id, so one already
// delivered is still read once. A batch left empty is dropped.
func stripUsage(tx *sql.Tx) error {
	// Usage counters are "<category>:<name>"; minute counters have no colon.
	if _, err := tx.Exec(`DELETE FROM counters WHERE instr(name, ':') > 0`); err != nil {
		return err
	}
	batches, err := queryBatches(tx, `WHERE level = ?`, Full)
	if err != nil {
		return err
	}
	for _, b := range batches {
		for name := range b.Counts {
			if IsUsageCounter(name) {
				delete(b.Counts, name)
			}
		}
		if len(b.Counts) == 0 && b.Event == eventDay {
			if _, err := tx.Exec(`DELETE FROM outbox WHERE batch_id = ?`, b.ID); err != nil {
				return err
			}
			continue
		}
		b.Level, b.AnalyticsID = Basic, ""
		counts, err := json.Marshal(b.Counts)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(`UPDATE outbox SET level = ?, analytics_id = '', counts = ?, size = ? WHERE batch_id = ?`,
			Basic, string(counts), batchSize(b, len(counts)), b.ID); err != nil {
			return err
		}
	}
	return nil
}

func trim(tx *sql.Tx, now time.Time) error {
	cutoff := now.UTC().AddDate(0, 0, -keepDays).Format(dayLayout)
	for _, statement := range []string{`DELETE FROM outbox WHERE day < ?`, `DELETE FROM counters WHERE day < ?`} {
		if _, err := tx.Exec(statement, cutoff); err != nil {
			return err
		}
	}
	for {
		var total int64
		if err := tx.QueryRow(`SELECT COALESCE(SUM(size), 0) FROM outbox`).Scan(&total); err != nil {
			return err
		}
		if total <= int64(maxOutboxBytes) {
			return nil
		}
		if _, err := tx.Exec(`DELETE FROM outbox WHERE batch_id = (SELECT batch_id FROM outbox ORDER BY day, batch_id LIMIT 1)`); err != nil {
			return err
		}
	}
}

type stateRow struct {
	level    Level
	id       string
	answered bool
}

type rowQuerier interface {
	QueryRow(query string, args ...any) *sql.Row
}

func readState(q rowQuerier) (stateRow, error) {
	var s stateRow
	err := q.QueryRow(`SELECT level, analytics_id, prompt_answered FROM state WHERE id = 1`).Scan(&s.level, &s.id, &s.answered)
	return s, err
}

type querier interface {
	Query(query string, args ...any) (*sql.Rows, error)
}

func queryBatches(q querier, tail string, args ...any) ([]Batch, error) {
	rows, err := q.Query(`SELECT batch_id, day, event, level, analytics_id, counts FROM outbox `+tail, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Batch
	for rows.Next() {
		var b Batch
		var counts string
		if err := rows.Scan(&b.ID, &b.Day, &b.Event, &b.Level, &b.AnalyticsID, &counts); err != nil {
			return nil, err
		}
		if err := json.Unmarshal([]byte(counts), &b.Counts); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

func insertBatch(tx *sql.Tx, b Batch) error {
	if b.Counts == nil {
		b.Counts = Counts{}
	}
	counts, err := json.Marshal(b.Counts)
	if err != nil {
		return err
	}
	_, err = tx.Exec(`INSERT INTO outbox (batch_id, day, event, level, analytics_id, counts, size) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		b.ID, b.Day, b.Event, b.Level, b.AnalyticsID, string(counts), batchSize(b, len(counts)))
	return err
}

// batchSize approximates the bytes a batch takes in the outbox and on the
// wire: its events' fixed properties plus its ids and counts.
func batchSize(b Batch, countsBytes int) int {
	return 300 + len(b.ID) + len(b.AnalyticsID) + countsBytes
}

// newUUID is a random (version 4) UUID.
func newUUID() string {
	var b [16]byte
	_, _ = rand.Read(b[:]) // never fails since Go 1.24
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
