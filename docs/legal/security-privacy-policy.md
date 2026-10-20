# Runnir Legal And Privacy Guardrails

Runnir is an open-source native macOS desktop application for local Git repositories and GitHub Actions automation.

## Required Guarantees

For v0.1, these apply to conventional UI/API actions and local workflow tools; AI, MCP and offers are deferred features.

- Do not transmit repository content or personal data by default. Any GitHub/cloud deployment or external AI operation requires explicit authorization for its destination and minimum necessary data. Provider consent is scoped by repository and data category.
- Do not collect or transmit personal data by default. Optional analytics must use explicit consent and a strict non-content allowlist; report sharing needs separate per-report review/approval. Disclose unavoidable network metadata and GitHub identity/publication effects instead of promising complete anonymity.
- Do not request broad filesystem access during the MVP. Future repository-folder access must be explicit and user initiated.
- Do not store GitHub credentials in UserDefaults, files, logs, crash reports, or diagnostics. Store OAuth/device-flow tokens only in macOS Keychain.
- Prefer narrowly scoped GitHub permissions: repository metadata, actions, pull requests, contents, and releases only when required by the feature.
- For public repositories, prefer the minimum GitHub scopes needed by the enabled feature. Request workflow write permissions only when CI management actions are enabled by the user.
- Keep release versioning tag-based, using semantic version tags such as `v0.1.0`.
- Local workflow validation must not execute repository hooks/scripts; local act execution requires explicit consent and a bounded resource/mount/network/credential policy.
- Never automatically inject the app's GitHub token, host secret environment or plaintext saved secrets into local execution.
- Preserve edits and require explicit saves; never automatically commit/push workflow changes.
- Publish builds through GitHub Releases. Developer ID signing, notarization, DMG packaging, and automatic updates are explicit release prerequisites, not assumed in bootstrap.

## Workspace Persistence Boundaries

Portable .runnir contains declarative non-secret config only and is read-only during normal open. Session/registry/SQLite/private overrides use resolved Application Support with scoped access; local repository/window identifiers, paths, cached GitHub data and environment values are excluded from analytics/crash summaries. Repository config cannot authorize Keychain reads, automatic execution or bypass confirmation. No secrets in DB/snapshots/preset files. Clear Cache/repair must preserve unique user-authored state; registry removal never silently deletes the repository. No new broad home-folder/diagnostic access is authorized by persistence.

The desktop workflow reader pins an opened repository directory for the grant lifetime. Reads traverse relative to that descriptor without following child symlinks, including links whose targets are inside the repository. Moving the root or replacing its old pathname does not redirect an existing reader. This is a read-boundary defense that Runnir enforces itself, not isolation for workflow execution.

## Review Checklist

- Filesystem permissions remain restricted and documented.
- No unrestricted shell execution is introduced.
- CI/release jobs do not print tokens, environment secrets, repository code, or local paths.
- New dependencies have permissive licenses and no known high-severity advisories.
- User-facing GitHub authentication copy explains the OAuth/device-flow configuration and never presents fake success.
- AI features keep repository data local by default and clearly label whether a response came from deterministic analysis, a local model, or an explicitly enabled external provider.
- Assistant action proposals require confirmation before workflow dispatch, rerun, cancel, release, tag, or token operations.
- Offer relevance is computed locally. Catalog requests carry no repository identifiers, stack fingerprints, source, logs or personal profile. Affiliate links are disclosed before navigation and may be bypassed with a direct vendor link.
- Catalog content cannot supply commands or execution permissions. Installation and cloud provisioning require separately reviewed actions; startup credits/free tiers are conditional, not guaranteed free service.
- Analytics and crash reporting follow [their separate policy](../product/analytics-and-crash-reporting.md). No repository data, credentials, raw logs/crash reports or personal paths in analytics; no background public issue creation. Consent withdrawal clears unsent analytics and does not imply deletion of published GitHub issues.
