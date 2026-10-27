package flow

import (
	"regexp"
	"strings"
	"sync"
)

// GitHub's filter patterns: `*` matches any characters but `/`, `**` any
// characters, `?` makes the character before it optional, `+` repeats it,
// `[...]` is one character of a set, and a leading `!` excludes. In a list
// the last pattern that matches decides.

var (
	patternsMu sync.Mutex
	patterns   = map[string]*regexp.Regexp{}
)

func compile(pattern string) *regexp.Regexp {
	patternsMu.Lock()
	defer patternsMu.Unlock()
	if re, ok := patterns[pattern]; ok {
		return re
	}
	var b strings.Builder
	b.WriteString("^")
	afterStar := false
	for i := 0; i < len(pattern); i++ {
		c := pattern[i]
		switch {
		case c == '*' && i+1 < len(pattern) && pattern[i+1] == '*':
			b.WriteString(".*")
			i++
			afterStar = true
			continue
		case c == '*':
			b.WriteString("[^/]*")
			afterStar = true
			continue
		case (c == '?' || c == '+') && i > 0 && !afterStar:
			b.WriteByte(c)
		case c == '[':
			if end := strings.IndexByte(pattern[i+1:], ']'); end > 0 {
				b.WriteString("[" + strings.ReplaceAll(pattern[i+1:i+1+end], `\`, `\\`) + "]")
				i += end + 1
			} else {
				b.WriteString(regexp.QuoteMeta(string(c)))
			}
		default:
			b.WriteString(regexp.QuoteMeta(string(c)))
		}
		afterStar = false
	}
	b.WriteString("$")
	re, err := regexp.Compile(b.String())
	if err != nil {
		re = nil
	}
	patterns[pattern] = re
	return re
}

func globMatch(pattern, value string) bool {
	re := compile(pattern)
	return re != nil && re.MatchString(value)
}

// decide applies a filter list to one value: the last pattern that matches
// decides, and a `!` pattern excludes. It returns whether the value is in,
// and the pattern that decided ("" when none matched).
func decide(list []string, value string) (in bool, by string) {
	for _, pattern := range list {
		if negated, ok := strings.CutPrefix(pattern, "!"); ok {
			if globMatch(negated, value) {
				in, by = false, pattern
			}
		} else if globMatch(pattern, value) {
			in, by = true, pattern
		}
	}
	return in, by
}

// refFilter checks a branch or tag against an include and an ignore list.
// ok is true without filters. The reason names what decided against it.
func refFilter(include, ignore []string, value, noun string) (ok bool, decided, reason string) {
	switch {
	case len(include) > 0:
		in, by := decide(include, value)
		switch {
		case in:
			return true, by, ""
		case by != "":
			return false, "", "excluded by " + by
		default:
			return false, "", noun + " " + value + " does not match " + strings.Join(include, ", ")
		}
	case len(ignore) > 0:
		for _, pattern := range ignore {
			if globMatch(pattern, value) {
				return false, "", map[string]string{"branch": "branches-ignore ", "tag": "tags-ignore "}[noun] + pattern
			}
		}
	}
	return true, "", ""
}

// pathFilter checks the changed files against paths or paths-ignore: with
// paths a file has to be in; with paths-ignore a file has to be out.
func pathFilter(paths, ignore, files []string) (ok bool, reason string) {
	switch {
	case len(paths) > 0:
		for _, file := range files {
			if in, _ := decide(paths, file); in {
				return true, ""
			}
		}
		return false, "paths " + strings.Join(paths, ", ") + ": no changed file matches"
	case len(ignore) > 0:
		for _, file := range files {
			ignored := false
			for _, pattern := range ignore {
				ignored = ignored || globMatch(pattern, file)
			}
			if !ignored {
				return true, ""
			}
		}
		return false, "paths-ignore: every changed file is ignored"
	}
	return true, ""
}

// literalName: a filter entry that names one branch, with no pattern.
func literalName(pattern string) bool {
	return pattern != "" && !strings.ContainsAny(pattern, "*?+[!")
}

// MatchesTag says whether a tag name matches a Tag scenario's target, a
// tag pattern ("v*") or a name.
func MatchesTag(target, tag string) bool { return tag != "" && globMatch(target, tag) }
