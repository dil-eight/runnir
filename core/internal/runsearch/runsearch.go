// Package runsearch is the one grammar of the run search: how a typed query
// is read, which of a repository's runs it matches, and which parts of it
// GitHub can filter itself.
//
// A query is words separated by spaces. A run matches when every word
// matches somewhere in it, in any case: its title, workflow, commit message,
// branch, author, event, outcome or pull request, or the start of its commit
// (four hex characters or more). `#142` also finds the run or the pull
// request with that number, and a bare number the run with that number.
// Qualifiers narrow it: `branch:`, `author:`, `event:`, `workflow:`,
// `status:` (success, failed, cancelled, running, queued, skipped) and the
// dates `after:` and `before:` (2026-03-12).
package runsearch

import (
	"strconv"
	"strings"
	"time"
	"unicode"
)

// Status is one of the six statuses a run is searched and filtered by.
type Status string

const (
	Succeeded Status = "success"
	Failed    Status = "failed"
	Cancelled Status = "cancelled"
	Running   Status = "running"
	Queued    Status = "queued"
	Skipped   Status = "skipped"
)

// StatusOf is the one mapping from GitHub's status and conclusion to the six.
// A run that waits for a person (action_required) counts as queued; neutral
// and stale conclusions count as skipped.
func StatusOf(status, conclusion string) Status {
	switch status {
	case "completed":
		switch conclusion {
		case "success":
			return Succeeded
		case "failure", "timed_out", "startup_failure":
			return Failed
		case "cancelled":
			return Cancelled
		case "action_required":
			return Queued
		default: // skipped, neutral, stale and what GitHub adds later
			return Skipped
		}
	case "in_progress":
		return Running
	default: // queued, waiting, requested, pending
		return Queued
	}
}

// Label is the outcome as the run list words it, so that a search for
// "failed" or "succeeded" finds those runs.
func Label(status, conclusion string) string {
	if status == "completed" && conclusion != "" && conclusion != "success" && conclusion != "failure" &&
		conclusion != "timed_out" && conclusion != "startup_failure" && conclusion != "cancelled" && conclusion != "skipped" {
		return "Completed"
	}
	switch StatusOf(status, conclusion) {
	case Succeeded:
		return "Succeeded"
	case Failed:
		return "Failed"
	case Cancelled:
		return "Cancelled"
	case Running:
		return "In progress"
	case Skipped:
		return "Skipped"
	default:
		return "Queued"
	}
}

// Query is a parsed query.
type Query struct {
	// Words are lowercased; every one has to match.
	Words []string
	// Qualifiers, lowercased; empty when not given.
	Branch, Author, Event, Workflow string
	Statuses                        []Status
	// After and Before bound the day a run was created: from the start of
	// After to the end of Before. Zero when not given.
	After, Before time.Time
	// Problems are parts of the query that could not be used, to show.
	Problems []string
}

// Parse reads a typed query.
func Parse(text string) Query {
	var q Query
	for _, token := range strings.Fields(text) {
		key, value, qualified := strings.Cut(token, ":")
		key = strings.ToLower(key)
		if !qualified || value == "" || !isQualifier(key) {
			q.Words = append(q.Words, strings.ToLower(token))
			continue
		}
		switch key {
		case "branch":
			q.Branch = strings.ToLower(value)
		case "author", "actor":
			q.Author = strings.ToLower(value)
		case "event":
			q.Event = strings.ToLower(value)
		case "workflow":
			q.Workflow = strings.ToLower(value)
		case "status":
			if status, ok := parseStatus(value); ok {
				q.Statuses = append(q.Statuses, status)
			} else {
				q.Problems = append(q.Problems, "status: wants success, failed, cancelled, running, queued or skipped")
			}
		case "after", "before":
			day, err := time.Parse("2006-01-02", value)
			switch {
			case err != nil:
				q.Problems = append(q.Problems, key+": wants a date like 2026-03-12")
			case key == "after":
				q.After = day
			default:
				q.Before = day.Add(24*time.Hour - time.Millisecond)
			}
		}
	}
	return q
}

func isQualifier(key string) bool {
	switch key {
	case "branch", "author", "actor", "event", "workflow", "status", "after", "before":
		return true
	}
	return false
}

func parseStatus(value string) (Status, bool) {
	switch strings.ToLower(value) {
	case "success", "succeeded", "passed":
		return Succeeded, true
	case "failed", "failure":
		return Failed, true
	case "cancelled", "canceled":
		return Cancelled, true
	case "running", "in_progress", "progress":
		return Running, true
	case "queued", "waiting", "pending":
		return Queued, true
	case "skipped":
		return Skipped, true
	}
	return "", false
}

// Active says whether the query narrows anything.
func (q Query) Active() bool {
	return len(q.Words) > 0 || q.Branch != "" || q.Author != "" || q.Event != "" || q.Workflow != "" ||
		len(q.Statuses) > 0 || !q.After.IsZero() || !q.Before.IsZero()
}

