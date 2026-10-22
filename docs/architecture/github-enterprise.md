# GitHub Enterprise Servers

Status: implemented; verified with unit tests, not against a real Enterprise server.

Runnir talks to github.com today. Teams on GitHub Enterprise Server, or on GitHub Enterprise Cloud with data residency (`*.ghe.com`), need Runnir to reach their own server too, at the same time as github.com.

## Decisions

- **Several servers at once.** github.com and any number of Enterprise servers are signed in side by side. A repository belongs to the server whose host its origin names.
- **Both URLs are entered by hand.** An Enterprise server is a web URL (`https://github.company.com`) and an API URL (`https://github.company.com/api/v3`, or `https://api.company.ghe.com`). Runnir does not derive one from the other; the form shows examples only.
- **Enterprise sign-in is by personal access token only.** Runnir Desktop is registered on github.com; Device Flow on another server would need an app registered there, which is out of scope. github.com keeps Device Flow and its token option.
- **Routing by origin host in the Core** (ADR 0004 keeps one Core process). The app owns the server list and the tokens; the Core gets them and picks the server for each request.

## Accounts

- github.com is an optional account, as today. Its Keychain item stays `dev.runnir.github` / `oauth-token`, so existing sign-ins keep working.
- Each Enterprise server is `{id, name, webURL, apiURL, login}` in `github-servers.json` in the app's support directory, with its token in Keychain as `dev.runnir.github` / `enterprise:<id>`. `id` is a random UUID, never derived from the URL.
- Removing a server signs it out and deletes its Keychain item. Changing a server's URLs is not offered; remove and add it again, so a token is never sent to a URL it was not checked against.
- Limits: at most 10 Enterprise servers; names up to 60 characters; the file up to 64 KiB.

## URL rules

- `https` only; no user name, password, query or fragment; a host is required; a port is allowed. `http` is accepted only for a loopback host — by the Core always, by the app only in Debug builds — so tests and local fakes can run.
- The web URL's host must not be `github.com`, and must differ from every other server's web host.
- The API URL may be on another host (as on `ghe.com`). The token is sent only to that API URL's origin.
- Certificates are checked against the macOS trust store, so a company CA installed in Keychain works. There is no option to skip certificate checks.

## Settings › GitHub

- A list of accounts: github.com (connected or "Connect GitHub..."), then each Enterprise server with its name, host, signed-in login and Remove.
- "Add Enterprise Server..." opens a sheet: name, web URL, API URL, token. Check Token runs the existing token check against that API URL and shows the same verdict (kind, missing permissions, expiry, SSO). Add stores the server and token only after a check that GitHub accepted.
- Token advice links ("New Fine-Grained Token...", "New Classic Token...", token settings) use the server's web URL. Fine-grained tokens need GitHub Enterprise Server 3.10 or later; the advice says so for Enterprise servers.

## Core contract

- `SetGitHubCredential` and `CheckGitHubToken` gain `GithubServer server` (`id`, `api_url`, `web_host`). An empty `id` is github.com, with `api.github.com` and `github.com`. `ClearGitHubCredential` gains `server_id`.
- The Core keeps one credential and client per server id. A credential set for one server is never used for another.
- Every request that names a repository by `github_repository` gains `github_server` (server id; empty is github.com).
- `GetGitHubOrigins` and the scanner recognize any host the Core holds a server for, and return the server id with "owner/name". A working tree whose origin host matches no server keeps the existing "no origin on GitHub" state, naming the host.
- `ListGitHubRepositories` and `ListPullRequests` take `github_server`; the app asks each signed-in server and merges the answers, so one unreachable server does not hide the others.
- Errors and access states (`signed out`, `token rejected`, `permission missing`, ...) name the server they came from.

## Where it shows

- GitHub tab: one list of every account's repositories — github.com first, then each Enterprise server — with the server's host on Enterprise rows; search, the owner filter and stars cover them all. "By Server" groups the list into a section per server (kept between launches). A server that cannot be read keeps its last list and shows its own notice, so it does not hide the others. Stars and registered clones match a repository by server id and "owner/name" together, so `org/app` on two servers stays two repositories.
- Workspaces: workflows, runs, dispatch and logs go to the server of the origin. Access notices name the server ("Sign in to github.company.com").
- Menu bar and Pull Requests window: pull requests from every account; the server host shows in the subtitle when more than one account is signed in.
- Local runs: for a working tree on an Enterprise server, act gets `--github-instance <web host>`, so `uses:` actions are fetched from that server. The token is not passed to act.

## Security

- The Go client refuses redirects to another origin (`CheckRedirect`), so a token never leaves its API origin.
- Server URLs and logins are not secrets but stay local: no telemetry, no logs with tokens or authorization headers.
- Tokens stay only in Keychain and in Core memory, as today.

## Testing

- Go: origin parsing for any configured host (scp and URL forms, ports, case); routing of each RPC to the right server with `httptest` servers; no request to one server carries another's token; a redirect to another origin is refused; one failing server still lists the others.
- Swift: URL validation; the server file (limits, unknown version, damage); Keychain account names through a fake store; the add-server sheet's states; access notices naming the server.
- Live: github.com plus a local fake Enterprise API on a loopback http URL in a Debug test copy, if no real Enterprise server is available. Claims about Enterprise support stay "implemented, not verified against a real server" until one is used.

## Out of scope

- Device Flow or OAuth apps on Enterprise servers.
- Editing a server's URLs in place, proxies, client certificates, skipping certificate checks.
- GitHub Enterprise Cloud on github.com needs nothing new: it is github.com with SAML SSO, which the token check already reports.

## Delivery

Branch `dilbarov/github-enterprise`, started from `dilbarov/menu-bar-pull-requests`. Its pull request opens after #31 and the menu bar pull request merge, keeping one open pull request at a time.
