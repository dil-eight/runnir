package mcpbridge

import (
	"fmt"
	"strings"
	"testing"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

func values(pairs ...string) []*corev1.McpValue {
	var out []*corev1.McpValue
	for i := 0; i+1 < len(pairs); i += 2 {
		out = append(out, &corev1.McpValue{Name: pairs[i], Value: pairs[i+1]})
	}
	return out
}

func TestCheckSetAcceptsAValidRequest(t *testing.T) {
	request := &corev1.McpBridgeSetValuesRequest{Repository: "/r", Set: "Repository",
		Secrets: values("API_KEY", "k"), Variables: values("_region", "eu")}
	if err := CheckSet(request); err != nil {
		t.Fatal(err)
	}
}

func TestCheckSetRefuses(t *testing.T) {
	many := make([]string, 0, 202)
	for i := 0; i < 101; i++ {
		many = append(many, fmt.Sprintf("N%d", i), "v")
	}
	cases := map[string]*corev1.McpBridgeSetValuesRequest{
		"at least one secret or variable":       {Repository: "/r", Set: "Repository"},
		"at most 100":                           {Repository: "/r", Set: "Repository", Secrets: values(many...)},
		"GITHUB_SHA":                            {Repository: "/r", Set: "Repository", Secrets: values("GITHUB_SHA", "v")},
		"github_x":                              {Repository: "/r", Set: "Repository", Secrets: values("github_x", "v")},
		"1A":                                    {Repository: "/r", Set: "Repository", Variables: values("1A", "v")},
		"A-B":                                   {Repository: "/r", Set: "Repository", Variables: values("A-B", "v")},
		"255":                                   {Repository: "/r", Set: "Repository", Variables: values(strings.Repeat("A", 256), "v")},
		"EMPTY has no value":                    {Repository: "/r", Set: "Repository", Secrets: values("EMPTY", "")},
		"BIG is longer than 48 KiB":             {Repository: "/r", Set: "Repository", Secrets: values("BIG", strings.Repeat("x", 49153))},
		"TWICE is both a secret and a variable": {Repository: "/r", Set: "Repository", Secrets: values("TWICE", "a"), Variables: values("TWICE", "b")},
		"DUP is given twice":                    {Repository: "/r", Set: "Repository", Secrets: values("DUP", "a", "DUP", "b")},
		"a repository":                          {Set: "Repository", Secrets: values("A", "a")},
		"a set":                                 {Repository: "/r", Secrets: values("A", "a")},
	}
	for want, request := range cases {
		err := CheckSet(request)
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%q: got %v", want, err)
		}
		if _, ok := err.(Refusal); !ok {
			t.Errorf("%q: %T is not a Refusal", want, err)
		}
	}
}

func TestCheckSetNeverQuotesAValue(t *testing.T) {
	err := CheckSet(&corev1.McpBridgeSetValuesRequest{Repository: "/r", Set: "Repository",
		Secrets: values("TWICE", "s3cr3t-VALUE"), Variables: values("TWICE", "s3cr3t-VALUE")})
	if err == nil || strings.Contains(err.Error(), "s3cr3t") {
		t.Fatalf("error = %v", err)
	}
}

func TestCheckSetTakesAGitHubTokenForLocalRuns(t *testing.T) {
	for _, name := range []string{"GITHUB_TOKEN", "github_token"} {
		if err := CheckSet(&corev1.McpBridgeSetValuesRequest{Repository: "/r", Set: "Repository", Secrets: values(name, "ghp_x")}); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
}
