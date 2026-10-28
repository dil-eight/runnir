package flow

import (
	"fmt"
	"math"
	"strconv"
	"strings"
)

// Truth is what a job's condition says in a scenario.
type Truth int

const (
	// Unknown: the condition reads something only a run knows (inputs,
	// outputs of other jobs, variables): the job "depends on a condition".
	Unknown Truth = iota
	True
	False
)

// Context is what a scenario knows of the github context, by its full
// name ("github.event_name"). Anything else is unknown.
type Context map[string]any

// Value is a name a condition read, with the value the context gave it.
type Value struct{ Name, Value string }

// Reading is what a condition says for a context and what it read: the
// names it found, with their values, and the names it could not know, each
// once and as written, in the order it read them.
type Reading struct {
	Truth   Truth
	Read    []Value
	Unknown []string
}

// Evaluate reads a condition as GitHub would for the scenario: literals,
// comparisons (strings without regard to case), !, && and ||, parentheses,
// startsWith, endsWith, contains and format, and the contexts the scenario
// knows. Status functions come from the context ("success()" and the
// others) for a run; without them the plan shows the run in which the jobs
// before succeed: success() and always() hold, failure() and cancelled()
// are unknown.
func Evaluate(condition string, ctx Context) Truth { return Read(condition, ctx).Truth }

// Read evaluates a condition as Evaluate does and says what it read.
func Read(condition string, ctx Context) Reading {
	text := strings.TrimSpace(unwrap(condition))
	if text == "" {
		return Reading{Truth: True}
	}
	p := &parser{tokens: tokenize(text), ctx: ctx}
	v := p.or()
	out := Reading{Read: p.read, Unknown: p.unknown}
	switch {
	case p.failed || p.pos != len(p.tokens) || v.unknown:
		out.Truth = Unknown
	case truthy(v.value):
		out.Truth = True
	default:
		out.Truth = False
	}
	return out
}

type val struct {
	value   any // string, float64, bool, nil
	unknown bool
}

type token struct {
	kind string // "str", "num", "ident", "op"
	text string
}

func tokenize(text string) []token {
	var out []token
	for i := 0; i < len(text); {
		c := text[i]
		switch {
		case c == ' ' || c == '\t' || c == '\n' || c == '\r':
			i++
		case c == '\'':
			var b strings.Builder
			j := i + 1
			for j < len(text) {
				if text[j] == '\'' {
					if j+1 < len(text) && text[j+1] == '\'' {
						b.WriteByte('\'')
						j += 2
						continue
					}
					break
				}
				b.WriteByte(text[j])
				j++
			}
			out = append(out, token{"str", b.String()})
			i = j + 1
		case strings.HasPrefix(text[i:], "&&"), strings.HasPrefix(text[i:], "||"), strings.HasPrefix(text[i:], "=="),
			strings.HasPrefix(text[i:], "!="), strings.HasPrefix(text[i:], "<="), strings.HasPrefix(text[i:], ">="):
			out = append(out, token{"op", text[i : i+2]})
			i += 2
		case strings.ContainsRune("!<>(),[]", rune(c)):
			out = append(out, token{"op", string(c)})
			i++
		case c >= '0' && c <= '9' || c == '-' && i+1 < len(text) && text[i+1] >= '0' && text[i+1] <= '9':
			j := i + 1
			for j < len(text) && (text[j] >= '0' && text[j] <= '9' || text[j] == '.' || text[j] == 'x' || text[j] >= 'a' && text[j] <= 'f' || text[j] == 'e') {
				j++
			}
			out = append(out, token{"num", text[i:j]})
			i = j
		default:
			j := i
			for j < len(text) && (isWord(text[j]) || text[j] == '.' || text[j] == '*') {
				j++
			}
			if j == i {
				// A character the grammar does not know: the whole condition is unknown.
				out = append(out, token{"op", string(c)})
				i++
				continue
			}
			out = append(out, token{"ident", text[i:j]})
			i = j
		}
	}
	return out
}

func isWord(c byte) bool {
	return c == '_' || c == '-' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
}

type parser struct {
	tokens  []token
	pos     int
	ctx     Context
	failed  bool
	read    []Value
	unknown []string
}

func (p *parser) peek(text string) bool {
	return p.pos < len(p.tokens) && p.tokens[p.pos].kind == "op" && p.tokens[p.pos].text == text
}

func (p *parser) expect(text string) {
	if p.peek(text) {
		p.pos++
	} else {
		p.failed = true
	}
}

// note keeps a name the condition read, once: with its value when the
// context has it, as not known otherwise.
func (p *parser) note(name string, v any, known bool) {
	if known {
		for _, r := range p.read {
			if r.Name == name {
				return
			}
		}
		shown := str(v)
		if v == nil {
			shown = "null"
		}
		p.read = append(p.read, Value{name, shown})
		return
	}
	for _, u := range p.unknown {
		if u == name {
			return
		}
	}
	p.unknown = append(p.unknown, name)
}

func (p *parser) or() val {
	left := p.and()
	for p.peek("||") {
		p.pos++
		right := p.and()
		switch {
		case !left.unknown && truthy(left.value):
		case !right.unknown && truthy(right.value):
			left = right
		case left.unknown || right.unknown:
			left = val{unknown: true}
		default:
			left = right
		}
	}
	return left
}

func (p *parser) and() val {
	left := p.compare()
	for p.peek("&&") {
		p.pos++
		right := p.compare()
		switch {
		case !left.unknown && !truthy(left.value):
		case !right.unknown && !truthy(right.value):
			left = right
		case left.unknown || right.unknown:
			left = val{unknown: true}
		default:
			left = right
		}
	}
	return left
}

