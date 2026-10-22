# GitHub Enterprise Servers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sign in to GitHub Enterprise servers next to github.com and use their repositories everywhere Runnir uses github.com ones.

**Architecture:** The app keeps the server list (`github-servers.json`) and one Keychain token per server, and hands each server with its token to the Core. The Core keeps one credential and client per server id (`github.Accounts`), finds a working tree's server by its origin host, and takes an explicit server id for repositories without a clone. Lists that span accounts (repositories, pull requests) are asked per server by the app, which merges them.

**Tech Stack:** Go 1.27.3 (CGO_ENABLED=0), protobuf + buf, grpc-go; Swift 6, SwiftUI, Observation, Security (Keychain), grpc-swift generated client, Swift Testing.

Spec: [docs/architecture/github-enterprise.md](../../architecture/github-enterprise.md).

## Global Constraints

- Server id: empty string is github.com; an Enterprise server's id is a lowercase UUID string made by the app.
- URLs: `https` only; `http` is accepted only for a loopback host (`localhost`, `127.0.0.1`, `::1`) — by the Core always (tests, local fakes) and by the app only in Debug builds. No user info, query or fragment; a host is required; a port is allowed.
- An Enterprise web host must not be `github.com` and must differ from every other server's web host (host compared lowercased, without port).
- Limits: at most 10 Enterprise servers; server name 1–60 characters; `github-servers.json` at most 64 KiB.
- Keychain: service `dev.runnir.github` (`dev.runnir.github.ui-testing` for `--ui-testing` Debug runs); github.com account `oauth-token` (unchanged); Enterprise account `enterprise:<id>`.
- A token is sent only to its own server's API origin; the Go client refuses redirects to another origin.
- Enterprise sign-in is by personal access token only; Device Flow stays github.com only.
- No new dependencies. No telemetry. Tokens never in logs.
- Copy rules: English UI text, no AI attribution anywhere (commits, docs, code comments).
- Before handing off: from `core/` run `go test ./...`, `go vet ./...`, `go build ./...`; then `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build` and `... test -only-testing:RunnirTests`. Local Go is 1.27.2, so prefix Go and xcodebuild commands with `PATH="$HOME/go/pkg/mod/golang.org/toolchain@v0.0.1-go1.27.3.darwin-arm64/bin:$PATH"`.

## File Map

Core (Go):
- `contracts/grpc/runnir/core/v1/runnir_core.proto` — server fields (Task 1).
- `core/internal/github/server.go` (new) — `Server`, validation, host helpers (Task 2).
- `core/internal/github/client.go` — same-origin redirect guard (Task 2).
- `core/internal/github/accounts.go` (new) — `Accounts`: credential + client per server (Task 3).
- `core/internal/scanner/scanner.go`, `core/internal/repository/manager.go` — origin host for any host (Task 4).
- `core/internal/server/{server,service,github,dispatch,runs,pulls}.go` — routing by server (Tasks 4–5).
- `core/internal/localrun/{runner,plan}.go`, `core/internal/server/localruns.go` — `--github-instance` (Task 6).

App (Swift):
- `apps/macos/Runnir/IPC/{CoreService,CoreGitHubModels,GRPCCoreService,CoreHub}.swift` — server-aware calls (Tasks 7, 9).
- `apps/macos/Runnir/Core/GitHub/EnterpriseServers.swift` (new) — model, URL rules, file store (Task 8).
- `apps/macos/Runnir/Core/Security/KeychainCredentialStore.swift` — account parameter (Task 8).
- `apps/macos/Runnir/Features/Settings/EnterpriseServersSettings.swift` (new) — list and add sheet (Task 10).
- `apps/macos/Runnir/Features/Authentication/GitHubConnectView.swift` — token advice per server (Task 10).
- `apps/macos/Runnir/Features/Desktop/GitHubRepositoriesView.swift` — accounts in the GitHub tab (Task 11).
- `apps/macos/Runnir/Features/Desktop/{GitHubAccessHelp,PullRequestsViews}.swift`, `App/Desktop/DesktopCoordinator.swift` — server names in notices and lists (Task 12).
- `docs/architecture/grpc-api.md`, `docs/security/github-authentication.md`, `README.md` (Task 13).

---

## Part A — Contract and Core

### Task 1: Contract fields for servers

**Files:**
- Modify: `contracts/grpc/runnir/core/v1/runnir_core.proto`
- Regenerated: `core/internal/gen/runnir/core/v1/*`, `apps/macos/Runnir/IPC/Generated/runnir/core/v1/*`

**Interfaces:**
- Produces: message `GithubServer {id, api_url, web_host}`; fields listed below. Later tasks use the generated names `GetGithubServer()`, `GetServerId()`, `GithubServerId`, `OriginHost` (Go) and `githubServer`, `serverID`, `githubServerID`, `originHost` (Swift).

- [ ] **Step 1: Add the message and fields**

Add after `message SetGitHubCredentialResponse`:

```proto
// A GitHub server: github.com when id is empty (api_url and web_host are
// then ignored), otherwise an Enterprise server the app registered.
message GithubServer {
  // Empty for github.com; a lowercase UUID for an Enterprise server.
  string id = 1;
  // "https://github.company.com/api/v3"; http only for a loopback host.
  string api_url = 2;
  // Host of the web URL, lowercased, without port: "github.company.com".
  string web_host = 3;
}
```

Change these messages (keep existing fields and numbers):

```proto
message SetGitHubCredentialRequest {
  string token = 1;
  // Which server the token is for; unset is github.com.
  GithubServer server = 2;
}

message ClearGitHubCredentialRequest {
  // Empty clears github.com's token; an Enterprise id forgets that server.
  string server_id = 1;
}

message CheckGitHubTokenRequest {
  string token = 1;
  // The server to ask; unset is github.com.
  GithubServer server = 2;
}

message ListPullRequestsRequest {
  google.protobuf.Timestamp closed_since = 1;
  // Server id; empty is github.com.
  string github_server = 2;
}

message ListGitHubRepositoriesRequest {
  // Server id; empty is github.com.
  string github_server = 1;
}
```

Add `string github_server = N;` (server id; empty is github.com; used only with `github_repository`) to:
`ListGitHubWorkflowsRequest` (N=3), `GetGitHubRepositoryRequest` (N=3), `ListWorkflowRunsRequest` (N=5), `ListRunJobsRequest` (N=4), `ListGitHubRefsRequest` (N=3), `DescribeWorkflowDispatchRequest` (N=5), `PrepareWorkflowDispatchRequest` (N=6).

```proto
message GitHubOrigin {
  string path = 1;
  string github_repository = 2;
  // Server id of the origin's host; empty is github.com.
  string github_server_id = 3;
}

message Repository {
  // ... fields 1-6 unchanged; update the comment of github_repository:
  // "owner/name" when the origin's host is github.com or a server the Core
  // holds; empty otherwise. The raw remote URL is never sent.
  string github_repository = 6;
  // Server id for github_repository; empty is github.com.
  string github_server_id = 7;
  // Host of the origin remote, lowercased, even when no server matches it,
  // so the app can say which server to add. Empty without an origin.
  string origin_host = 8;
}
```

Update the comment of `GetGitHubOriginsResponse.origins` to "One per path whose origin host is github.com or a server the Core holds".

- [ ] **Step 2: Regenerate and lint**

Run: `./scripts/generate-contracts.sh`
Expected: exits 0; `git status` shows changed generated files in `core/internal/gen` and `apps/macos/Runnir/IPC/Generated`.

Run: `cd contracts && buf lint`
Expected: no output.

- [ ] **Step 3: Build both sides unchanged**

Run: `cd core && go build ./... && go test ./internal/server/...`
Expected: PASS (new fields unused).

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add contracts core/internal/gen apps/macos/Runnir/IPC/Generated
git commit -m "Add GitHub server fields to the Core contract"
```

### Task 2: Server URLs and the redirect guard

**Files:**
- Create: `core/internal/github/server.go`
- Modify: `core/internal/github/client.go` (`NewClient`)
- Test: `core/internal/github/server_test.go`, `core/internal/github/client_test.go`

**Interfaces:**
- Produces:
  - `type Server struct { ID, APIURL, WebHost string }`
  - `const DotComHost = "github.com"`
  - `func DotCom(apiURL string) Server` — github.com, `apiURL` empty means `https://api.github.com`.
  - `func (s Server) Validate() error` — returns `ErrInvalidServer` for an Enterprise server that breaks the URL rules.
  - `var ErrInvalidServer = errors.New("invalid GitHub server")`
  - `func NormalizeHost(host string) string` — lowercased, port stripped.

- [ ] **Step 1: Write the failing tests**

`core/internal/github/server_test.go`:

```go
package github

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestServerValidate(t *testing.T) {
	ok := []Server{
		{ID: "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed", APIURL: "https://github.company.com/api/v3", WebHost: "github.company.com"},
		{ID: "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed", APIURL: "https://api.company.ghe.com", WebHost: "company.ghe.com"},
		{ID: "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed", APIURL: "https://ghe.example:8443/api/v3", WebHost: "ghe.example"},
		{ID: "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed", APIURL: "http://127.0.0.1:3000", WebHost: "ghe.test"},
	}
	for _, s := range ok {
		if err := s.Validate(); err != nil {
			t.Errorf("%+v: %v", s, err)
		}
	}
	bad := []Server{
		{ID: "x", APIURL: "https://github.company.com/api/v3", WebHost: "github.company.com"},                                     // id not a UUID
		{ID: "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed", APIURL: "http://github.company.com/api/v3", WebHost: "github.company.com"},     // http off loopback
		{ID: "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed", APIURL: "https://user:pw@github.company.com", WebHost: "github.company.com"},   // user info
		{ID: "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed", APIURL: "https://github.company.com/api/v3?x=1", WebHost: "github.company.com"}, // query
		{ID: "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed", APIURL: "https:///api/v3", WebHost: "github.company.com"},                      // no host
		{ID: "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed", APIURL: "https://github.company.com/api/v3", WebHost: "github.com"},           // github.com
		{ID: "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed", APIURL: "https://github.company.com/api/v3", WebHost: "bad host"},             // web host
	}
	for _, s := range bad {
		if err := s.Validate(); !errors.Is(err, ErrInvalidServer) {
			t.Errorf("%+v: want ErrInvalidServer, got %v", s, err)
		}
	}
	if err := DotCom("").Validate(); err != nil {
		t.Errorf("github.com: %v", err)
	}
}

func TestNormalizeHost(t *testing.T) {
	for in, want := range map[string]string{"GitHub.Company.com": "github.company.com", "ghe.example:2222": "ghe.example", "[::1]:22": "::1"} {
		if got := NormalizeHost(in); got != want {
			t.Errorf("NormalizeHost(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestClientRefusesRedirectToAnotherOrigin(t *testing.T) {
	var leaked bool
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		leaked = r.Header.Get("Authorization") != ""
		_, _ = w.Write([]byte(`{}`))
	}))
	defer other.Close()
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, other.URL+"/user", http.StatusFound)
	}))
	defer api.Close()
	credential := &Credential{}
	_ = credential.Set("ghp_test")
	client := NewClient(credential, api.URL, "test")
	var out map[string]any
	if err := client.get(t.Context(), "/user", nil, &out); err == nil {
		t.Fatal("a redirect to another origin was followed")
	}
	if leaked {
		t.Fatal("the token reached another origin")
	}
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd core && go test ./internal/github/ -run 'TestServerValidate|TestNormalizeHost|TestClientRefusesRedirect' -v`
Expected: FAIL — `undefined: Server`, `undefined: NormalizeHost`.

- [ ] **Step 3: Implement**

`core/internal/github/server.go`:

```go
package github

import (
	"errors"
	"net"
	"net/url"
	"regexp"
	"strings"
)

// ErrInvalidServer rejects an Enterprise server whose URLs break the rules.
var ErrInvalidServer = errors.New("invalid GitHub server")

// DotComHost is github.com's web host.
const DotComHost = "github.com"

// Server is where a token belongs: github.com (empty ID) or an Enterprise
// server the app registered.
type Server struct {
	// Empty for github.com; a lowercase UUID for an Enterprise server.
	ID string
	// The REST API root, such as "https://github.company.com/api/v3".
	APIURL string
	// The web URL's host, lowercased, without port.
	WebHost string
}

// DotCom is github.com; apiURL overrides https://api.github.com for tests.
func DotCom(apiURL string) Server {
	if apiURL == "" {
		apiURL = defaultBaseURL
	}
	return Server{APIURL: apiURL, WebHost: DotComHost}
}

var (
	serverID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	hostName = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?$`)
)

// Validate checks an Enterprise server: a UUID id; an https API URL (http
// only for a loopback host) with a host and no user info, query or
// fragment; a web host that is a host name other than github.com.
// github.com itself is always valid.
func (s Server) Validate() error {
	if s.ID == "" {
		return nil
	}
	if !serverID.MatchString(s.ID) {
		return ErrInvalidServer
	}
	api, err := url.Parse(s.APIURL)
	if err != nil || api.Host == "" || api.User != nil || api.RawQuery != "" || api.Fragment != "" || api.Opaque != "" {
		return ErrInvalidServer
	}
	switch api.Scheme {
	case "https":
	case "http":
		if !isLoopback(api.Hostname()) {
			return ErrInvalidServer
		}
	default:
		return ErrInvalidServer
	}
	if s.WebHost != NormalizeHost(s.WebHost) || s.WebHost == DotComHost || !hostName.MatchString(s.WebHost) {
		return ErrInvalidServer
	}
	return nil
}

