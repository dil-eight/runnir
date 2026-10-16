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

## Current Status

The bootstrap includes the credential storage abstraction and GitHub REST client. A real login flow is intentionally not presented until a GitHub App or OAuth app configuration exists.
