# GitHub Authentication

Runnir should use a GitHub-supported native app authentication flow.

For MVP v0.1, the target is supported OAuth Device Flow with a configured client identifier and no manual PAT requirement. This is a requirement, not an implemented login path; see [FR-01](../product/specification.md#fr-01-github-authentication).

## Requirements

- Do not embed a GitHub client secret.
- Open browser-based authorization in the system browser, or use GitHub device authorization when appropriate.
- Store tokens only in macOS Keychain.
- Support logout by deleting Keychain credentials.
- Distinguish local logout from remote revocation. Provide a supported user-controlled authorization revocation path when remote revocation cannot be performed without a client secret.
- Request minimal scopes for the enabled feature set.
- Do not log tokens or authorization responses.

## Registered GitHub App

Registered 2026-10-18 in the `dil-eight` organization: **Runnir Desktop** (`runnir-desktop`, client ID `Iv23liopD8rc8O16F7gK`, public link https://github.com/apps/runnir-desktop). The values live in `GitHubAppConfiguration.runnirDesktop`.

- Device Flow enabled; no callback URL, no OAuth during installation, webhook inactive, no event subscriptions.
- Installable on any account. User tokens reach only repositories where the app is installed, so the login flow must lead users to `https://github.com/apps/runnir-desktop/installations/new`.
- Repository permissions: Actions read and write (runs, logs, dispatch, cancel, rerun, billable timing per run), Contents read-only (branches, tags, commits, workflow files at any ref), Metadata read-only. No organization or account permissions.
- The Core lists these in `github.RequiredPermissions`. When the app asks for more, existing installations keep the old ones until an owner accepts the update on GitHub. Runnir compares each installation's granted permissions with the list and says which ones wait for an owner, instead of offering to connect again. The user's own rights are separate: starting, cancelling and re-running need write access to the repository, and Runnir says so instead of offering a fix it cannot make.
- User token expiry is turned off, because refreshing an expiring token needs a client secret, which a desktop app must not ship. Tokens stay in Keychain and can be revoked by the user in GitHub settings or with "Revoke all user tokens". Confirm this choice against GitHub's current documentation when the login flow is built.
- GitHub requires at least one private key before the app can be installed. The key is kept by the owner outside the repository; the desktop app never uses it. No client secret was generated.

## Personal Access Tokens

Device Flow stays the main way in. A personal access token is the alternative for people who cannot install the app on an organization, or who prefer a token.
- **Before use:** the Core checks the token without holding it (`CheckGitHubToken`). The connection sheet shows each check, and advice for a token that fits:
  - fine-grained (recommended): Actions — Read and write, Contents — Read-only, for the repositories used; GitHub adds Metadata;
  - classic: the `repo` scope, authorized for single sign-on where an organization asks.
- **Storage:** the token goes only to the Keychain, as the app's sign-in does, and the Core holds it in memory.
- **Repositories:** with a token, they come from `/user/repos`, and refusals point to the token's settings instead of the app's installations.

## Current Status

Implemented in Swift (the token never leaves the app process):
- `GitHubDeviceFlowClient` requests a device code with the client id only and polls `login/oauth/access_token`, mapping pending, slow down, expired, denied, a disabled Device Flow, rate limits and network failures. A verification page that is not HTTPS is refused.
- `GitHubSession` owns the account state: it restores the saved token at launch and confirms it with `GET /user` (a rejected token is deleted, a network failure keeps it and shows "offline"), runs sign-in (opens the verification page, honors the interval and `slow_down`, retries up to three dropped requests, stops at the code's expiry), saves the token only to the Keychain, and signs out by deleting the Keychain item.
- UI: the account row at the bottom of each workspace sidebar opens the connection sheet (code, Copy, Open GitHub Again, Cancel, every failure with its next step, and after success a link to install the app on repositories). Settings shows the account with Sign Out and a link to revoke the authorization at https://github.com/settings/apps/authorizations, since revoking from the app would need a client secret.

Verified with unit tests against canned GitHub responses and fakes. Not yet verified: a real sign-in against github.com, Keychain behavior in a Developer ID signed build, and repository listing after installation (backlog B06/B07).

## Enterprise Servers

Enterprise servers sign in with a personal access token only; Runnir Desktop is registered on github.com. Each server's token is in Keychain as `dev.runnir.github` / `enterprise:<server id>`, and the server list (name, web URL, API URL and the token's login, never a token) in `github-servers.json`. The Core sends a token only to its server's API origin and refuses redirects to another origin. URLs must be https; http is accepted only for a loopback host (the Core always, the app in Debug builds) so tests and local fakes can run. Certificates are checked against the macOS trust store, so a company CA installed in Keychain works; there is no option to skip the check. A token an Enterprise server rejects is forgotten by the Core and never signs the user out of github.com. Removing a server deletes its token from Keychain and clears it in the Core, also when a slower sign-in was still being handed over; the token stays valid on the server until the user revokes it. Links a server sends (pull requests, runs, repositories) are opened only when they are http or https, so a server cannot make Runnir open a file or another app. See [GitHub Enterprise Servers](../architecture/github-enterprise.md).
