package github

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

// TokenKind is what issued a token, which decides what Runnir can read with
// it and how its rights are set.
type TokenKind int

const (
	TokenOther TokenKind = iota
	// TokenAppUser comes from signing in to the Runnir Desktop app (Device
	// Flow): it reaches the repositories where the app is installed.
	TokenAppUser
	// TokenClassic is a personal access token (classic): scopes.
	TokenClassic
	// TokenFineGrained is a fine-grained personal access token: chosen
	// repositories and permissions.
	TokenFineGrained
	// TokenOAuth comes from an OAuth app: scopes, like a classic token.
	TokenOAuth
)

// KindOf tells a token's kind from GitHub's published prefixes.
func KindOf(token string) TokenKind {
	switch {
	case strings.HasPrefix(token, "ghu_"):
		return TokenAppUser
	case strings.HasPrefix(token, "ghp_"):
		return TokenClassic
	case strings.HasPrefix(token, "github_pat_"):
		return TokenFineGrained
	case strings.HasPrefix(token, "gho_"):
		return TokenOAuth
	default:
		return TokenOther
	}
}

// Kind is the kind of the held token; TokenOther when none is held.
func (c *Credential) Kind() TokenKind {
	token, _ := c.Token()
	return KindOf(token)
}

// CheckState says whether a token has what one check needs.
type CheckState int

const (
	CheckPassed CheckState = iota
	CheckMissing
	// CheckUnknown: GitHub does not tell without trying a change.
	CheckUnknown
)

// TokenCheckItem is one thing a token needs, and what GitHub showed.
type TokenCheckItem struct {
	Name   string
	State  CheckState
	Detail string
}

// TokenCheck is what Runnir found out about a token before using it.
type TokenCheck struct {
	Kind  TokenKind
	Login string
	// Scopes of a classic or OAuth token.
	Scopes []string
	// When the token expires; zero when it does not or GitHub does not say.
	ExpiresAt time.Time
	// Repositories the token reaches, counted up to 100.
	Repositories int
	Checks       []TokenCheckItem
	// Nothing Runnir needs is missing; unknown checks do not count.
	Suitable bool
}

// CheckToken asks GitHub what token can do, without holding it: it must be
// accepted, and reach repositories with Actions and Contents readable.
// Starting, cancelling and re-running need Actions write, which only a
// change shows; that check stays unknown for fine-grained tokens. Errors are
// those of reading the user (ErrUnauthorized for a token GitHub refuses).
func (c *Client) CheckToken(ctx context.Context, token string) (TokenCheck, error) {
	probe := &Credential{}
	if err := probe.Set(token); err != nil {
		return TokenCheck{}, err
	}
	client := &Client{credential: probe, baseURL: c.baseURL, http: c.http, userAgent: c.userAgent}
	check := TokenCheck{Kind: KindOf(token)}

	data, _, header, err := client.exchange(ctx, http.MethodGet, "/user", nil, nil, "application/vnd.github+json")
	if err != nil {
		return TokenCheck{}, err
	}
	var user struct {
		Login string `json:"login"`
	}
	if json.Unmarshal(data, &user) != nil || user.Login == "" {
		return TokenCheck{}, ErrInvalid
	}
	check.Login = user.Login
	check.ExpiresAt = tokenExpiry(header.Get("GitHub-Authentication-Token-Expiration"))
	scopesHeader, hasScopes := header["X-Oauth-Scopes"]
	if hasScopes {
		check.Scopes = splitScopes(strings.Join(scopesHeader, ","))
	}
	check.Checks = append(check.Checks, TokenCheckItem{Name: "GitHub accepts the token", State: CheckPassed, Detail: "Signed in as " + user.Login + "."})

	switch {
	case check.Kind == TokenAppUser:
		check.Checks = append(check.Checks, TokenCheckItem{Name: "Repositories", State: CheckPassed,
			Detail: "This token comes from the Runnir Desktop app and reaches the repositories where the app is installed."})
	case check.Kind == TokenClassic || check.Kind == TokenOAuth || hasScopes:
		check.Checks = append(check.Checks, scopeCheck(check.Scopes))
	default:
		check.Checks = append(check.Checks, client.fineGrainedChecks(ctx, &check)...)
	}
	if sso := header.Get("X-Github-Sso"); sso != "" {
		check.Checks = append(check.Checks, TokenCheckItem{Name: "Single sign-on", State: CheckMissing,
			Detail: "An organization asks to authorize this token for single sign-on: " + ssoURL(sso)})
	}
	check.Suitable = true
	for _, item := range check.Checks {
		if item.State == CheckMissing {
			check.Suitable = false
		}
	}
	return check, nil
}