// NormalizeHost lowercases a host and drops its port.
func NormalizeHost(host string) string {
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	return strings.ToLower(strings.Trim(host, "[]"))
}

func isLoopback(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
```

In `core/internal/github/client.go`, replace the `http:` field in `NewClient`:

```go
		http: &http.Client{
			Timeout: 20 * time.Second,
			// The token goes only to the API's own origin: a redirect
			// elsewhere ends the request instead of being followed.
			CheckRedirect: func(request *http.Request, via []*http.Request) error {
				first := via[0].URL
				if request.URL.Scheme != first.Scheme || !strings.EqualFold(request.URL.Host, first.Host) {
					return errCrossOriginRedirect
				}
				if len(via) >= 10 {
					return errors.New("stopped after 10 redirects")
				}
				return nil
			},
		},
```

and add next to the other package errors in `client.go`:

```go
var errCrossOriginRedirect = errors.New("redirect to another origin")
```

(`exchange` already maps a `Do` error to `ErrUnavailable`.)

- [ ] **Step 4: Run to verify they pass**

Run: `cd core && go test ./internal/github/ -v -run 'TestServerValidate|TestNormalizeHost|TestClientRefusesRedirect' && go test ./internal/github/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/internal/github/server.go core/internal/github/server_test.go core/internal/github/client.go
git commit -m "Describe GitHub servers and keep tokens on their API origin"
```

### Task 3: One credential and client per server

**Files:**
- Create: `core/internal/github/accounts.go`
- Test: `core/internal/github/accounts_test.go`

**Interfaces:**
- Consumes: `Server`, `DotCom`, `NormalizeHost`, `ErrInvalidServer` (Task 2); `Credential`, `NewClient` (existing).
- Produces:
  - `type Account struct { Server Server; Credential *Credential; Client *Client }`
  - `func NewAccounts(dotComAPIURL, version string) *Accounts`
  - `func (a *Accounts) Get(id string) (*Account, bool)` — github.com (`""`) always exists.
  - `func (a *Accounts) ForHost(host string) (*Account, bool)` — by web host, any case or port.
  - `func (a *Accounts) Set(server Server, token string) (*Account, error)` — `ErrInvalidServer`, `ErrInvalidToken`, or `ErrTooManyServers`.
  - `func (a *Accounts) Clear(id string)` — github.com: forget the token; Enterprise: forget the server.
  - `func (a *Accounts) Checker(server Server) (*Client, error)` — a client without a token for `CheckToken`.
  - `const MaxEnterpriseServers = 10`, `var ErrTooManyServers`.

- [ ] **Step 1: Write the failing test**

`core/internal/github/accounts_test.go`:

```go
package github

import (
	"errors"
	"testing"
)

const enterpriseID = "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"

func enterprise(id, host string) Server {
	return Server{ID: id, APIURL: "https://" + host + "/api/v3", WebHost: host}
}

func TestAccountsKeepTokensApart(t *testing.T) {
	accounts := NewAccounts("", "test")
	dotcom, ok := accounts.Get("")
	if !ok || dotcom.Server.WebHost != "github.com" {
		t.Fatalf("github.com = %+v, %v", dotcom, ok)
	}
	if _, has := dotcom.Credential.Token(); has {
		t.Fatal("github.com starts without a token")
	}
	if _, err := accounts.Set(DotCom(""), "ghu_dotcom"); err != nil {
		t.Fatal(err)
	}
	company, err := accounts.Set(enterprise(enterpriseID, "github.company.com"), "ghp_company")
	if err != nil {
		t.Fatal(err)
	}
	if token, _ := company.Credential.Token(); token != "ghp_company" {
		t.Fatalf("company token = %q", token)
	}
	if token, _ := dotcom.Credential.Token(); token != "ghu_dotcom" {
		t.Fatalf("github.com token = %q", token)
	}
	if found, ok := accounts.ForHost("GitHub.Company.com:22"); !ok || found != company {
		t.Fatalf("ForHost = %v, %v", found, ok)
	}
	if found, ok := accounts.ForHost("github.com"); !ok || found != dotcom {
		t.Fatalf("ForHost(github.com) = %v, %v", found, ok)
	}
	if _, ok := accounts.ForHost("gitlab.com"); ok {
		t.Fatal("an unknown host matched")
	}

	accounts.Clear(enterpriseID)
	if _, ok := accounts.Get(enterpriseID); ok {
		t.Fatal("a cleared Enterprise server stays")
	}
	accounts.Clear("")
	if _, ok := accounts.Get(""); !ok {
		t.Fatal("github.com is always there")
	}
	if _, has := dotcom.Credential.Token(); has {
		t.Fatal("github.com's token stays after Clear")
	}
}

func TestAccountsRefuseBadServers(t *testing.T) {
	accounts := NewAccounts("", "test")
	if _, err := accounts.Set(enterprise(enterpriseID, "github.company.com"), "ghp_a"); err != nil {
		t.Fatal(err)
	}
	other := "2c9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"
	if _, err := accounts.Set(enterprise(other, "github.company.com"), "ghp_b"); !errors.Is(err, ErrInvalidServer) {
		t.Fatalf("same web host twice: %v", err)
	}
	if _, err := accounts.Set(Server{ID: other, APIURL: "http://ghe.example/api/v3", WebHost: "ghe.example"}, "ghp_b"); !errors.Is(err, ErrInvalidServer) {
		t.Fatalf("http: %v", err)
	}
	if _, err := accounts.Set(enterprise(other, "ghe.example"), "bad token"); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("token: %v", err)
	}
	// Setting the same id again with new URLs replaces its client.
	moved, err := accounts.Set(Server{ID: enterpriseID, APIURL: "https://api.company.ghe.com", WebHost: "company.ghe.com"}, "ghp_c")
	if err != nil || moved.Server.WebHost != "company.ghe.com" {
		t.Fatalf("replace = %+v, %v", moved, err)
	}
	if _, ok := accounts.ForHost("github.company.com"); ok {
		t.Fatal("the old host still matches")
	}
}