// Record is what a query is matched against: one run, as the activity cache
// and the search index keep it.
type Record struct {
	ID           int64
	RunNumber    int64
	Title        string
	Workflow     string
	CommitTitle  string
	Branch       string
	SHA          string
	Author       string
	Event        string
	Status       string
	Conclusion   string
	CreatedAt    time.Time
	PullRequests []int64
	// PullRequestText is the title and author of a pull request the run is
	// linked to, so that a search for its words finds the run.
	PullRequestText []string
}

// Matches says whether a run matches every part of the query.
func (q Query) Matches(r Record) bool {
	if q.Branch != "" && !strings.EqualFold(r.Branch, q.Branch) {
		return false
	}
	if q.Author != "" && !strings.EqualFold(r.Author, q.Author) {
		return false
	}
	if q.Event != "" && !strings.EqualFold(r.Event, q.Event) {
		return false
	}
	if q.Workflow != "" && !strings.Contains(strings.ToLower(r.Workflow), q.Workflow) {
		return false
	}
	if len(q.Statuses) > 0 {
		own := StatusOf(r.Status, r.Conclusion)
		found := false
		for _, status := range q.Statuses {
			found = found || status == own
		}
		if !found {
			return false
		}
	}
	if !q.After.IsZero() && r.CreatedAt.Before(q.After) {
		return false
	}
	if !q.Before.IsZero() && r.CreatedAt.After(q.Before) {
		return false
	}
	for _, word := range q.Words {
		if !wordMatches(r, word) {
			return false
		}
	}
	return true
}

func wordMatches(r Record, word string) bool {
	fields := [...]string{r.Title, r.Workflow, r.CommitTitle, r.Branch, r.Author, r.Event, Label(r.Status, r.Conclusion)}
	for _, field := range fields {
		if strings.Contains(strings.ToLower(field), word) {
			return true
		}
	}
	for _, text := range r.PullRequestText {
		if strings.Contains(strings.ToLower(text), word) {
			return true
		}
	}
	if len(word) >= 4 && isHex(word) && strings.HasPrefix(strings.ToLower(r.SHA), word) {
		return true
	}
	if strings.HasPrefix(word, "#") {
		if number, err := strconv.ParseInt(word[1:], 10, 64); err == nil {
			if r.RunNumber == number {
				return true
			}
			for _, pr := range r.PullRequests {
				if pr == number {
					return true
				}
			}
		}
		return false
	}
	if number, err := strconv.ParseInt(word, 10, 64); err == nil && r.RunNumber == number {
		return true
	}
	// "#142" also matches the text of a linked pull request written that way.
	for _, pr := range r.PullRequests {
		if "#"+strconv.FormatInt(pr, 10) == word {
			return true
		}
	}
	return false
}

// MatchFields says whether every word of the query is found in one of the
// fields, for things that are not runs: pull requests, workflows, local
// runs. A word "#12" also matches the number 12. A query of qualifiers only,
// which only runs have, matches none of them.
func (q Query) MatchFields(number int64, fields ...string) bool {
	if len(q.Words) == 0 {
		return false
	}
	for _, word := range q.Words {
		found := number > 0 && (word == "#"+strconv.FormatInt(number, 10) || word == strconv.FormatInt(number, 10))
		for _, field := range fields {
			found = found || strings.Contains(strings.ToLower(field), word)
		}
		if !found {
			return false
		}
	}
	return true
}

func isHex(word string) bool {
	for _, r := range word {
		if !unicode.Is(unicode.ASCII_Hex_Digit, r) {
			return false
		}
	}
	return true
}

// GitHubFilter is the part of a query GitHub's list of runs can apply
// itself, as that endpoint's parameters. The rest is matched locally on
// every page that comes back.
type GitHubFilter struct {
	Branch, Actor, Event, Status, HeadSHA string
	// Created is the endpoint's `created` range, "" for none.
	Created string
}

// GitHub turns a query into GitHub's parameters. `before` is the upper
// bound of this step of the search, zero for the newest runs: a deep search
// reads pages by the time of the oldest run it has read.
func (q Query) GitHub(before time.Time) GitHubFilter {
	f := GitHubFilter{Branch: q.Branch, Actor: q.Author, Event: q.Event}
	if len(q.Statuses) == 1 {
		switch q.Statuses[0] {
		case Succeeded:
			f.Status = "success"
		case Failed:
			f.Status = "failure"
		case Cancelled:
			f.Status = "cancelled"
		case Running:
			f.Status = "in_progress"
		case Queued:
			f.Status = "queued"
		case Skipped:
			f.Status = "skipped"
		}
	}
	for _, word := range q.Words {
		if len(word) == 40 && isHex(word) {
			f.HeadSHA = word
		}
	}
	upper := before
	if !q.Before.IsZero() && (upper.IsZero() || q.Before.Before(upper)) {
		upper = q.Before
	}
	const layout = "2006-01-02T15:04:05Z"
	switch {
	case !q.After.IsZero() && !upper.IsZero():
		f.Created = q.After.UTC().Format(layout) + ".." + upper.UTC().Format(layout)
	case !upper.IsZero():
		f.Created = "<=" + upper.UTC().Format(layout)
	case !q.After.IsZero():
		f.Created = ">=" + q.After.UTC().Format(layout)
	}
	return f
}