func (p *parser) compare() val {
	left := p.unary()
	for _, op := range []string{"==", "!=", "<=", ">=", "<", ">"} {
		if !p.peek(op) {
			continue
		}
		p.pos++
		right := p.unary()
		if left.unknown || right.unknown {
			return val{unknown: true}
		}
		var result bool
		switch op {
		case "==":
			result = equal(left.value, right.value)
		case "!=":
			result = !equal(left.value, right.value)
		default:
			a, b := number(left.value), number(right.value)
			switch op {
			case "<":
				result = a < b
			case ">":
				result = a > b
			case "<=":
				result = a <= b
			default:
				result = a >= b
			}
		}
		return val{value: result}
	}
	return left
}

func (p *parser) unary() val {
	if p.peek("!") {
		p.pos++
		v := p.unary()
		if v.unknown {
			return v
		}
		return val{value: !truthy(v.value)}
	}
	return p.primary()
}

func (p *parser) primary() val {
	if p.pos >= len(p.tokens) {
		p.failed = true
		return val{unknown: true}
	}
	t := p.tokens[p.pos]
	p.pos++
	switch t.kind {
	case "str":
		return val{value: t.text}
	case "num":
		n, err := strconv.ParseFloat(t.text, 64)
		if err != nil {
			if i, err := strconv.ParseInt(t.text, 0, 64); err == nil {
				return val{value: float64(i)}
			}
			return val{unknown: true}
		}
		return val{value: n}
	case "op":
		if t.text == "(" {
			v := p.or()
			p.expect(")")
			return v
		}
		p.failed = true
		return val{unknown: true}
	}
	switch strings.ToLower(t.text) {
	case "true":
		return val{value: true}
	case "false":
		return val{value: false}
	case "null":
		return val{value: nil}
	}
	if p.peek("(") {
		return p.call(t.text)
	}
	// An index by a string, github['event_name'], reads as a property; any
	// other index, and a key with a dot, which no property name the plan
	// knows has, is beyond what the plan knows.
	name, shown, known := strings.ToLower(t.text), t.text, true
	for p.peek("[") {
		p.pos++
		key := p.or()
		p.expect("]")
		s, ok := key.value.(string)
		known = known && ok && !key.unknown && !strings.Contains(s, ".")
		name += "." + strings.ToLower(s)
		shown += "." + s
		if p.pos < len(p.tokens) && p.tokens[p.pos].kind == "ident" && strings.HasPrefix(p.tokens[p.pos].text, ".") {
			name += strings.ToLower(p.tokens[p.pos].text)
			shown += p.tokens[p.pos].text
			p.pos++
		}
	}
	if v, ok := p.ctx[name]; ok && known {
		p.note(shown, v, true)
		return val{value: v}
	}
	p.note(shown, nil, false)
	return val{unknown: true}
}

func (p *parser) call(name string) val {
	p.expect("(")
	var args []val
	for !p.peek(")") && !p.failed && p.pos < len(p.tokens) {
		args = append(args, p.or())
		if p.peek(",") {
			p.pos++
		}
	}
	p.expect(")")
	switch fn := strings.ToLower(name); fn {
	case "success", "always", "failure", "cancelled":
		if v, ok := p.ctx[fn+"()"]; ok {
			p.note(fn+"()", v, true)
			return val{value: v}
		}
		if fn == "success" || fn == "always" {
			return val{value: true}
		}
		p.note(fn+"()", nil, false)
		return val{unknown: true}
	}
	for _, a := range args {
		if a.unknown {
			return val{unknown: true}
		}
	}
	text := func(i int) string { return strings.ToLower(str(args[i].value)) }
	switch strings.ToLower(name) {
	case "startswith":
		if len(args) == 2 {
			return val{value: strings.HasPrefix(text(0), text(1))}
		}
	case "endswith":
		if len(args) == 2 {
			return val{value: strings.HasSuffix(text(0), text(1))}
		}
	case "contains":
		if len(args) == 2 {
			return val{value: strings.Contains(text(0), text(1))}
		}
	case "format":
		if len(args) >= 1 {
			out := str(args[0].value)
			for i := 1; i < len(args); i++ {
				out = strings.ReplaceAll(out, fmt.Sprintf("{%d}", i-1), str(args[i].value))
			}
			return val{value: out}
		}
	}
	return val{unknown: true}
}

func truthy(v any) bool {
	switch x := v.(type) {
	case nil:
		return false
	case bool:
		return x
	case float64:
		return x != 0 && !math.IsNaN(x)
	case string:
		return x != ""
	}
	return true
}

func str(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case bool:
		return strconv.FormatBool(x)
	case float64:
		return strconv.FormatFloat(x, 'f', -1, 64)
	case string:
		return x
	}
	return fmt.Sprint(v)
}

func number(v any) float64 {
	switch x := v.(type) {
	case nil:
		return 0
	case bool:
		if x {
			return 1
		}
		return 0
	case float64:
		return x
	case string:
		if strings.TrimSpace(x) == "" {
			return 0
		}
		if n, err := strconv.ParseFloat(strings.TrimSpace(x), 64); err == nil {
			return n
		}
	}
	return math.NaN()
}

// equal compares as GitHub does: strings without regard to case, values of
// different types as numbers.
func equal(a, b any) bool {
	as, aString := a.(string)
	bs, bString := b.(string)
	if aString && bString {
		return strings.EqualFold(as, bs)
	}
	if a == nil && b == nil {
		return true
	}
	ab, aBool := a.(bool)
	bb, bBool := b.(bool)
	if aBool && bBool {
		return ab == bb
	}
	return number(a) == number(b)
}