func TestAccountsLimitEnterpriseServers(t *testing.T) {
	accounts := NewAccounts("", "test")
	for i := 0; i < MaxEnterpriseServers; i++ {
		id := "00000000-0000-4000-8000-0000000000" + string(rune('a'+i/10)) + string(rune('0'+i%10))
		if _, err := accounts.Set(enterprise(id, "ghe"+string(rune('a'+i))+".example"), "ghp_x"); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := accounts.Set(enterprise("ffffffff-0000-4000-8000-000000000000", "one-more.example"), "ghp_x"); !errors.Is(err, ErrTooManyServers) {
		t.Fatalf("eleventh server: %v", err)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd core && go test ./internal/github/ -run TestAccounts -v`
Expected: FAIL — `undefined: NewAccounts`.

- [ ] **Step 3: Implement**

`core/internal/github/accounts.go`:

```go
package github

import (
	"errors"
	"sync"
)

// MaxEnterpriseServers bounds the Enterprise servers the Core holds.
const MaxEnterpriseServers = 10

// ErrTooManyServers refuses an Enterprise server past MaxEnterpriseServers.
var ErrTooManyServers = errors.New("too many GitHub servers")

// Account is one server with its own token and client; a token is never
// used for another server.
type Account struct {
	Server     Server
	Credential *Credential
	Client     *Client
}

// Accounts holds github.com, always, and the Enterprise servers the app
// signed in to. Safe for concurrent use.
type Accounts struct {
	mu       sync.RWMutex
	byID     map[string]*Account
	version  string
}

// NewAccounts starts with github.com and no token; dotComAPIURL overrides
// https://api.github.com for tests.
func NewAccounts(dotComAPIURL, version string) *Accounts {
	a := &Accounts{byID: map[string]*Account{}, version: version}
	a.byID[""] = a.newAccount(DotCom(dotComAPIURL))
	return a
}

func (a *Accounts) newAccount(server Server) *Account {
	credential := &Credential{}
	return &Account{Server: server, Credential: credential, Client: NewClient(credential, server.APIURL, a.version)}
}

// Get returns the account for a server id; "" is github.com.
func (a *Accounts) Get(id string) (*Account, bool) {
	a.mu.RLock()
	defer a.mu.RUnlock()
	account, ok := a.byID[id]
	return account, ok
}

// ForHost finds the account whose web host is host, ignoring case and port.
func (a *Accounts) ForHost(host string) (*Account, bool) {
	host = NormalizeHost(host)
	a.mu.RLock()
	defer a.mu.RUnlock()
	for _, account := range a.byID {
		if account.Server.WebHost == host {
			return account, true
		}
	}
	return nil, false
}

// Set gives a server its token. github.com keeps its own URLs whatever the
// request says; an Enterprise server is added, or replaced when its URLs
// changed, so a token never reaches a URL it was not set for.
func (a *Accounts) Set(server Server, token string) (*Account, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if server.ID == "" {
		dotcom := a.byID[""]
		return dotcom, dotcom.Credential.Set(token)
	}
	if err := server.Validate(); err != nil {
		return nil, err
	}
	enterpriseCount := 0
	for id, account := range a.byID {
		if id != "" && id != server.ID {
			enterpriseCount++
		}
		if id != server.ID && account.Server.WebHost == server.WebHost {
			return nil, ErrInvalidServer
		}
	}
	if _, exists := a.byID[server.ID]; !exists && enterpriseCount >= MaxEnterpriseServers {
		return nil, ErrTooManyServers
	}
	account, exists := a.byID[server.ID]
	if !exists || account.Server != server {
		account = a.newAccount(server)
	}
	if err := account.Credential.Set(token); err != nil {
		return nil, err
	}
	a.byID[server.ID] = account
	return account, nil
}

// Clear forgets github.com's token, or an Enterprise server altogether.
func (a *Accounts) Clear(id string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if id == "" {
		a.byID[""].Credential.Clear()
		return
	}
	delete(a.byID, id)
}

// Checker is a client for server with no token of its own, for CheckToken.
func (a *Accounts) Checker(server Server) (*Client, error) {
	if server.ID == "" {
		dotcom, _ := a.Get("")
		server = dotcom.Server
	} else if err := server.Validate(); err != nil {
		return nil, err
	}
	return NewClient(&Credential{}, server.APIURL, a.version), nil
}
```

Run `gofmt -w core/internal/github/accounts.go` (aligns the struct fields).

- [ ] **Step 4: Run to verify it passes**

Run: `cd core && go test -race ./internal/github/ -run TestAccounts -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/internal/github/accounts.go core/internal/github/accounts_test.go
git commit -m "Hold a credential and client per GitHub server in the Core"
```

### Task 4: Origins on any host

**Files:**
- Modify: `core/internal/scanner/scanner.go` (`gitHubRepository` → `parseOrigin`, `readGitHubRepository` → `readOrigin`, `GitHubOrigin` → `Origin`, `Scan`)
- Modify: `core/internal/repository/manager.go` (`Snapshot`, `Info`)
- Modify: `core/internal/server/service.go` (`toProto` → `(*service).repositoryMessage`), its 3 callers
- Test: `core/internal/scanner/scanner_test.go`

**Interfaces:**
- Produces:
  - `func scanner.Origin(root string) (host, repository string)` — host lowercased without port; repository "owner/name"; both empty when there is no readable origin.
  - `repository.Snapshot.OriginHost`, `repository.Snapshot.OriginRepository` (replace `GitHubRepository`); same two fields on `repository.Info`.
  - `func (s *service) repositoryMessage(info repository.Info) *corev1.Repository`

- [ ] **Step 1: Write the failing test**

Replace the table test of `gitHubRepository` in `core/internal/scanner/scanner_test.go` (search for `gitHubRepository(`) with:

```go
func TestParseOrigin(t *testing.T) {
	cases := []struct{ remote, host, repository string }{
		{"git@github.com:o/r.git", "github.com", "o/r"},
		{"https://github.com/o/r", "github.com", "o/r"},
		{"git@GitHub.Company.com:org/app.git", "github.company.com", "org/app"},
		{"ssh://git@github.company.com:2222/org/app.git", "github.company.com", "org/app"},
		{"https://company.ghe.com/org/app.git", "company.ghe.com", "org/app"},
		{"https://gitlab.com/group/project.git", "gitlab.com", "group/project"},
		{"https://github.com/o/r/extra", "", ""},
		{"file:///tmp/r.git", "", ""},
		{"git@github.com:../r.git", "", ""},
		{"", "", ""},
	}
	for _, c := range cases {
		host, repository := parseOrigin(c.remote)
		if host != c.host || repository != c.repository {
			t.Errorf("parseOrigin(%q) = %q, %q; want %q, %q", c.remote, host, repository, c.host, c.repository)
		}
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd core && go test ./internal/scanner/ -run TestParseOrigin -v`
Expected: FAIL — `undefined: parseOrigin`.

- [ ] **Step 3: Implement the scanner change**

In `core/internal/scanner/scanner.go` replace `gitHubRepository` with:

```go
// parseOrigin turns a remote URL into its host (lowercased, without port)
// and "owner/name"; a path that is not exactly owner/name, a local or
// unknown scheme, or a malformed URL gives "", "". Which hosts are GitHub
// servers is the Core's choice, not the scanner's.
func parseOrigin(remote string) (host, repository string) {
	var path string
	if user, rest, ok := strings.Cut(remote, "@"); ok && !strings.Contains(user, "/") && !strings.Contains(remote, "://") {
		// scp-like: git@host:owner/name.git
		h, p, ok := strings.Cut(rest, ":")
		if !ok || h == "" {
			return "", ""
		}
		host, path = h, p
	} else {
		parsed, err := url.Parse(remote)
		if err != nil || parsed.Hostname() == "" {
			return "", ""
		}
		switch parsed.Scheme {
		case "https", "http", "ssh", "git":
		default:
			return "", ""
		}
		host, path = parsed.Hostname(), parsed.Path
	}
	path = strings.TrimSuffix(strings.Trim(path, "/"), ".git")
	owner, name, ok := strings.Cut(path, "/")
	if !ok || !validOwner.MatchString(owner) || !validName.MatchString(name) {
		return "", ""
	}
	return strings.ToLower(host), owner + "/" + name
}
```

Rename `readGitHubRepository(gitDir, linked) string` to `readOrigin(gitDir string, linked bool) (host, repository string)`, ending with `return parseOrigin(originURL(string(config)))` and returning `"", ""` where it returned `""`.

Replace `GitHubOrigin`:

```go
// Origin returns the host and "owner/name" of the working tree's origin
// remote (also through a linked worktree), or "", "" when it has none or
// it cannot be read. It reads only git's metadata, bounded.
func Origin(root string) (host, repository string) {
	if gitDir, linked, ok := resolveGitDir(root); ok {
		return readOrigin(gitDir, linked)
	}
	return "", ""
}
```

In `Scan`: `snapshot.OriginHost, snapshot.OriginRepository = readOrigin(gitDir, linked)`.

In `core/internal/repository/manager.go`, in both `Snapshot` and `Info`, replace `GitHubRepository string` with:

```go
	// OriginHost is the origin remote's host, lowercased; OriginRepository
	// its "owner/name". Both empty without a readable origin.
	OriginHost       string
	OriginRepository string
```

and in the two `Info{...}` literals replace `GitHubRepository: e.snap.GitHubRepository` with `OriginHost: e.snap.OriginHost, OriginRepository: e.snap.OriginRepository`.

- [ ] **Step 4: Server: build the repository message from the accounts**

In `core/internal/server/service.go` replace `toProto` with a method (the `accounts` field arrives in Task 5; until then use the github.com-only rule below so this task compiles on its own):

```go
func (s *service) repositoryMessage(info repository.Info) *corev1.Repository {
	out := &corev1.Repository{
		Id: info.ID, Path: info.Path, Branch: info.Branch, WorkflowCount: uint32(info.WorkflowCount),
		OriginHost: info.OriginHost,
	}
	if info.OriginHost == github.DotComHost {
		out.GithubRepository = info.OriginRepository
	}
	if !info.LastRefresh.IsZero() {
		out.LastRefresh = timestamppb.New(info.LastRefresh)
	}
	return out
}
```

Replace the 3 calls `toProto(x)` with `s.repositoryMessage(x)` (`grep -n "toProto(" core/internal/server/*.go`). In `githubTarget` (github.go) replace `info.GitHubRepository` with `info.OriginRepository` guarded by `info.OriginHost == github.DotComHost`; in `GetGitHubOrigins` use `host, name := scanner.Origin(...)` and append only when `host == github.DotComHost`. Fix the test files that read `GitHubRepository` on `repository.Info`/`Snapshot` (`grep -rn "GitHubRepository" core/internal --include=*_test.go`) to the new field names.

- [ ] **Step 5: Run the Core tests**

Run: `cd core && go test ./... && go vet ./...`
Expected: PASS (behaviour for github.com unchanged).

- [ ] **Step 6: Commit**

```bash
git add core/internal/scanner core/internal/repository core/internal/server
git commit -m "Read a working tree's origin host, not only github.com"
```

### Task 5: Route every GitHub call to its server

**Files:**
- Modify: `core/internal/server/server.go` (construct `github.NewAccounts`)
- Modify: `core/internal/server/service.go` (fields, `HealthCheck`, `SetGitHubCredential`, `ClearGitHubCredential`, `repositoryMessage`)
- Modify: `core/internal/server/github.go`, `dispatch.go`, `runs.go`, `pulls.go`
- Modify: `core/internal/dispatch/dispatch.go` (`Request.ServerID`)
- Test: `core/internal/server/enterprise_test.go` (new)

**Interfaces:**
- Consumes: `github.Accounts`, `Account`, `Server`, `ErrInvalidServer`, `ErrTooManyServers` (Tasks 2–3); `scanner.Origin`, `Info.OriginHost/OriginRepository` (Task 4); proto fields (Task 1).
- Produces:
  - `type githubRepo struct { account *github.Account; owner, name string }`
  - `func (s *service) githubTarget(repositoryID, serverID, githubRepository string) (githubRepo, *corev1.GitHubStatus, error)`
  - `func (s *service) githubStatus(account *github.Account, err error) (*corev1.GitHubStatus, error)`
  - `func serverFrom(message *corev1.GithubServer) github.Server`
  - `dispatch.Request.ServerID string`, `runAction.ServerID string`

- [ ] **Step 1: Write the failing test**

`core/internal/server/enterprise_test.go`:

```go
//go:build !windows

package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

const companyID = "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"

// fakeAPI answers runs for o/r and records the tokens it saw.
func fakeAPI(t *testing.T) (*httptest.Server, func() []string) {
	t.Helper()
	var mu sync.Mutex
	var tokens []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		tokens = append(tokens, strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
		mu.Unlock()
		if r.URL.Path == "/repos/o/r/actions/runs" {
			_, _ = w.Write([]byte(`{"workflow_runs":[]}`))
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(server.Close)
	return server, func() []string { mu.Lock(); defer mu.Unlock(); return append([]string(nil), tokens...) }
}

func TestEnterpriseCallsGoToTheirServer(t *testing.T) {
	dotcom, dotcomTokens := fakeAPI(t)
	company, companyTokens := fakeAPI(t)
	path := socketPath(t)
	stop := startWith(t, path, Options{GitHubBaseURL: dotcom.URL})
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if _, err := client.SetGitHubCredential(ctx, &corev1.SetGitHubCredentialRequest{Token: "ghu_dotcom"}); err != nil {
		t.Fatal(err)
	}
	server := &corev1.GithubServer{Id: companyID, ApiUrl: company.URL, WebHost: "github.company.com"}
	if _, err := client.SetGitHubCredential(ctx, &corev1.SetGitHubCredentialRequest{Token: "ghp_company", Server: server}); err != nil {
		t.Fatal(err)
	}

	// A working tree on the Enterprise host goes to the Enterprise API.
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: linkedRepository(t, "git@github.company.com:o/r.git")})
	if err != nil {
		t.Fatal(err)
	}
	if opened.Repository.GithubRepository != "o/r" || opened.Repository.GithubServerId != companyID || opened.Repository.OriginHost != "github.company.com" {
		t.Fatalf("repository = %+v", opened.Repository)
	}
	runs, err := client.ListWorkflowRuns(ctx, &corev1.ListWorkflowRunsRequest{RepositoryId: opened.Repository.Id})
	if err != nil || runs.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_OK {
		t.Fatalf("runs = %v, %v", runs, err)
	}
	// A named repository goes where github_server says.
	if _, err := client.ListWorkflowRuns(ctx, &corev1.ListWorkflowRunsRequest{GithubRepository: "o/r", GithubServer: companyID}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.ListWorkflowRuns(ctx, &corev1.ListWorkflowRunsRequest{GithubRepository: "o/r"}); err != nil {
		t.Fatal(err)
	}
	for _, token := range companyTokens() {
		if token != "ghp_company" {
			t.Fatalf("the Enterprise API saw %q", token)
		}
	}
	for _, token := range dotcomTokens() {
		if token != "ghu_dotcom" {
			t.Fatalf("github.com saw %q", token)
		}
	}
	if len(companyTokens()) != 2 || len(dotcomTokens()) != 1 {
		t.Fatalf("calls: company %d, github.com %d", len(companyTokens()), len(dotcomTokens()))
	}

	// An unknown server is signed out; forgetting the server makes the
	// working tree's origin unknown again.
	unknown, err := client.ListWorkflowRuns(ctx, &corev1.ListWorkflowRunsRequest{GithubRepository: "o/r", GithubServer: "2c9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"})
	if err != nil || unknown.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT {
		t.Fatalf("unknown server = %v, %v", unknown, err)
	}
	if _, err := client.ClearGitHubCredential(ctx, &corev1.ClearGitHubCredentialRequest{ServerId: companyID}); err != nil {
		t.Fatal(err)
	}
	gone, err := client.ListWorkflowRuns(ctx, &corev1.ListWorkflowRunsRequest{RepositoryId: opened.Repository.Id})
	if err != nil || gone.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_NO_REMOTE {
		t.Fatalf("after removal = %v, %v", gone, err)
	}
}

func TestEnterpriseServerMustBeValid(t *testing.T) {
	path := socketPath(t)
	stop := startWith(t, path, Options{})
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	bad := &corev1.GithubServer{Id: companyID, ApiUrl: "http://github.company.com/api/v3", WebHost: "github.company.com"}
	_, err := client.SetGitHubCredential(ctx, &corev1.SetGitHubCredentialRequest{Token: "ghp_x", Server: bad})
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("http off loopback: %v", err)
	}
	_, err = client.CheckGitHubToken(ctx, &corev1.CheckGitHubTokenRequest{Token: "ghp_x", Server: bad})
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("check against a bad server: %v", err)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd core && go test ./internal/server/ -run TestEnterprise -v`
Expected: FAIL — the Enterprise call reaches github.com or `GithubServerId` is empty.

- [ ] **Step 3: Replace the single client with accounts**

`core/internal/server/server.go`: delete `credential := &github.Credential{}` and in the `&service{...}` literal replace `credential: credential,` and `github: github.NewClient(...)` with:

```go
		accounts: github.NewAccounts(options.GitHubBaseURL, buildinfo.Version),
```

`core/internal/server/service.go`: in `service` replace the `credential` and `github` fields with:

```go
	// accounts holds github.com and the Enterprise servers, each with its
	// own token and client.
	accounts *github.Accounts
```

Replace `hasCredential`, `SetGitHubCredential`, `ClearGitHubCredential`:

```go
// hasCredential reports github.com's token, as before Enterprise servers.
func (s *service) hasCredential() bool {
	dotcom, _ := s.accounts.Get("")
	_, ok := dotcom.Credential.Token()
	return ok
}

// serverFrom reads a request's server; nil is github.com.
func serverFrom(message *corev1.GithubServer) github.Server {
	if message == nil || message.GetId() == "" {
		return github.Server{}
	}
	return github.Server{ID: message.GetId(), APIURL: message.GetApiUrl(), WebHost: message.GetWebHost()}
}

func (s *service) SetGitHubCredential(_ context.Context, request *corev1.SetGitHubCredentialRequest) (*corev1.SetGitHubCredentialResponse, error) {
	account, err := s.accounts.Set(serverFrom(request.GetServer()), request.GetToken())
	switch {
	case errors.Is(err, github.ErrInvalidServer):
		return nil, status.Error(codes.InvalidArgument, "not a valid GitHub server")
	case errors.Is(err, github.ErrTooManyServers):
		return nil, status.Errorf(codes.ResourceExhausted, "at most %d Enterprise servers", github.MaxEnterpriseServers)
	case err != nil:
		return nil, status.Error(codes.InvalidArgument, "not a valid GitHub token")
	}
	return &corev1.SetGitHubCredentialResponse{Kind: credentialKind(account.Credential.Kind())}, nil
}

func (s *service) ClearGitHubCredential(_ context.Context, request *corev1.ClearGitHubCredentialRequest) (*corev1.ClearGitHubCredentialResponse, error) {
	s.accounts.Clear(request.GetServerId())
	return &corev1.ClearGitHubCredentialResponse{}, nil
}
```

Update `repositoryMessage` to use the accounts:

```go
func (s *service) repositoryMessage(info repository.Info) *corev1.Repository {
	out := &corev1.Repository{
		Id: info.ID, Path: info.Path, Branch: info.Branch, WorkflowCount: uint32(info.WorkflowCount),
		OriginHost: info.OriginHost,
	}
	if account, ok := s.accounts.ForHost(info.OriginHost); ok && info.OriginHost != "" {
		out.GithubRepository = info.OriginRepository
		out.GithubServerId = account.Server.ID
	}
	if !info.LastRefresh.IsZero() {
		out.LastRefresh = timestamppb.New(info.LastRefresh)
	}
	return out
}
```

- [ ] **Step 4: Resolve the target and status per account**

In `core/internal/server/github.go` replace `githubTarget` and `githubStatus`:

```go
// githubRepo is a repository on one server, with that server's account.
type githubRepo struct {
	account     *github.Account
	owner, name string
}

// githubTarget resolves a request's repository: githubRepository
// ("owner/name") on serverID ("" is github.com) for a repository without a
// local clone, otherwise the origin of the open repository repositoryID on
// the server whose web host it names. An unknown server is SIGNED_OUT and
// an origin on no known server NO_REMOTE, both statuses; an unknown
// repository id is NOT_FOUND and a malformed name INVALID_ARGUMENT.
func (s *service) githubTarget(repositoryID, serverID, githubRepository string) (githubRepo, *corev1.GitHubStatus, error) {
	if githubRepository != "" {
		if !github.ValidRepository(githubRepository) {
			return githubRepo{}, nil, status.Error(codes.InvalidArgument, "github_repository must be owner/name")
		}
		account, ok := s.accounts.Get(serverID)
		if !ok {
			return githubRepo{}, &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT}, nil
		}
		owner, name, _ := strings.Cut(githubRepository, "/")
		return githubRepo{account: account, owner: owner, name: name}, nil, nil
	}
	info, err := s.repositories.Get(repositoryID)
	if err != nil {
		return githubRepo{}, nil, rpcError(err)
	}
	owner, name, ok := strings.Cut(info.OriginRepository, "/")
	account, known := s.accounts.ForHost(info.OriginHost)
	if !ok || owner == "" || name == "" || info.OriginHost == "" || !known {
		return githubRepo{}, &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_NO_REMOTE}, nil
	}
	return githubRepo{account: account, owner: owner, name: name}, nil, nil
}

// githubStatus maps a client error to the status returned to the app, and
// forgets the token of the account GitHub rejected. Context errors stay
// call errors.
func (s *service) githubStatus(account *github.Account, err error) (*corev1.GitHubStatus, error) {
	var rateLimit *github.RateLimitError
	switch {
	case err == nil:
		return &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_OK}, nil
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return nil, status.FromContextError(err).Err()
	case errors.Is(err, github.ErrNoCredential):
		return &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT}, nil
	case errors.Is(err, github.ErrUnauthorized):
		account.Credential.Clear()
		return &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_TOKEN_REJECTED}, nil
	case errors.Is(err, github.ErrNotVisible):
		return &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_NOT_VISIBLE}, nil
	case errors.Is(err, github.ErrPermissionMissing):
		return &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_PERMISSION_MISSING}, nil
	case errors.As(err, &rateLimit):
		return &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_RATE_LIMITED, RetryAfter: timestamppb.New(rateLimit.Reset)}, nil
	default:
		return &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE}, nil
	}
}
```

Then update every handler with this mechanical pattern (shown for `ListGitHubWorkflows`; apply the same to `GetGitHubRepository`, `ListWorkflowRuns`, `ListRunJobs` in github.go, `ListGitHubRefs`, `DescribeWorkflowDispatch`, `PrepareWorkflowDispatch` in dispatch.go, and `GetJobLog`, `PrepareRunAction` in runs.go, which pass `""` for both serverID and githubRepository):

```go
	target, problem, err := s.githubTarget(request.GetRepositoryId(), request.GetGithubServer(), request.GetGithubRepository())
	if err != nil || problem != nil {
		return &corev1.ListGitHubWorkflowsResponse{Status: problem}, err
	}
	workflows, fetchErr := target.account.Client.Workflows(ctx, target.owner, target.name)
	result, err := s.githubStatus(target.account, fetchErr)
```

(`s.github.X(ctx, owner, name, ...)` → `target.account.Client.X(ctx, target.owner, target.name, ...)`; `s.githubStatus(err)` → `s.githubStatus(target.account, err)`; `s.github.InstallationFor(ctx, owner)` → `target.account.Client.InstallationFor(ctx, target.owner)`.)

`ListGitHubRepositories`:

```go
func (s *service) ListGitHubRepositories(ctx context.Context, request *corev1.ListGitHubRepositoriesRequest) (*corev1.ListGitHubRepositoriesResponse, error) {
	account, ok := s.accounts.Get(request.GetGithubServer())
	if !ok {
		return &corev1.ListGitHubRepositoriesResponse{Status: &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT}}, nil
	}
	listing, fetchErr := account.Client.AccountRepositories(ctx)
	result, err := s.githubStatus(account, fetchErr)
	if err != nil {
		return nil, err
	}
	out := &corev1.ListGitHubRepositoriesResponse{Status: result, Truncated: listing.Truncated,
		CredentialKind: credentialKind(account.Credential.Kind())}
	// ... the two existing loops over listing.Installations and listing.Repositories, unchanged
	return out, nil
}
```

`GetGitHubOrigins` loop body:

```go
		host, name := scanner.Origin(filepath.Clean(path))
		if account, ok := s.accounts.ForHost(host); ok && host != "" && name != "" {
			out.Origins = append(out.Origins, &corev1.GitHubOrigin{Path: path, GithubRepository: name, GithubServerId: account.Server.ID})
		}
```

`CheckGitHubToken` first lines:

```go
	checker, err := s.accounts.Checker(serverFrom(request.GetServer()))
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "not a valid GitHub server")
	}
	check, err := checker.CheckToken(ctx, request.GetToken())
```

`core/internal/server/pulls.go`:

```go
	account, ok := s.accounts.Get(request.GetGithubServer())
	if !ok {
		return &corev1.ListPullRequestsResponse{Status: &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT}}, nil
	}
	pulls, fetchErr := account.Client.MyPullRequests(ctx, since)
	result, err := s.githubStatus(account, fetchErr)
```

Prepared actions remember their server. `core/internal/dispatch/dispatch.go` `Request` gains `ServerID string` (comment: "the server the repository is on; \"\" is github.com"). In `PrepareWorkflowDispatch` pass `ServerID: target.account.Server.ID`. `runAction` in runs.go gains `ServerID string`; `PrepareRunAction` sets it. In both Confirm handlers resolve the account first:

```go
	account, ok := s.accounts.Get(prepared.ServerID)
	if !ok {
		return &corev1.ConfirmWorkflowDispatchResponse{Status: &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT}}, nil
	}
	runID, sendErr := account.Client.Dispatch(ctx, prepared.Owner, prepared.Name, prepared.WorkflowID, prepared.Ref, prepared.Inputs)
```

(same in `ConfirmRunAction` with `account.Client.CancelRun/RerunRun`, `s.githubStatus(account, sendErr)`). A dispatch prepared for an Enterprise server whose token is later replaced still goes to that server id, never to another.

- [ ] **Step 5: Run the Core suite**

Run: `cd core && go test -race ./... && go vet ./... && go build ./...`
Expected: PASS, including `TestEnterpriseCallsGoToTheirServer` and the existing github.com tests.

- [ ] **Step 6: Commit**

```bash
git add core/internal
git commit -m "Route GitHub calls to the server of the repository"
```

### Task 6: act fetches actions from the Enterprise server

**Files:**
- Modify: `core/internal/localrun/runner.go` (`Spec`, `Args`)
- Modify: `core/internal/server/localruns.go` (`PrepareLocalRun`)
- Test: `core/internal/localrun/runner_test.go`

**Interfaces:**
- Consumes: `s.accounts.ForHost`, `repository.Info.OriginHost`.
- Produces: `localrun.Spec.GitHubInstance string` — an Enterprise web host, or "" for github.com.

- [ ] **Step 1: Write the failing test**

Add to `core/internal/localrun/runner_test.go`:

```go
func TestArgsNameTheEnterpriseInstance(t *testing.T) {
	spec := &Spec{RepositoryPath: "/repo", Plan: Plan{WorkflowID: ".github/workflows/ci.yml", Event: "push"}}
	for _, arg := range Args(spec, "e1", "/scratch") {
		if strings.HasPrefix(arg, "--github-instance") {
			t.Fatalf("github.com run has %q", arg)
		}
	}
	spec.GitHubInstance = "github.company.com"
	args := Args(spec, "e1", "/scratch")
	if !slices.Contains(args, "--github-instance=github.company.com") {
		t.Fatalf("args = %v", args)
	}
	if slices.Index(args, "--github-instance=github.company.com") > slices.Index(args, "--") {
		t.Fatal("the flag comes after --")
	}
}
```

(Add `"slices"` and `"strings"` to the test imports if missing.)

- [ ] **Step 2: Run to verify it fails**

Run: `cd core && go test ./internal/localrun/ -run TestArgsNameTheEnterpriseInstance -v`
Expected: FAIL — `spec.GitHubInstance undefined`.

- [ ] **Step 3: Implement**

In `Spec` (runner.go) add:

```go
	// GitHubInstance is the Enterprise web host the repository is on, so
	// act fetches `uses:` actions there; empty for github.com. The token is
	// never given to act.
	GitHubInstance string
```

In `Args`, before `args = append(args, "--", plan.Event)`:

```go
	if spec.GitHubInstance != "" {
		args = append(args, "--github-instance="+spec.GitHubInstance)
	}
```

In `PrepareLocalRun` (localruns.go), where `Spec` is built, add:

```go
	instance := ""
	if account, ok := s.accounts.ForHost(info.OriginHost); ok && account.Server.ID != "" {
		instance = account.Server.WebHost
	}
```

and `GitHubInstance: instance,` in the `&localrun.Spec{...}` literal.

- [ ] **Step 4: Run to verify it passes**

Run: `cd core && go test ./internal/localrun/ ./internal/server/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/internal/localrun core/internal/server/localruns.go
git commit -m "Point act at the Enterprise server for its actions"
```

---

## Part B — App

### Task 7: Server-aware Core calls in the app

**Files:**
- Modify: `apps/macos/Runnir/IPC/CoreService.swift` (`CoreRepository`, `CoreServicing`, `CoreGitHubTarget`)
- Modify: `apps/macos/Runnir/IPC/CoreGitHubModels.swift` (new `GitHubServerRef`, `GitHubRepositoryRef`; `CorePullRequest.server`)
- Modify: `apps/macos/Runnir/IPC/GRPCCoreService.swift`
- Modify: `apps/macos/RunnirTests/CoreHubTests.swift` (`FakeCore`), `apps/macos/RunnirTests/CoreProcessSupervisorTests.swift` (its stub)
- Test: `apps/macos/RunnirTests/GitHubServerTests.swift` (new; add to the RunnirTests target in `Runnir.xcodeproj` with a new `C…` id as in earlier hand-added files)

**Interfaces:**
- Produces (Swift):
  - `struct GitHubServerRef: Hashable, Sendable, Codable { let id: String; let apiURL: URL?; let webHost: String; static let dotCom }` — `id == ""` is github.com.
  - `struct GitHubRepositoryRef: Hashable, Sendable, Codable { let serverID: String; let fullName: String; var key: String }` — `key` is `fullName` for github.com, `"\(serverID):\(fullName)"` otherwise.
  - `CoreGitHubTarget.named(GitHubRepositoryRef)` (was `.named(String)`).
  - `CoreServicing`:
    - `setGitHubCredential(_ token: String?, server: GitHubServerRef) async throws -> CoreGitHubCredentialKind?`
    - `checkGitHubToken(_ token: String, server: GitHubServerRef) async throws -> CoreGitHubTokenCheck`
    - `listPullRequests(server: String, closedSince: Date) async throws -> CorePullRequests`
    - `listGitHubRepositories(server: String) async throws -> CoreGitHubAccount`
    - `githubOrigins(paths: [String]) async throws -> [String: GitHubRepositoryRef]`
  - `CoreRepository.githubServerID: String?`, `CoreRepository.originHost: String?`.
  - `CorePullRequest.server: String` (server id) — set by the hub in Task 9.

- [ ] **Step 1: Write the failing test**

`apps/macos/RunnirTests/GitHubServerTests.swift`:

```swift
import Foundation
import Testing
@testable import Runnir

struct GitHubServerTests {
    @Test func repositoryKeysStayCompatibleForGitHubDotCom() {
        #expect(GitHubRepositoryRef(serverID: "", fullName: "o/r").key == "o/r")
        let id = "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"
        let enterprise = GitHubRepositoryRef(serverID: id, fullName: "o/r")
        #expect(enterprise.key == "\(id):o/r")
        #expect(GitHubRepositoryRef(key: enterprise.key) == enterprise)
        #expect(GitHubRepositoryRef(key: "o/r") == GitHubRepositoryRef(serverID: "", fullName: "o/r"))
        #expect(GitHubRepositoryRef(key: "nope") == nil)
    }

    @Test func gitHubDotComHasNoID() {
        #expect(GitHubServerRef.dotCom.id.isEmpty && GitHubServerRef.dotCom.webHost == "github.com")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/GitHubServerTests`
Expected: FAIL — `cannot find 'GitHubRepositoryRef' in scope`.

- [ ] **Step 3: Implement the types**

Add to `apps/macos/Runnir/IPC/CoreGitHubModels.swift`:

```swift
/// A GitHub server as the Core knows it: github.com (empty id) or an
/// Enterprise server the user added.
struct GitHubServerRef: Hashable, Sendable, Codable {
    /// Empty for github.com; a lowercase UUID for an Enterprise server.
    let id: String
    /// The REST API root; nil for github.com.
    let apiURL: URL?
    /// The web URL's host, lowercased, without port.
    let webHost: String

    static let dotCom = GitHubServerRef(id: "", apiURL: nil, webHost: "github.com")
    var isDotCom: Bool { id.isEmpty }
}

/// A repository on one server.
struct GitHubRepositoryRef: Hashable, Sendable, Codable {
    /// Empty for github.com.
    let serverID: String
    /// "owner/name".
    let fullName: String

    /// What lists and files store: "owner/name" on github.com, as before
    /// Enterprise servers, and "<server id>:owner/name" elsewhere.
    var key: String { serverID.isEmpty ? fullName : serverID + ":" + fullName }

    init(serverID: String, fullName: String) {
        self.serverID = serverID
        self.fullName = fullName
    }

    init?(key: String) {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        let (server, name) = parts.count == 2 ? (parts[0], parts[1]) : ("", key)
        guard GitHubRepositoryName.isValid(name) else { return nil }
        self.init(serverID: server, fullName: name)
    }
}
```

In `CorePullRequest` add `var server: String = ""` as the last stored property (default keeps existing initializers working).

In `CoreService.swift`:
- `CoreRepository`: add `var githubServerID: String? = nil` and `var originHost: String? = nil` under `githubRepository`, with the doc comment "Server id of `githubRepository` (empty is github.com)" and "The origin's host, even when no server matches it".
- `CoreGitHubTarget.named`: `case named(GitHubRepositoryRef)` with comment "A repository with no local clone, on its server".
- Replace the five `CoreServicing` requirements with the signatures in **Interfaces** and add, in the `extension CoreServicing`, github.com shorthands so untouched callers keep compiling:

```swift
    @discardableResult
    func setGitHubCredential(_ token: String?) async throws -> CoreGitHubCredentialKind? {
        try await setGitHubCredential(token, server: .dotCom)
    }
    func checkGitHubToken(_ token: String) async throws -> CoreGitHubTokenCheck {
        try await checkGitHubToken(token, server: .dotCom)
    }
```

In `GRPCCoreService.swift`:

```swift
    static func message(_ server: GitHubServerRef) -> Runnir_Core_V1_GithubServer {
        .with {
            $0.id = server.id
            $0.apiURL = server.apiURL?.absoluteString ?? ""
            $0.webHost = server.webHost
        }
    }

    @discardableResult
    func setGitHubCredential(_ token: String?, server: GitHubServerRef) async throws -> CoreGitHubCredentialKind? {
        if let token {
            let response = try await call {
                try await client.setGitHubCredential(.with { $0.token = token; $0.server = Self.message(server) },
                                                     options: Self.options(Self.callTimeout))
            }
            return Self.map(response.kind)
        } else {
            _ = try await call {
                try await client.clearGitHubCredential(.with { $0.serverID = server.id }, options: Self.options(Self.callTimeout))
            }
            return nil
        }
    }
```

`checkGitHubToken(_:server:)`: `.with { $0.token = token; $0.server = Self.message(server) }`. `listPullRequests(server:closedSince:)`: add `$0.githubServer = server`. `listGitHubRepositories(server:)`: `.with { $0.githubServer = server }`. `githubOrigins`: map to `GitHubRepositoryRef(serverID: $0.githubServerID, fullName: $0.githubRepository)`. In the six `switch target` blocks: `case .named(let ref): $0.githubRepository = ref.fullName; $0.githubServer = ref.serverID`. Where `CoreRepository` is mapped from `Runnir_Core_V1_Repository`, set `githubServerID: message.githubRepository.isEmpty ? nil : message.githubServerID` and `originHost: message.originHost.isEmpty ? nil : message.originHost`.

Update `FakeCore` (CoreHubTests.swift) and the stub in CoreProcessSupervisorTests.swift to the new signatures: record `server` in `credentialCalls` as `[(token: String?, server: String)]` (change `credentialCalls` to `[String?]` derived for github.com to keep existing assertions: `var credentialCalls: [String?] { lock.withLock { _serverCredentialCalls.filter { $0.server.isEmpty }.map(\.token) } }` plus `var serverCredentialCalls`), and make `githubOrigins` return `[String: GitHubRepositoryRef]` (`originsResult` type changes accordingly in tests that set it: wrap values as `GitHubRepositoryRef(serverID: "", fullName: name)`).

Fix the remaining compile errors where `.named(fullName)` or `[String: String]` origins were used (`GitHubRepositoriesView.swift`: `RemoteRepositoryModel.target` → `.repository(GitHubRepositoryRef(serverID: serverID, fullName: fullName))` with a new stored `serverID` defaulting to `""`; `CoreHub.GitHubTarget.repository(GitHubRepositoryRef)`; `DesktopCoordinator.findGitHubOrigins` compares `ref.fullName` for github.com refs only until Task 11).

- [ ] **Step 4: Run the app tests**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests`
Expected: `** TEST SUCCEEDED **`, including `GitHubServerTests`.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Runnir apps/macos/RunnirTests apps/macos/Runnir.xcodeproj
git commit -m "Name the GitHub server in the app's Core calls"
```

### Task 8: Enterprise servers and their tokens

**Files:**
- Create: `apps/macos/Runnir/Core/GitHub/EnterpriseServers.swift`
- Modify: `apps/macos/Runnir/Core/Security/KeychainCredentialStore.swift` (account parameter)
- Test: `apps/macos/RunnirTests/EnterpriseServersTests.swift` (new; add to the test target)

**Interfaces:**
- Consumes: `GitHubServerRef` (Task 7), `CredentialStoring`, `AtomicFile`, `RunnirSupportDirectory`, `DesktopStoreError`.
- Produces:
  - `struct EnterpriseServer: Codable, Identifiable, Hashable, Sendable { let id: UUID; var name: String; let webURL: URL; let apiURL: URL; var login: String = ""; var webHost: String; var ref: GitHubServerRef }` — `login` is the account the token belongs to, as the token check reported when the server was added.
  - `enum EnterpriseServerURL { static func check(_ text: String, allowLoopbackHTTP: Bool) -> Result<URL, Problem> }` with `enum Problem: Error, Equatable { case empty, notAURL, notHTTPS, hasCredentials, hasQuery, isGitHubDotCom }`
  - `struct FileEnterpriseServersStore: Sendable { let directory: URL; func load() throws -> [EnterpriseServer]; func save(_:) throws; static func live() throws -> Self }`
  - `@MainActor @Observable final class EnterpriseServers { private(set) var servers: [EnterpriseServer]; private(set) var problem: String?; init(store: FileEnterpriseServersStore?, credentials: @escaping @Sendable (UUID) -> any CredentialStoring); func add(_ server: EnterpriseServer, token: String) async throws; func remove(_ id: UUID) async; func token(for id: UUID) async -> String?; static let maxServers = 10; static func keychainAccount(_ id: UUID) -> String }`
  - `KeychainCredentialStore(service:account:)`, `KeychainCredentialStore.defaultAccount = "oauth-token"`.

- [ ] **Step 1: Write the failing tests**

`apps/macos/RunnirTests/EnterpriseServersTests.swift`:

```swift
import Foundation
import Testing
@testable import Runnir

actor MemoryCredentialStore: CredentialStoring {
    private(set) var stored: String?
    func token() async throws -> String? { stored }
    func saveToken(_ token: String) async throws { stored = token }
    func removeToken() async throws { stored = nil }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct EnterpriseServersTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("servers-" + UUID().uuidString, isDirectory: true)
    }

    @Test func urlsMustBeHTTPSWithoutCredentials() {
        #expect(try EnterpriseServerURL.check("https://github.company.com", allowLoopbackHTTP: false).get().host() == "github.company.com")
        #expect(try EnterpriseServerURL.check(" https://ghe.example:8443/api/v3 ", allowLoopbackHTTP: false).get().port == 8443)
        #expect(EnterpriseServerURL.check("", allowLoopbackHTTP: false) == .failure(.empty))
        #expect(EnterpriseServerURL.check("github.company.com", allowLoopbackHTTP: false) == .failure(.notAURL))
        #expect(EnterpriseServerURL.check("http://github.company.com", allowLoopbackHTTP: false) == .failure(.notHTTPS))
        #expect(EnterpriseServerURL.check("http://127.0.0.1:3000", allowLoopbackHTTP: false) == .failure(.notHTTPS))
        #expect((try? EnterpriseServerURL.check("http://127.0.0.1:3000", allowLoopbackHTTP: true).get()) != nil)
        #expect(EnterpriseServerURL.check("https://me:pw@github.company.com", allowLoopbackHTTP: false) == .failure(.hasCredentials))
        #expect(EnterpriseServerURL.check("https://github.company.com/?a=1", allowLoopbackHTTP: false) == .failure(.hasQuery))
        #expect(EnterpriseServerURL.check("https://GitHub.com", allowLoopbackHTTP: false) == .failure(.isGitHubDotCom))
    }

    @Test func serversAndTokensAreSavedApart() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let made = LockedStores()
        let servers = EnterpriseServers(store: FileEnterpriseServersStore(directory: directory), credentials: { made.store(for: $0) })
        let server = EnterpriseServer(id: UUID(), name: "Company", webURL: URL(string: "https://github.company.com")!,
                                      apiURL: URL(string: "https://github.company.com/api/v3")!)
        try await servers.add(server, token: "ghp_company")
        #expect(servers.servers.map(\.webHost) == ["github.company.com"])
        #expect(await servers.token(for: server.id) == "ghp_company")
        #expect(server.ref == GitHubServerRef(id: server.id.uuidString.lowercased(), apiURL: server.apiURL, webHost: "github.company.com"))

        // The next launch reads the same list; the file holds no token.
        let data = try Data(contentsOf: directory.appendingPathComponent("github-servers.json"))
        #expect(!String(decoding: data, as: UTF8.self).contains("ghp_"))
        let reread = EnterpriseServers(store: FileEnterpriseServersStore(directory: directory), credentials: { made.store(for: $0) })
        #expect(reread.servers == servers.servers)

        // The same web host twice is refused.
        let twin = EnterpriseServer(id: UUID(), name: "Twin", webURL: URL(string: "https://GITHUB.company.com/")!,
                                    apiURL: URL(string: "https://github.company.com/api/v3")!)
        await #expect(throws: EnterpriseServers.AddError.duplicateHost) { try await servers.add(twin, token: "ghp_x") }

        await servers.remove(server.id)
        #expect(servers.servers.isEmpty)
        #expect(await servers.token(for: server.id) == nil)
    }

    @Test func keychainAccountsDoNotTouchGitHubDotCom() {
        let id = UUID(uuidString: "1B9D6BCD-BBFD-4B2D-9B5D-AB8DFBBD4BED")!
        #expect(EnterpriseServers.keychainAccount(id) == "enterprise:1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed")
        #expect(KeychainCredentialStore.defaultAccount == "oauth-token")
    }
}

/// One memory store per server id, shared across model instances.
final class LockedStores: @unchecked Sendable {
    private let lock = NSLock()
    private var stores: [UUID: MemoryCredentialStore] = [:]
    func store(for id: UUID) -> MemoryCredentialStore {
        lock.withLock {
            if let existing = stores[id] { return existing }
            let made = MemoryCredentialStore()
            stores[id] = made
            return made
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild ... test -only-testing:RunnirTests/EnterpriseServersTests`
Expected: FAIL — `cannot find 'EnterpriseServerURL' in scope`.

- [ ] **Step 3: Implement**

`KeychainCredentialStore.swift`: replace `private let account = "oauth-token"` and the `init` with:

```swift
    private let account: String

    /// github.com's sign-in, as before Enterprise servers.
    static let defaultAccount = "oauth-token"

    init(service: String = KeychainCredentialStore.defaultService, account: String = KeychainCredentialStore.defaultAccount) {
        self.service = service
        self.account = account
    }
```

`apps/macos/Runnir/Core/GitHub/EnterpriseServers.swift`:

```swift
import Foundation
import Observation

/// A GitHub Enterprise server the user added: where it is, never its token.
struct EnterpriseServer: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    let webURL: URL
    let apiURL: URL
    /// The login the token belongs to, from the check when it was added.
    var login: String = ""

    /// The web host, lowercased, without port: how working trees are matched.
    var webHost: String { (webURL.host() ?? "").lowercased() }

    var ref: GitHubServerRef { GitHubServerRef(id: id.uuidString.lowercased(), apiURL: apiURL, webHost: webHost) }

    static let maxNameLength = 60
}

/// The rules for an Enterprise web or API URL.
enum EnterpriseServerURL {
    enum Problem: Error, Equatable {
        case empty, notAURL, notHTTPS, hasCredentials, hasQuery, isGitHubDotCom

        var message: String {
            switch self {
            case .empty: "Enter the URL."
            case .notAURL: "Enter a full URL, such as https://github.company.com."
            case .notHTTPS: "Use an https:// URL."
            case .hasCredentials: "Leave the user name and password out of the URL."
            case .hasQuery: "Leave ?… and #… out of the URL."
            case .isGitHubDotCom: "github.com is already in Runnir; add Enterprise servers here."
            }
        }
    }

    /// Debug builds accept http for a loopback host, for local fakes.
    static var allowsLoopbackHTTP: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static func check(_ text: String, allowLoopbackHTTP: Bool = allowsLoopbackHTTP) -> Result<URL, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty, let url = components.url else { return .failure(.notAURL) }
        guard components.user == nil, components.password == nil else { return .failure(.hasCredentials) }
        guard components.query == nil, components.fragment == nil else { return .failure(.hasQuery) }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
        guard scheme == "https" || (scheme == "http" && allowLoopbackHTTP && loopback) else { return .failure(.notHTTPS) }
        guard host.lowercased() != "github.com", host.lowercased() != "www.github.com" else { return .failure(.isGitHubDotCom) }
        return .success(url)
    }
}

/// github-servers.json in the app's support directory.
struct FileEnterpriseServersStore: Sendable {
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("github-servers.json") }
    static let maxFileBytes = 64 * 1024

    private struct Snapshot: Codable {
        var version = 1
        var servers: [EnterpriseServer]
    }

    static func live() throws -> FileEnterpriseServersStore {
        FileEnterpriseServersStore(directory: try RunnirSupportDirectory.url())
    }

    func load() throws -> [EnterpriseServer] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maxFileBytes else { throw DesktopStoreError.tooLarge }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
        guard snapshot.version == 1, snapshot.servers.count <= EnterpriseServers.maxServers,
              snapshot.servers.allSatisfy(Self.isValid) else { throw DesktopStoreError.invalidState }
        return snapshot.servers
    }

    func save(_ servers: [EnterpriseServer]) throws {
        guard servers.count <= EnterpriseServers.maxServers, servers.allSatisfy(Self.isValid) else { throw DesktopStoreError.invalidState }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try AtomicFile.write(try encoder.encode(Snapshot(servers: servers)), to: fileURL)
    }

    static func isValid(_ server: EnterpriseServer) -> Bool {
        let name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.count <= EnterpriseServer.maxNameLength
            && (try? EnterpriseServerURL.check(server.webURL.absoluteString).get()) != nil
            && (try? EnterpriseServerURL.check(server.apiURL.absoluteString).get()) != nil
    }
}

/// The Enterprise servers and their Keychain tokens. github.com's sign-in
/// stays with GitHubSession.
@MainActor
@Observable
final class EnterpriseServers {
    enum AddError: Error, Equatable { case invalid, duplicateHost, tooMany, notSaved }

    static let maxServers = 10

    private(set) var servers: [EnterpriseServer] = []
    /// Why the list could not be read or saved, for Settings.
    private(set) var problem: String?
    @ObservationIgnored private let store: FileEnterpriseServersStore?
    @ObservationIgnored private let credentials: @Sendable (UUID) -> any CredentialStoring
    /// Called after a server is added or removed, so the Core is told.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    init(store: FileEnterpriseServersStore?, credentials: @escaping @Sendable (UUID) -> any CredentialStoring) {
        self.store = store
        self.credentials = credentials
        do {
            servers = try store?.load() ?? []
        } catch {
            problem = "Runnir could not read its list of Enterprise servers."
        }
    }

    /// The live list, with tokens in Keychain under `enterprise:<id>`.
    static func live() -> EnterpriseServers {
        EnterpriseServers(store: try? FileEnterpriseServersStore.live()) { id in
            KeychainCredentialStore(account: EnterpriseServers.keychainAccount(id))
        }
    }

    nonisolated static func keychainAccount(_ id: UUID) -> String { "enterprise:" + id.uuidString.lowercased() }

    /// Saves the token first, then the server: a listed server always has
    /// its token, and a failed save leaves nothing behind.
    func add(_ server: EnterpriseServer, token: String) async throws {
        guard FileEnterpriseServersStore.isValid(server) else { throw AddError.invalid }
        guard !servers.contains(where: { $0.webHost == server.webHost }) else { throw AddError.duplicateHost }
        guard servers.count < Self.maxServers else { throw AddError.tooMany }
        let tokenStore = credentials(server.id)
        do { try await tokenStore.saveToken(token) } catch { throw AddError.notSaved }
        let candidate = servers + [server]
        do {
            try store?.save(candidate)
        } catch {
            try? await tokenStore.removeToken()
            throw AddError.notSaved
        }
        servers = candidate
        problem = nil
        onChange?()
    }

    /// Removes the server and deletes its token from Keychain.
    func remove(_ id: UUID) async {
        let candidate = servers.filter { $0.id != id }
        do {
            try store?.save(candidate)
        } catch {
            problem = "Runnir could not save its list of Enterprise servers."
            return
        }
        servers = candidate
        try? await credentials(id).removeToken()
        onChange?()
    }

    func token(for id: UUID) async -> String? {
        try? await credentials(id).token()
    }
}
```

Add both new files to the `Runnir` and `RunnirTests` targets in `project.pbxproj` with new `C…` ids, as earlier hand-added files.

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild ... test -only-testing:RunnirTests/EnterpriseServersTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Runnir apps/macos/RunnirTests apps/macos/Runnir.xcodeproj
git commit -m "Keep Enterprise servers and their tokens in the app"
```

### Task 9: The hub hands every server to the Core

**Files:**
- Modify: `apps/macos/Runnir/IPC/CoreHub.swift` (credential push, `pullRequests`, `accountRepositories`, `credentialKind`)
- Modify: `apps/macos/Runnir/App/Desktop/DesktopCoordinator.swift` (`DesktopAppDelegate.init` wiring)
- Test: `apps/macos/RunnirTests/CoreHubTests.swift`

**Interfaces:**
- Consumes: `EnterpriseServers` (Task 8), new `CoreServicing` calls (Task 7).
- Produces:
  - `CoreHub.enterpriseCredentialsProvider: (@MainActor () async -> [(server: GitHubServerRef, token: String)])?`
  - `CoreHub.signedInServers: [GitHubServerRef]` — github.com first when signed in, then Enterprise servers whose token the Core accepted.
  - `CoreHub.credentialKinds: [String: CoreGitHubCredentialKind]` by server id; `credentialKind` stays github.com's (`credentialKinds[""]`).
  - `CoreHub.pullRequests(closedSince:) async -> CorePullRequests` — merged over `signedInServers`, each PR's `server` set; `access` is `.ok` when any server answered, else the first failure.
  - `CoreHub.accountRepositories(server: String) async -> CoreGitHubAccount`
  - `CoreHub.checkGitHubToken(_ token: String, server: GitHubServerRef) async -> CoreGitHubTokenCheck`
  - `DesktopCoordinator.enterpriseServers: EnterpriseServers?` (set by the app delegate), with `var enterpriseServerNames: [String: String]` (server id → name) and `func serverName(for serverID: String?) -> String?` (nil for github.com or an unknown id).

- [ ] **Step 1: Write the failing test**

Add to `CoreHubTests` (or a new suite in the same file):

```swift
    @Test func everySignedInServerIsHandedToTheCore() async {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        let company = GitHubServerRef(id: "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed", apiURL: URL(string: "https://github.company.com/api/v3"),
                                      webHost: "github.company.com")
        hub.githubTokenProvider = { "ghu_dotcom" }
        hub.enterpriseCredentialsProvider = { [(server: company, token: "ghp_company")] }
        hub.startMonitoring()
        provider.ready()
        #expect(await eventually { hub.signedInServers.map(\.id) == ["", company.id] })
        let calls = provider.core.serverCredentialCalls
        #expect(calls.contains { $0.server == "" && $0.token == "ghu_dotcom" })
        #expect(calls.contains { $0.server == company.id && $0.token == "ghp_company" })

        // Pull requests come from both servers, each tagged.
        provider.core.pullRequestsByServer = [
            "": CorePullRequests(access: .ok, open: [pullRequest(1)], closed: [], headsUnreadable: false),
            company.id: CorePullRequests(access: .ok, open: [pullRequest(2)], closed: [], headsUnreadable: false),
        ]
        let merged = await hub.pullRequests(closedSince: Date())
        #expect(Set(merged.open.map(\.server)) == ["", company.id])

        // A removed server is cleared in the Core.
        hub.enterpriseCredentialsProvider = { [] }
        hub.githubCredentialChanged()
        #expect(await eventually { hub.signedInServers.map(\.id) == [""] })
        #expect(provider.core.serverCredentialCalls.contains { $0.server == company.id && $0.token == nil })
    }
```

with a helper in the test file:

```swift
private func pullRequest(_ number: Int64) -> CorePullRequest {
    CorePullRequest(repository: "o/r", number: number, title: "PR", htmlURL: URL(string: "https://example.com/\(number)"), state: "open",
                    draft: false, headBranch: "b", updatedAt: Date(), closedAt: nil, ci: .passed, ciRuns: 1, ciFailed: 0, ciRunning: 0, ciURL: nil)
}
```

and in `FakeCore`: `var pullRequestsByServer: [String: CorePullRequests] = [:]` used by `listPullRequests(server:closedSince:)` (falling back to `pullRequestsResult` when the server has no entry).

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild ... test -only-testing:RunnirTests/CoreHubTests`
Expected: FAIL — `value of type 'CoreHub' has no member 'enterpriseCredentialsProvider'`.

- [ ] **Step 3: Implement**

In `CoreHub.swift` replace `credentialKind` and `pushGitHubCredential`:

```swift
    /// The Enterprise servers to sign in to, with their tokens.
    @ObservationIgnored var enterpriseCredentialsProvider: (@MainActor () async -> [(server: GitHubServerRef, token: String)])?

    /// Kinds of the tokens the Core holds, by server id ("" is github.com).
    private(set) var credentialKinds: [String: CoreGitHubCredentialKind] = [:]
    /// github.com's token kind; nil when signed out of github.com.
    var credentialKind: CoreGitHubCredentialKind? { credentialKinds[""] }
    /// Servers the Core holds a token for: github.com first, then Enterprise.
    private(set) var signedInServers: [GitHubServerRef] = []
    @ObservationIgnored private var pushedEnterpriseIDs: Set<String> = []

    private func pushGitHubCredential() async {
        guard isReady, let service = try? await provider.service() else { return }
        var kinds: [String: CoreGitHubCredentialKind] = [:]
        var servers: [GitHubServerRef] = []
        if let kind = (try? await service.setGitHubCredential(await githubTokenProvider?(), server: .dotCom)) ?? nil {
            kinds[""] = kind
            servers.append(.dotCom)
        }
        let enterprise = await enterpriseCredentialsProvider?() ?? []
        for (server, token) in enterprise {
            if let kind = (try? await service.setGitHubCredential(token, server: server)) ?? nil {
                kinds[server.id] = kind
                servers.append(server)
            }
        }
        // Forget servers removed since the last push.
        let current = Set(enterprise.map(\.server.id))
        for id in pushedEnterpriseIDs.subtracting(current) {
            _ = try? await service.setGitHubCredential(nil, server: GitHubServerRef(id: id, apiURL: nil, webHost: ""))
        }
        pushedEnterpriseIDs = current
        credentialKinds = kinds
        signedInServers = servers
        credentialGeneration += 1
        for workspaceID in sessions.keys { await loadGitHubActivity(workspaceID: workspaceID) }
    }
```

Replace `pullRequests(closedSince:)`:

```swift
    /// Pull requests from every signed-in server, merged newest first.
    func pullRequests(closedSince: Date) async -> CorePullRequests {
        guard isReady, let service = try? await provider.service() else { return .failed(.unavailable) }
        let servers = signedInServers
        guard !servers.isEmpty else { return .failed(.signedOut) }
        var open: [CorePullRequest] = [], closed: [CorePullRequest] = []
        var answered = false, headsUnreadable = false
        var firstFailure: CoreGitHubAccess?
        for server in servers {
            guard let result = try? await service.listPullRequests(server: server.id, closedSince: closedSince) else {
                firstFailure = firstFailure ?? .unavailable
                continue
            }
            if result.access == .tokenRejected {
                if server.isDotCom { await onGitHubTokenRejected?() }
                firstFailure = firstFailure ?? .tokenRejected
                continue
            }
            guard result.access == .ok else { firstFailure = firstFailure ?? result.access; continue }
            answered = true
            headsUnreadable = headsUnreadable || result.headsUnreadable
            open += result.open.map { var pr = $0; pr.server = server.id; return pr }
            closed += result.closed.map { var pr = $0; pr.server = server.id; return pr }
        }
        guard answered else { return .failed(firstFailure ?? .unavailable) }
        let newest: (CorePullRequest, CorePullRequest) -> Bool = { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        return CorePullRequests(access: .ok, open: open.sorted(by: newest), closed: closed.sorted(by: newest), headsUnreadable: headsUnreadable)
    }
```

(If `CorePullRequest.server` is a `let`, make it `var`.) `accountRepositories()` becomes `accountRepositories(server: String = "")` passing `server` to the service and calling `onGitHubTokenRejected` only for `server.isEmpty`. `checkGitHubToken(_:)` gains `server: GitHubServerRef = .dotCom`.

Wire it in `DesktopAppDelegate` (`DesktopCoordinator.swift`): add `let enterpriseServers = EnterpriseServers.live()` as a stored property, and after `hub.githubTokenProvider = ...`:

```swift
        hub.enterpriseCredentialsProvider = { [enterpriseServers] in
            var out: [(server: GitHubServerRef, token: String)] = []
            for server in enterpriseServers.servers {
                if let token = await enterpriseServers.token(for: server.id) { out.append((server.ref, token)) }
            }
            return out
        }
        enterpriseServers.onChange = { [hub] in hub.githubCredentialChanged() }
        desktop.enterpriseServers = enterpriseServers
```

and in `DesktopCoordinator`:

```swift
    /// The Enterprise servers, for their names in lists and notices.
    @ObservationIgnored var enterpriseServers: EnterpriseServers?

    var enterpriseServerNames: [String: String] {
        Dictionary((enterpriseServers?.servers ?? []).map { ($0.ref.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    func serverName(for serverID: String?) -> String? {
        guard let serverID, !serverID.isEmpty else { return nil }
        return enterpriseServerNames[serverID]
    }
```

For a `--ui-testing` run, `EnterpriseServers.live()` already reads from `RunnirSupportDirectory` (the test state folder) and Keychain service `dev.runnir.github.ui-testing`.

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild ... test -only-testing:RunnirTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Runnir apps/macos/RunnirTests
git commit -m "Hand every signed-in GitHub server to the Core"
```

### Task 10: Settings › GitHub lists Enterprise servers

**Files:**
- Create: `apps/macos/Runnir/Features/Settings/EnterpriseServersSettings.swift`
- Modify: `apps/macos/Runnir/Features/Settings/SettingsView.swift`, `apps/macos/Runnir/App/RunnirApp.swift` (pass `enterpriseServers`)
- Modify: `apps/macos/Runnir/Features/Authentication/GitHubConnectView.swift` (`GitHubTokenAdvice` per web URL)
- Modify: `apps/macos/Runnir/Features/Desktop/GitHubAccessHelp.swift` (`tokenSettingsURL(_:webURL:)`)
- Test: `apps/macos/RunnirTests/EnterpriseServersTests.swift` (form model tests)

**Interfaces:**
- Consumes: `EnterpriseServers`, `EnterpriseServerURL` (Task 8); `CoreHub.checkGitHubToken(_:server:)` (Task 9); `GitHubTokenCheckView` (existing).
- Produces:
  - `@MainActor @Observable final class EnterpriseServerForm { var name, webURL, apiURL, token: String; private(set) var check: CoreGitHubTokenCheck?; private(set) var isChecking: Bool; var problems: [String]; var draft: EnterpriseServer?; func runCheck(hub: CoreHub) async; var canAdd: Bool }`
  - `GitHubTokenAdvice.newFineGrainedURL(webURL: URL) -> URL`, `newClassicURL(webURL:)`, `fineGrainedSettingsURL(webURL:)`, `classicSettingsURL(webURL:)`; the existing static `URL` constants become `...(webURL: GitHubTokenAdvice.dotComWebURL)` calls.
  - `struct EnterpriseServersSection: View` (Settings) and `struct AddEnterpriseServerSheet: View`.

- [ ] **Step 1: Write the failing tests**

Add to `EnterpriseServersTests`:

```swift
    @Test func tokenLinksUseTheServersWebURL() {
        let web = URL(string: "https://github.company.com")!
        #expect(GitHubTokenAdvice.newClassicURL(webURL: web).absoluteString == "https://github.company.com/settings/tokens/new?scopes=repo&description=Runnir")
        #expect(GitHubTokenAdvice.newFineGrainedURL(webURL: web).absoluteString == "https://github.company.com/settings/personal-access-tokens/new")
        #expect(GitHubTokenAdvice.newClassicURL(webURL: GitHubTokenAdvice.dotComWebURL).host() == "github.com")
    }

    @Test func theFormNeedsValidURLsAndAnAcceptedToken() async {
        let (hub, provider) = await readyHub()
        let form = EnterpriseServerForm(existing: [])
        form.name = "Company"
        form.webURL = "http://github.company.com"
        form.apiURL = "https://github.company.com/api/v3"
        form.token = "ghp_company"
        #expect(form.problems == ["Web URL: Use an https:// URL."])
        #expect(!form.canAdd)

        form.webURL = "https://github.company.com"
        provider.core.tokenCheckResult = CoreGitHubTokenCheck(access: .ok, kind: .classic, login: "me", scopes: ["repo"], expiresAt: nil,
                                                              repositories: 3, checks: [], suitable: true)
        await form.runCheck(hub: hub)
        #expect(form.canAdd && form.draft?.webHost == "github.company.com" && form.draft?.login == "me")
        #expect(provider.core.tokenCheckServers.last?.webHost == "github.company.com")

        form.token = "ghp_other"
        #expect(!form.canAdd, "a changed token is checked again")
    }
```

(`readyHub()` is the helper from `PullRequestsTests`; move it to `TestSupport.swift` so both suites share it. Add `tokenCheckResult` and `tokenCheckServers: [GitHubServerRef]` to `FakeCore.checkGitHubToken(_:server:)`.)

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild ... test -only-testing:RunnirTests/EnterpriseServersTests`
Expected: FAIL — `cannot find 'EnterpriseServerForm' in scope`.

- [ ] **Step 3: Implement the advice URLs**

In `GitHubConnectView.swift` replace the four `static let` URLs of `GitHubTokenAdvice` with:

```swift
    static let dotComWebURL = URL(string: "https://github.com")!

    static func newFineGrainedURL(webURL: URL) -> URL { webURL.appending(path: "settings/personal-access-tokens/new") }
    static func newClassicURL(webURL: URL) -> URL {
        var components = URLComponents(url: webURL.appending(path: "settings/tokens/new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "scopes", value: "repo"), URLQueryItem(name: "description", value: "Runnir")]
        return components.url!
    }
    static func fineGrainedSettingsURL(webURL: URL) -> URL { webURL.appending(path: "settings/personal-access-tokens") }
    static func classicSettingsURL(webURL: URL) -> URL { webURL.appending(path: "settings/tokens") }
```

and update their callers (`grep -rn "newFineGrainedURL\|newClassicURL\|fineGrainedSettingsURL\|classicSettingsURL" apps/macos/Runnir`) to pass `GitHubTokenAdvice.dotComWebURL`. Give `GitHubTokenAdvice`'s view an optional `webURL: URL = GitHubTokenAdvice.dotComWebURL` and `enterprise: Bool = false`; when `enterprise` is true, append to the fine-grained text: " Fine-grained tokens need GitHub Enterprise Server 3.10 or later; use a classic token on older servers." In `GitHubAccessHelp.tokenSettingsURL(_:)` add `webURL: URL = GitHubTokenAdvice.dotComWebURL` and pass it through.

- [ ] **Step 4: Implement the form and views**

`apps/macos/Runnir/Features/Settings/EnterpriseServersSettings.swift`:

```swift
import SwiftUI

/// The add-server form: URLs are checked as typed; the token is checked
/// against the server's API before Add is offered.
@MainActor
@Observable
final class EnterpriseServerForm {
    var name = ""
    var webURL = ""
    var apiURL = ""
    var token = "" { didSet { if token != checkedToken { check = nil } } }
    private(set) var check: CoreGitHubTokenCheck?
    private(set) var isChecking = false
    @ObservationIgnored private var checkedToken: String?
    @ObservationIgnored private let existing: [EnterpriseServer]
    @ObservationIgnored private let id = UUID()

    init(existing: [EnterpriseServer]) {
        self.existing = existing
    }

    var problems: [String] {
        var out: [String] = []
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || trimmedName.count > EnterpriseServer.maxNameLength {
            out.append("Name: use 1 to \(EnterpriseServer.maxNameLength) characters.")
        }
        if case .failure(let problem) = EnterpriseServerURL.check(webURL) { out.append("Web URL: " + problem.message) }
        if case .failure(let problem) = EnterpriseServerURL.check(apiURL) { out.append("API URL: " + problem.message) }
        if let draft, existing.contains(where: { $0.webHost == draft.webHost }) {
            out.append("Web URL: \(draft.webHost) is already in the list.")
        }
        return out
    }

    /// The server the fields describe, when both URLs pass.
    var draft: EnterpriseServer? {
        guard case .success(let web) = EnterpriseServerURL.check(webURL),
              case .success(let api) = EnterpriseServerURL.check(apiURL) else { return nil }
        return EnterpriseServer(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), webURL: web, apiURL: api,
                                login: check?.login ?? "")
    }

    var canAdd: Bool {
        problems.isEmpty && check?.access == .ok && checkedToken == token && !isChecking
    }

    func runCheck(hub: CoreHub) async {
        guard let draft, problems.isEmpty, !token.isEmpty else { return }
        isChecking = true
        defer { isChecking = false }
        let tokenToCheck = token
        let result = await hub.checkGitHubToken(tokenToCheck, server: draft.ref)
        guard tokenToCheck == token else { return }
        checkedToken = tokenToCheck
        check = result
    }
}

/// Settings › GitHub: the Enterprise servers under github.com.
struct EnterpriseServersSection: View {
    let servers: EnterpriseServers
    let hub: CoreHub?
    @State private var adding = false
    @State private var removing: EnterpriseServer?

    var body: some View {
        Section("GitHub Enterprise") {
            ForEach(servers.servers) { server in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name)
                        Text(server.login.isEmpty ? server.webHost : "\(server.login) on \(server.webHost)")
                            .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                    }
                    Spacer()
                    Button("Remove...") { removing = server }
                }
            }
            if let problem = servers.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(RunnirTheme.warning)
            }
            HStack {
                Button("Add Enterprise Server...") { adding = true }
                    .disabled(hub == nil || servers.servers.count >= EnterpriseServers.maxServers)
                Spacer()
            }
            Text("Runnir signs in to an Enterprise server with a personal access token, kept in your Keychain. Working trees whose origin is on that server use it.")
                .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
        }
        .sheet(isPresented: $adding) {
            if let hub { AddEnterpriseServerSheet(servers: servers, hub: hub) }
        }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let removing { Task { await servers.remove(removing.id) } }
            }
        } message: {
            Text("Runnir forgets this server and deletes its token from your Keychain. The token stays valid on the server until you revoke it.")
        }
    }
}

struct AddEnterpriseServerSheet: View {
    let servers: EnterpriseServers
    let hub: CoreHub
    @State private var form: EnterpriseServerForm
    @State private var saveProblem: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(servers: EnterpriseServers, hub: CoreHub) {
        self.servers = servers
        self.hub = hub
        _form = State(initialValue: EnterpriseServerForm(existing: servers.servers))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Enterprise Server").font(.headline)
            Form {
                TextField("Name", text: $form.name, prompt: Text("Company GitHub"))
                TextField("Web URL", text: $form.webURL, prompt: Text("https://github.company.com"))
                TextField("API URL", text: $form.apiURL, prompt: Text("https://github.company.com/api/v3"))
                SecureField("Token", text: $form.token, prompt: Text("github_pat_… or ghp_…"))
            }
            ForEach(form.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(RunnirTheme.warning)
            }
            if let web = form.draft?.webURL {
                GitHubTokenAdvice(webURL: web, enterprise: true)
            }
            if let check = form.check {
                GitHubTokenCheckView(check: check)
            }
            if let saveProblem {
                Label(saveProblem, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(RunnirTheme.warning)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Check Token") { Task { await form.runCheck(hub: hub) } }
                    .disabled(!form.problems.isEmpty || form.token.isEmpty || form.isChecking)
                Button("Add") { Task { await add() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!form.canAdd)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func add() async {
        guard let draft = form.draft else { return }
        do {
            try await servers.add(draft, token: form.token)
            dismiss()
        } catch EnterpriseServers.AddError.duplicateHost {
            saveProblem = "\(draft.webHost) is already in the list."
        } catch {
            saveProblem = "Runnir could not save the server or its token in your Keychain."
        }
    }
}
```

(`GitHubTokenCheckView(check:)` and `GitHubTokenAdvice(webURL:enterprise:)` must match the initializers in `GitHubConnectView.swift`; if `GitHubTokenCheckView` takes more arguments there, pass the same ones the token form passes.)

`SettingsView`: add `var enterpriseServers: EnterpriseServers?` and, right after the GitHub section, `if let enterpriseServers { EnterpriseServersSection(servers: enterpriseServers, hub: core) }`. `RunnirApp.swift`: pass `enterpriseServers: delegate.enterpriseServers`.

- [ ] **Step 5: Run to verify it passes**

Run: `xcodebuild ... test -only-testing:RunnirTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Runnir apps/macos/RunnirTests apps/macos/Runnir.xcodeproj
git commit -m "Add and remove Enterprise servers in Settings"
```

### Task 11: The GitHub tab shows every account

**Files:**
- Modify: `apps/macos/Runnir/Features/Desktop/GitHubRepositoriesView.swift` (`GitHubRepositoriesModel`, `RepositoryFavorites`, list view, `RemoteRepositoryModel`)
- Modify: `apps/macos/Runnir/App/Desktop/DesktopCoordinator.swift` (`findGitHubOrigins`, `registeredWorkspace(for:)`)
- Test: `apps/macos/RunnirTests/GitHubRepositoriesTests.swift`

**Interfaces:**
- Consumes: `CoreHub.signedInServers`, `accountRepositories(server:)` (Task 9), `GitHubRepositoryRef` (Task 7), `EnterpriseServers` names.
- Produces:
  - `GitHubRepositoriesModel.accounts: [AccountListing]` where `struct AccountListing: Identifiable { let server: GitHubServerRef; let title: String; var access: CoreGitHubAccess?; var repositories: [CoreGitHubAccountRepository]; var installations: [CoreGitHubInstallation]; var truncated: Bool; var credentialKind: CoreGitHubCredentialKind; var id: String { server.id } }`
  - `GitHubRepositoriesModel.load(hub:titles:)` with `titles: [String: String]` (server id → name; github.com is "GitHub.com").
  - `GitHubRepositoriesModel.selected: GitHubRepositoryRef?`
  - `RepositoryFavorites` stores `GitHubRepositoryRef.key` strings; `isFavorite(_ ref: GitHubRepositoryRef)`, `toggle(_ ref:)`.
  - `DesktopCoordinator.registeredWorkspace(for ref: GitHubRepositoryRef) -> WorkspaceRecord?`

- [ ] **Step 1: Write the failing test**

Add to `GitHubRepositoriesTests`:

```swift
    @Test func repositoriesAreListedPerAccount() async {
        let (hub, provider) = await readyHub()
        let company = GitHubServerRef(id: "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed", apiURL: URL(string: "https://github.company.com/api/v3"),
                                      webHost: "github.company.com")
        hub.githubTokenProvider = { "ghu_x" }
        hub.enterpriseCredentialsProvider = { [(server: company, token: "ghp_y")] }
        hub.githubCredentialChanged()
        _ = await eventually { hub.signedInServers.count == 2 }
        provider.core.accountsByServer = [
            "": CoreGitHubAccount(access: .ok, installations: [], repositories: [repository("o/r")], truncated: false),
            company.id: CoreGitHubAccount(access: .ok, installations: [], repositories: [repository("o/r"), repository("org/app")], truncated: false),
        ]
        let model = GitHubRepositoriesModel()
        await model.load(hub: hub, titles: [company.id: "Company"])
        #expect(model.accounts.map(\.title) == ["GitHub.com", "Company"])
        #expect(model.accounts.map { $0.repositories.count } == [1, 2])
    }

    @Test func favoritesKeepGitHubDotComNamesAndAddServerKeys() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fav-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let favorites = RepositoryFavorites(store: FileRepositoryFavoritesStore(directory: folder))
        let dotcom = GitHubRepositoryRef(serverID: "", fullName: "o/r")
        let company = GitHubRepositoryRef(serverID: "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed", fullName: "o/r")
        #expect(favorites.toggle(dotcom) && favorites.toggle(company))
        #expect(favorites.names == ["o/r", "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed:o/r"])
        #expect(favorites.isFavorite(company) && favorites.isFavorite(dotcom))
    }
```

(`FakeCore` gains `var accountsByServer: [String: CoreGitHubAccount] = [:]`, used by `listGitHubRepositories(server:)` before falling back to `accountResult`.)

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild ... test -only-testing:RunnirTests/GitHubRepositoriesTests`
Expected: FAIL — `value of type 'GitHubRepositoriesModel' has no member 'accounts'`.

- [ ] **Step 3: Implement**

- `FileRepositoryFavoritesStore.isValid(_:)`: accept `GitHubRepositoryRef(key:) != nil` for each name instead of `GitHubRepositoryName.isValid`.
- `RepositoryFavorites`: `isFavorite(_ ref: GitHubRepositoryRef) -> Bool { names.contains(ref.key) }`; `toggle(_ ref: GitHubRepositoryRef) -> Bool` operating on `ref.key` (keep the existing body, replacing `fullName` with `ref.key`).
- `GitHubRepositoriesModel`: replace the single-account properties (`access`, `installations`, `repositories`, `truncated`, `credentialKind`) with `private(set) var accounts: [AccountListing] = []`, and `load(hub:titles:)`:

```swift
    func load(hub: CoreHub, titles: [String: String]) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        var loaded: [AccountListing] = []
        for server in hub.signedInServers {
            let result = await hub.accountRepositories(server: server.id)
            loaded.append(AccountListing(server: server, title: server.isDotCom ? "GitHub.com" : (titles[server.id] ?? server.webHost),
                                         access: result.access, repositories: result.repositories, installations: result.installations,
                                         truncated: result.truncated, credentialKind: result.credentialKind))
        }
        accounts = loaded
        loadedAt = Date()
    }
```

  `visible(favorites:)` returns `[(listing: AccountListing, repositories: [CoreGitHubAccountRepository])]` filtered per account with the existing search/owner/starred rules (favorites by `GitHubRepositoryRef(serverID: listing.server.id, fullName: repo.fullName)`); `selected` becomes `GitHubRepositoryRef?` and the detail view builds `RemoteRepositoryModel(ref:)`.
- The list view renders one section per account, so one failing server does not hide the others:

```swift
            ForEach(model.visible(favorites: favorites), id: \.listing.id) { group in
                Section {
                    if let access = group.listing.access, let help = Self.listHelp(access, credential: group.listing.credentialKind) {
                        GitHubAccessNotice(help: help, style: .banner, github: desktop.github) { Task { await model.load(hub: hub, titles: titles) } }
                    }
                    ForEach(group.repositories) { repository in
                        let ref = GitHubRepositoryRef(serverID: group.listing.server.id, fullName: repository.fullName)
                        row(repository, ref: ref)   // the existing row view, given the ref for favorites and selection
                    }
                } header: {
                    if model.accounts.count > 1 { SectionLabel(title: group.listing.title.uppercased()) }
                }
            }
```

  (`titles` is `desktop.enterpriseServerNames`, a new `[String: String]` computed property on `DesktopCoordinator` built from `EnterpriseServers.servers` as `[server.ref.id: server.name]`.)
- `DesktopCoordinator.findGitHubOrigins()` stores `[String: GitHubRepositoryRef]` per workspace, and `registeredWorkspace(for ref:)` compares refs (server and name) instead of names.

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild ... test -only-testing:RunnirTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Runnir apps/macos/RunnirTests
git commit -m "Show repositories of every GitHub account in the GitHub tab"
```

### Task 12: Server names in workspaces, notices and pull requests

**Files:**
- Modify: `apps/macos/Runnir/IPC/CoreHub.swift` (session server fields)
- Modify: `apps/macos/Runnir/Features/Desktop/GitHubAccessHelp.swift` (`forAccess(..., serverName:)`)
- Modify: `apps/macos/Runnir/Features/Desktop/RunInspectorView.swift`, `OverviewViews.swift`, `DesktopViews.swift` (no-remote text with the host)
- Modify: `apps/macos/Runnir/Features/Desktop/PullRequestsViews.swift` (subtitle host)
- Test: `apps/macos/RunnirTests/GitHubAccessHelpTests.swift`, `apps/macos/RunnirTests/PullRequestsTests.swift`

**Interfaces:**
- Consumes: `CoreRepository.githubServerID/originHost` (Task 7), `EnterpriseServers` (Task 8).
- Produces:
  - `WorkspaceSession.githubServerID: String?`, `WorkspaceSession.originHost: String?`.
  - `GitHubAccessHelp.Fix.openSettings` (button "Open Settings..."), handled in `GitHubAccessNotice.perform` and `GitHubAccessAlert.perform` with `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`.
  - `GitHubAccessHelp.forAccess(_ access:, repository:, purpose:, credential:, serverName: String? = nil)` — `serverName` nil means github.com; for an Enterprise server, signed-out and token-rejected give title "Sign in to \(serverName)" and `fix: .openSettings` instead of `.connect`/`.signInAgain`.
  - `GitHubAccessHelp.noRemote(originHost: String?) -> GitHubAccessHelp` — "This working tree's origin is on \(host), which is not a GitHub server in Runnir. Add it in Settings › GitHub Enterprise." when the host is set; the existing text otherwise.
  - `PullRequestRow(pullRequest:, serverHost: String?, dismiss:)` — subtitle starts with `serverHost` when non-nil.

- [ ] **Step 1: Write the failing tests**

```swift
    @Test func enterpriseNoticesNameTheServer() {
        let help = GitHubAccessHelp.forAccess(.signedOut, repository: "org/app", purpose: .read, credential: nil, serverName: "Company")
        #expect(help?.title.contains("Company") == true)
        #expect(help?.fix == .openSettings)
        let unknown = GitHubAccessHelp.noRemote(originHost: "gitlab.com")
        #expect(unknown.message.contains("gitlab.com") && unknown.message.contains("Settings"))
    }
```

and in `PullRequestsTests`:

```swift
    @Test func theServerShowsWhenMoreThanOneAccountIsSignedIn() {
        var pr = CorePullRequest(repository: "org/app", number: 3, title: "T", htmlURL: nil, state: "open", draft: false, headBranch: "b",
                                 updatedAt: nil, closedAt: nil, ci: .passed, ciRuns: 1, ciFailed: 0, ciRunning: 0, ciURL: nil)
        pr.server = "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"
        #expect(PullRequestRow.subtitle(pr, serverHost: "github.company.com").hasPrefix("github.company.com · org/app #3"))
        #expect(PullRequestRow.subtitle(pr, serverHost: nil).hasPrefix("org/app #3"))
    }
```

(`GitHubAccessHelp` has one `fix: Fix`; its cases today are `connect`, `signInAgain`, `giveAccess(URL)`, `reviewPermissions(URL)`, `editToken(URL)`, `askForWriteAccess`, `retry`, `none`. Add `case openSettings` with `buttonTitle` "Open Settings...".)

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild ... test -only-testing:RunnirTests`
Expected: FAIL — extra argument `serverName`, no member `noRemote`, no member `subtitle`.

- [ ] **Step 3: Implement**

- `WorkspaceSession` gets `githubServerID`/`originHost`, set where `githubRepository` is set from `CoreRepository`; `loadGitHubActivity` unchanged (the Core routes by origin).
- `GitHubAccessHelp.forAccess`: add `serverName: String? = nil`; when non-nil and access is `.signedOut` or `.tokenRejected`, return `GitHubAccessHelp(title: "Sign in to \(serverName)", message: "Add a token for \(serverName) in Settings › GitHub Enterprise.", fix: .openSettings)`. Other cases keep their text, with "GitHub" replaced by `serverName ?? "GitHub"` in titles.
- Add `static func noRemote(originHost: String?) -> GitHubAccessHelp` and use it where `.noRemote` text was built (`GitHubAccessHelp.swift:83`, `RunInspectorView.swift:161,174`).
- Callers that show workspace notices pass `serverName: desktop.serverName(for: session.githubServerID)`, a new `DesktopCoordinator` helper returning nil for github.com and the `EnterpriseServers` name otherwise.
- `PullRequestRow`: extract the subtitle into `static func subtitle(_ pr: CorePullRequest, serverHost: String?) -> String`, prefixing `"\(serverHost) · "`; `PullRequestsList` passes `serverHost` only when `hub.signedInServers.count > 1` (github.com shows "github.com").

- [ ] **Step 4: Run to verify they pass**

Run: `xcodebuild ... test -only-testing:RunnirTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Runnir apps/macos/RunnirTests
git commit -m "Name the GitHub server in workspaces, notices and pull requests"
```

### Task 13: Docs and full verification

**Files:**
- Modify: `docs/architecture/grpc-api.md` (server fields), `docs/security/github-authentication.md` (new "Enterprise servers" section), `README.md` (feature list), `docs/architecture/github-enterprise.md` (Status line)

- [ ] **Step 1: Write the docs**

`docs/security/github-authentication.md`, new section at the end:

```markdown
## Enterprise Servers

Enterprise servers sign in with a personal access token only; Runnir Desktop is registered on github.com. Each server's token is in Keychain as `dev.runnir.github` / `enterprise:<server id>`, and the server list (name, web URL, API URL, never a token) in `github-servers.json`. The Core sends a token only to its server's API origin and refuses redirects to another origin. URLs must be https; http is accepted only for a loopback host (the Core always, the app in Debug builds) so tests and local fakes can run. Removing a server deletes its token from Keychain; the token stays valid on the server until the user revokes it. See [GitHub Enterprise Servers](../architecture/github-enterprise.md).
```

`docs/architecture/grpc-api.md`: under the GitHub RPCs, describe `GithubServer`, `github_server` on named-repository requests, `ClearGitHubCredentialRequest.server_id`, and `Repository.github_server_id/origin_host`, in the style of the surrounding entries.

`README.md`: add "GitHub Enterprise servers next to github.com, signed in with a personal access token (not verified against a real Enterprise server yet)" to the feature list.

`docs/architecture/github-enterprise.md`: change the Status line to "Status: implemented; verified with unit tests and a local fake API, not against a real Enterprise server." and change the "Responses that list repositories or pull requests ..." bullet to: "`ListGitHubRepositories` and `ListPullRequests` take `github_server`; the app asks each signed-in server and merges the answers, so one unreachable server does not hide the others."

- [ ] **Step 2: Run everything**

Run: `cd core && go test -race ./... && go vet ./... && go build ./...`
Expected: PASS.

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build && xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests`
Expected: `** BUILD SUCCEEDED **`, `** TEST SUCCEEDED **`.

- [ ] **Step 3: Live check (Debug test copy, never the user's data)**

1. Build the test copy: `xcodebuild ... -derivedDataPath <scratch>/dd-alert PRODUCT_BUNDLE_IDENTIFIER=com.dileight.runnir.alertcheck build`; run it with `RUNNIR_UI_TEST_STATE_DIRECTORY=<scratch>/e2e-files/state <app>/Contents/MacOS/Runnir --ui-testing` (separate Keychain service and state folder).
2. Start a local fake API on `http://127.0.0.1:<port>` answering `/user`, `/user/repos`, `/repos/org/app/actions/runs`, `/search/issues` (a small Go program in the scratch folder using `net/http`).
3. Settings › GitHub Enterprise › Add: web `https://ghe.test`, API `http://127.0.0.1:<port>`, a made-up `ghp_` test token. Expect: Check Token shows the fake login; Add stores it; the GitHub tab shows a "Fake" section; a fixture working tree with origin `git@ghe.test:org/app.git` shows runs from the fake; the menu bar lists the fake's pull request with the host.
4. Remove the server; expect it gone from the tab, and the Keychain item gone (`security find-generic-password -s dev.runnir.github.ui-testing -a enterprise:<id>` returns "could not be found").
5. github.com regression in the live app: the GitHub tab, a workspace's runs, the menu bar list.

- [ ] **Step 4: Commit**

```bash
git add docs README.md
git commit -m "Document GitHub Enterprise servers"
```
