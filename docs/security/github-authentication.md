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
- User token expiry is turned off, because refreshing an expiring token needs a client secret, which a desktop app must not ship. Tokens stay in Keychain and can be revoked by the user in GitHub settings or with "Revoke all user tokens". Confirm this choice against GitHub's current documentation when the login flow is built.
- GitHub requires at least one private key before the app can be installed. The key is kept by the owner outside the repository; the desktop app never uses it. No client secret was generated.

## Current Status

Implemented in Swift (the token never leaves the app process):
- `GitHubDeviceFlowClient` requests a device code with the client id only and polls `login/oauth/access_token`, mapping pending, slow down, expired, denied, a disabled Device Flow, rate limits and network failures. A verification page that is not HTTPS is refused.
- `GitHubSession` owns the account state: it restores the saved token at launch and confirms it with `GET /user` (a rejected token is deleted, a network failure keeps it and shows "offline"), runs sign-in (opens the verification page, honors the interval and `slow_down`, retries up to three dropped requests, stops at the code's expiry), saves the token only to the Keychain, and signs out by deleting the Keychain item.
- UI: the account row at the bottom of each workspace sidebar opens the connection sheet (code, Copy, Open GitHub Again, Cancel, every failure with its next step, and after success a link to install the app on repositories). Settings shows the account with Sign Out and a link to revoke the authorization at https://github.com/settings/apps/authorizations, since revoking from the app would need a client secret.

Verified with unit tests against canned GitHub responses and fakes. Not yet verified: a real sign-in against github.com, Keychain prompts in a signed sandboxed build, and repository listing after installation (backlog B06/B07).
