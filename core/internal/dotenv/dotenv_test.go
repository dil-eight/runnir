package dotenv

import (
	"reflect"
	"testing"
)

func TestParse(t *testing.T) {
	data := []byte("\ufeff# comment\n" +
		"\n" +
		"export NPM_TOKEN=abc123\n" +
		"plain = spaced value  # trailing comment\n" +
		"HASH=a#b\n" +
		"SINGLE='lit ${HOME} \\n'\n" +
		"DOUBLE=\"line1\\nline2 \\\"q\\\" \\\\ ${HOME}\"\n" +
		"MULTI=\"first\n" +
		"second\"\n" +
		"KEY='-----BEGIN\n" +
		"body\n" +
		"-----END'\n" +
		"SECRET=encrypted:BDb7t3QkTRp2\n" +
		"not a line\n" +
		"1BAD=x\n" +
		"EMPTY=\n" +
		"NPM_TOKEN=later\n" +
		"OPEN=\"never closed\n")
	entries, problems := Parse(data)
	want := []Entry{
		{Name: "NPM_TOKEN", Value: "later", Line: 17},
		{Name: "PLAIN", Value: "spaced value", Line: 4},
		{Name: "HASH", Value: "a#b", Line: 5},
		{Name: "SINGLE", Value: "lit ${HOME} \\n", Line: 6},
		{Name: "DOUBLE", Value: "line1\nline2 \"q\" \\ ${HOME}", Line: 7},
		{Name: "MULTI", Value: "first\nsecond", Line: 8},
		{Name: "KEY", Value: "-----BEGIN\nbody\n-----END", Line: 10},
		{Name: "SECRET", Encrypted: true, Line: 13},
		{Name: "EMPTY", Value: "", Line: 16},
	}
	if !reflect.DeepEqual(entries, want) {
		t.Fatalf("entries =\n%+v\nwant\n%+v", entries, want)
	}
	wantProblems := []Problem{
		{Line: 14, Message: "Not a NAME=value line."},
		{Line: 15, Message: "Not a NAME=value line."},
		{Line: 18, Message: "The quote that starts here is not closed."},
	}
	if !reflect.DeepEqual(problems, wantProblems) {
		t.Fatalf("problems = %+v", problems)
	}
}

func TestParseCRLFAndTextAfterQuote(t *testing.T) {
	entries, problems := Parse([]byte("A=\"x\" # ok\r\nB='y' junk\r\n"))
	if len(entries) != 1 || entries[0] != (Entry{Name: "A", Value: "x", Line: 1}) {
		t.Fatalf("entries = %+v", entries)
	}
	if len(problems) != 1 || problems[0].Line != 2 {
		t.Fatalf("problems = %+v", problems)
	}
}
