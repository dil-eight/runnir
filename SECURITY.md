# Security Policy

Report security issues privately to Dil Eight LLC maintainers before public disclosure.

## Security Principles

- No telemetry by default.
- No repository code or logs are sent to a Runnir backend.
- GitHub credentials must be stored only in macOS Keychain.
- Secrets, signing keys, certificates, and provisioning profiles must never be committed.
- Future filesystem access must be explicit and scoped to user intent.

## Supported Versions

The project is in early bootstrap. Security fixes target the latest `main` branch until the first stable release.
