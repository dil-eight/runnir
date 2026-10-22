package github

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func tokenServer(t *testing.T, handler http.HandlerFunc) *Client {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	held := &Credential{}
	_ = held.Set("ghu_held")
	return NewClient(held, server.URL, "test")
}

func states(check TokenCheck) string {
	var parts []string
	for _, item := range check.Checks {
		parts = append(parts, item.Name+"="+[]string{"ok", "missing", "unknown"}[item.State])
	}
	return strings.Join(parts, ", ")
}

func TestKindsComeFromGitHubPrefixes(t *testing.T) {
	for token, want := range map[string]TokenKind{
		"ghu_x": TokenAppUser, "ghp_x": TokenClassic, "github_pat_x": TokenFineGrained, "gho_x": TokenOAuth,
		strings.Repeat("a", 40): TokenOther,
	} {
		if got := KindOf(token); got != want {
			t.Errorf("%s: %v, want %v", token, got, want)
		}
	}
}

func TestAClassicTokenNeedsTheRepoScope(t *testing.T) {
	scopes := "repo, read:org"
	client := tokenServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer ghp_checked" {
			t.Errorf("authorization = %q", r.Header.Get("Authorization"))
		}
		w.Header().Set("X-OAuth-Scopes", scopes)
		w.Header().Set("GitHub-Authentication-Token-Expiration", "2026-11-20 10:00:00 UTC")
		_, _ = w.Write([]byte(`{"login":"octocat"}`))
	})
	check, err := client.CheckToken(context.Background(), "ghp_checked")
	if err != nil || !check.Suitable || check.Login != "octocat" || check.Kind != TokenClassic ||
		strings.Join(check.Scopes, ",") != "read:org,repo" || !check.ExpiresAt.Equal(time.Date(2026, 11, 20, 10, 0, 0, 0, time.UTC)) {
		t.Fatalf("check = %+v, %v", check, err)
	}
	scopes = "public_repo"
	check, _ = client.CheckToken(context.Background(), "ghp_checked")
	if check.Suitable || !strings.Contains(states(check), "Scope repo=missing") || !strings.Contains(check.Checks[1].Detail, "public_repo only") {
		t.Fatalf("public_repo = %+v", check)
	}
	// The held token is not touched.
	if token, _ := client.credential.Token(); token != "ghu_held" {
		t.Fatalf("held = %q", token)
	}
}

func TestAFineGrainedTokenIsReadInItsFirstRepository(t *testing.T) {
	client := tokenServer(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/user":
			w.Header().Set("X-GitHub-SSO", "required; url=https://github.com/orgs/o/sso?authorization_request=1")
			_, _ = w.Write([]byte(`{"login":"octocat"}`))
		case "/user/repos":
			_, _ = w.Write([]byte(`[{"full_name":"o/r"},{"full_name":"o/s"}]`))
		case "/repos/o/r/actions/runs":
			_, _ = w.Write([]byte(`{"total_count":0,"workflow_runs":[]}`))
		case "/repos/o/r/branches":
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"message":"Resource not accessible by personal access token"}`))
		default:
			t.Errorf("unexpected %s", r.URL)
		}
	})
	check, err := client.CheckToken(context.Background(), "github_pat_checked")
	if err != nil || check.Kind != TokenFineGrained || check.Repositories != 2 || check.Suitable {
		t.Fatalf("check = %+v, %v", check, err)
	}
	want := "GitHub accepts the token=ok, Repository access=ok, Actions (read)=ok, Contents (read)=missing, Actions (write)=unknown, Single sign-on=missing"
	if got := states(check); got != want {
		t.Fatalf("states = %s", got)
	}
	if !strings.Contains(check.Checks[5].Detail, "https://github.com/orgs/o/sso") {
		t.Fatalf("sso = %q", check.Checks[5].Detail)
	}
}

func TestAFineGrainedTokenWithoutRepositoriesIsNotSuitable(t *testing.T) {
	client := tokenServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/user" {
			_, _ = w.Write([]byte(`{"login":"octocat"}`))
			return
		}
		_, _ = w.Write([]byte(`[]`))
	})
	check, err := client.CheckToken(context.Background(), "github_pat_empty")
	if err != nil || check.Suitable || states(check) != "GitHub accepts the token=ok, Repository access=missing" {
		t.Fatalf("check = %+v, %v", check, err)
	}
}

func TestARefusedTokenIsAnError(t *testing.T) {
	client := tokenServer(t, func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusUnauthorized) })
	if _, err := client.CheckToken(context.Background(), "ghp_revoked"); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("err = %v", err)
	}
	if _, err := client.CheckToken(context.Background(), "not a token"); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("invalid = %v", err)
	}
}

func TestAPersonalTokenListsWhatItReaches(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/user/repos" || r.URL.Query().Get("affiliation") == "" {
			t.Errorf("unexpected %s", r.URL)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		_, _ = w.Write([]byte(`[{"full_name":"o/r","name":"r","owner":{"login":"o"},"private":true,"permissions":{"push":true}}]`))
	}))
	defer server.Close()
	credential := &Credential{}
	_ = credential.Set("ghp_personal")
	account, err := NewClient(credential, server.URL, "test").AccountRepositories(context.Background())
	if err != nil || len(account.Installations) != 0 || len(account.Repositories) != 1 || !account.Repositories[0].CanPush ||
		account.Repositories[0].Visibility != "private" {
		t.Fatalf("account = %+v, %v", account, err)
	}
}
