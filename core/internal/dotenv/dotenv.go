// Package dotenv reads .env files for importing values: NAME=value lines as
// dotenv tools write them. Nothing is expanded or executed, and values
// encrypted by dotenvx are flagged rather than decrypted.
package dotenv

import (
	"regexp"
	"strings"
)

// MaxSize is the largest file Runnir reads.
const MaxSize = 1 << 20

type Entry struct {
	// Name is upper-cased.
	Name  string
	Value string
	// Encrypted: a dotenvx "encrypted:" value; Value is empty.
	Encrypted bool
	// Line is the 1-based line the entry starts on.
	Line int
}

type Problem struct {
	Line    int
	Message string
}

var namePattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// Parse reads a dotenv file. A later entry for a name replaces an earlier
// one in its place; a line it cannot read becomes a problem and parsing
// goes on with the next line.
func Parse(data []byte) ([]Entry, []Problem) {
	text := strings.TrimPrefix(strings.ReplaceAll(string(data), "\r\n", "\n"), "\ufeff")
	lines := strings.Split(text, "\n")
	var entries []Entry
	var problems []Problem
	index := map[string]int{}
	for i := 0; i < len(lines); i++ {
		start := i + 1
		line := strings.TrimSpace(lines[i])
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if rest, ok := strings.CutPrefix(line, "export"); ok && (strings.HasPrefix(rest, " ") || strings.HasPrefix(rest, "\t")) {
			line = strings.TrimSpace(rest)
		}
		name, rest, ok := strings.Cut(line, "=")
		name = strings.TrimSpace(name)
		if !ok || !namePattern.MatchString(name) {
			problems = append(problems, Problem{Line: start, Message: "Not a NAME=value line."})
			continue
		}
		rest = strings.TrimLeft(rest, " \t")
		var value string
		if rest != "" && (rest[0] == '"' || rest[0] == '\'') {
			quote := rest[0]
			body := rest[1:]
			end := closing(body, quote)
			for end < 0 && i+1 < len(lines) {
				i++
				body += "\n" + lines[i]
				end = closing(body, quote)
			}
			if end < 0 {
				problems = append(problems, Problem{Line: start, Message: "The quote that starts here is not closed."})
				continue
			}
			if tail := strings.TrimSpace(body[end+1:]); tail != "" && !strings.HasPrefix(tail, "#") {
				problems = append(problems, Problem{Line: start, Message: "Text after the closing quote."})
				continue
			}
			value = body[:end]
			if quote == '"' {
				value = unescape(value)
			}
		} else {
			value = rest
			for _, marker := range []string{" #", "\t#"} {
				if cut := strings.Index(value, marker); cut >= 0 {
					value = value[:cut]
				}
			}
			value = strings.TrimSpace(value)
		}
		entry := Entry{Name: strings.ToUpper(name), Value: value, Line: start}
		if strings.HasPrefix(value, "encrypted:") {
			entry.Value, entry.Encrypted = "", true
		}
		if at, seen := index[entry.Name]; seen {
			entries[at] = entry
			continue
		}
		index[entry.Name] = len(entries)
		entries = append(entries, entry)
	}
	return entries, problems
}

// closing is the index of the quote that ends body, or -1. In double quotes
// a backslash escapes the next character.
func closing(body string, quote byte) int {
	for i := 0; i < len(body); i++ {
		switch {
		case quote == '"' && body[i] == '\\':
			i++
		case body[i] == quote:
			return i
		}
	}
	return -1
}

func unescape(value string) string {
	var out strings.Builder
	for i := 0; i < len(value); i++ {
		if value[i] != '\\' || i+1 == len(value) {
			out.WriteByte(value[i])
			continue
		}
		i++
		switch value[i] {
		case 'n':
			out.WriteByte('\n')
		case 'r':
			out.WriteByte('\r')
		case 't':
			out.WriteByte('\t')
		case '"', '\\':
			out.WriteByte(value[i])
		default:
			out.WriteByte('\\')
			out.WriteByte(value[i])
		}
	}
	return out.String()
}
