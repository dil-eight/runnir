package flow

import (
	"regexp"
	"strings"
	"sync"
)

// GitHub's filter patterns: `*` matches any characters but `/`, `**` any
// characters, `?` makes the character before it optional, `+` repeats it,
// `[...]` is one character of a set, `\` takes the next character as it is,
// and a leading `!` excludes. In a list the last pattern that matches decides.

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
		case c == '\\' && i+1 < len(pattern):
			i++
			b.WriteString(regexp.QuoteMeta(pattern[i : i+1]))
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
			if set, end, ok := charSet(pattern, i); ok {
				b.WriteString(set)
				i = end
			} else {
				b.WriteString(`\[`)
			}
		default:
			// One byte at a time: the bytes of a multi-byte character follow
			// each other unchanged, as QuoteMeta leaves them.
			b.WriteString(regexp.QuoteMeta(pattern[i : i+1]))
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

// charSet reads the [...] set that starts at pattern[start]: its regexp
// and the index of its closing ']'. Inside it `\` takes the next character
// as it is. A set holds one character at least, so "[]" is no set.
func charSet(pattern string, start int) (set string, end int, ok bool) {
	if start+1 >= len(pattern) || pattern[start+1] == ']' {
		return "", 0, false
	}
	var b strings.Builder
	b.WriteString("[")
	for i := start + 1; i < len(pattern); i++ {
		switch c := pattern[i]; {
		case c == ']':
			return b.String() + "]", i, true
		case c == '\\' && i+1 < len(pattern):
			i++
			b.WriteString(classLiteral(pattern[i]))
		case c == '\\' || c == '[':
			b.WriteString(classLiteral(c))
		default:
			b.WriteByte(c)
		}
	}
	return "", 0, false
}

// classLiteral writes a character as itself inside a regexp set: the ones
// a set reads otherwise (\ [ ] ^ -) escaped, any other byte as it is.
func classLiteral(c byte) string {
	if strings.IndexByte(`\[]^-`, c) >= 0 {
		return `\` + string(rune(c))
	}
	return string([]byte{c})
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

// refFilter checks a branch or tag (noun says which) against the include
// and ignore lists of a filter ("branches" or "tags"). ok is true without
// filters. The reason names what decided against it.
func refFilter(filter string, include, ignore []string, value, noun string) (ok bool, decided, reason string) {
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
				return false, "", filter + "-ignore " + pattern
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

// exactName is the one name a filter entry stands for, with GitHub's escapes
// taken out; ok is false for a pattern or an exclusion.
func exactName(pattern string) (name string, ok bool) {
	if pattern == "" || pattern[0] == '!' {
		return "", false
	}
	var b strings.Builder
	for i := 0; i < len(pattern); i++ {
		switch c := pattern[i]; {
		case c == '\\' && i+1 < len(pattern):
			i++
			b.WriteByte(pattern[i])
		case strings.IndexByte("*?+[", c) >= 0:
			return "", false
		default:
			b.WriteByte(c)
		}
	}
	return b.String(), true
}

// MatchesTag says whether a tag name matches a Tag scenario's target, a
// tag pattern ("v*") or a name.
func MatchesTag(target, tag string) bool { return tag != "" && globMatch(target, tag) }