func scopeCheck(scopes []string) TokenCheckItem {
	has := map[string]bool{}
	for _, scope := range scopes {
		has[scope] = true
	}
	switch {
	case has["repo"]:
		return TokenCheckItem{Name: "Scope repo", State: CheckPassed,
			Detail: "Reads and starts workflows in public and private repositories you can reach."}
	case has["public_repo"]:
		return TokenCheckItem{Name: "Scope repo", State: CheckMissing,
			Detail: "The token has public_repo only: private repositories and starting workflows in them need repo."}
	default:
		return TokenCheckItem{Name: "Scope repo", State: CheckMissing,
			Detail: "Without repo the token cannot read Actions in private repositories or start, cancel and re-run workflows."}
	}
}

// fineGrainedChecks counts the repositories the token reaches and reads
// Actions and Contents in the most recently pushed one.
func (c *Client) fineGrainedChecks(ctx context.Context, check *TokenCheck) []TokenCheckItem {
	var repositories []struct {
		FullName string `json:"full_name"`
	}
	query := url.Values{"per_page": {"100"}, "sort": {"pushed"}}
	if err := c.get(ctx, "/user/repos", query, &repositories); err != nil {
		return []TokenCheckItem{{Name: "Repository access", State: CheckUnknown, Detail: "GitHub did not list the token's repositories."}}
	}
	check.Repositories = len(repositories)
	if len(repositories) == 0 {
		return []TokenCheckItem{{Name: "Repository access", State: CheckMissing, Detail: "The token reaches no repositories."}}
	}
	items := []TokenCheckItem{{Name: "Repository access", State: CheckPassed, Detail: repositoryCount(len(repositories)) + "."}}
	first := repositories[0].FullName
	owner, name, ok := strings.Cut(first, "/")
	if !ok {
		return items
	}
	probe := func(title, suffix, needs string) TokenCheckItem {
		var ignored json.RawMessage
		err := c.get(ctx, repoPath(owner, name, suffix), url.Values{"per_page": {"1"}}, &ignored)
		switch {
		case err == nil:
			return TokenCheckItem{Name: title, State: CheckPassed, Detail: "Readable in " + first + "."}
		case errors.Is(err, ErrPermissionMissing), errors.Is(err, ErrNotVisible):
			return TokenCheckItem{Name: title, State: CheckMissing, Detail: "Not readable in " + first + ": the token needs " + needs + "."}
		default:
			return TokenCheckItem{Name: title, State: CheckUnknown, Detail: "GitHub did not answer for " + first + "."}
		}
	}
	items = append(items,
		probe("Actions (read)", "/actions/runs", "Actions: Read and write"),
		probe("Contents (read)", "/branches", "Contents: Read-only"),
		TokenCheckItem{Name: "Actions (write)", State: CheckUnknown,
			Detail: "Needed to start, cancel and re-run. GitHub shows it only when one of these is tried; choose Actions: Read and write."})
	return items
}

func repositoryCount(n int) string {
	switch {
	case n >= 100:
		return "Reaches 100 or more repositories"
	case n == 1:
		return "Reaches 1 repository"
	default:
		return "Reaches " + strconv.Itoa(n) + " repositories"
	}
}

func splitScopes(header string) []string {
	var scopes []string
	for _, scope := range strings.Split(header, ",") {
		if scope = strings.TrimSpace(scope); scope != "" {
			scopes = append(scopes, scope)
		}
	}
	sort.Strings(scopes)
	return scopes
}

// tokenExpiry reads GitHub's "2026-11-20 10:00:00 UTC" style header.
func tokenExpiry(value string) time.Time {
	for _, layout := range []string{"2006-01-02 15:04:05 MST", "2006-01-02 15:04:05 -0700", time.RFC3339} {
		if t, err := time.Parse(layout, strings.TrimSpace(value)); err == nil {
			return t
		}
	}
	return time.Time{}
}

// ssoURL takes the url from "required; url=https://github.com/orgs/o/sso?...".
func ssoURL(header string) string {
	for _, part := range strings.Split(header, ";") {
		if value, ok := strings.CutPrefix(strings.TrimSpace(part), "url="); ok {
			return value
		}
	}
	return "authorize it in the token's settings on GitHub."
}
