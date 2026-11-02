# Signing and notarization (B48)

Status: design approved on 2026-11-01. Builds on the build marks (B47), ADR 0005 (Developer ID without the App Sandbox) and the release workflow.

## Problem

Tagged builds are published unsigned. macOS's Gatekeeper refuses to open an unsigned app or command-line tool downloaded from the web, so every alpha, beta or release would have to be opened around it, and Keychain asks again after each update because the code's identity changes. ADR 0005 decided on Developer ID signing with the hardened runtime and notarization; nothing implements it yet.

## Decisions

| Question | Decision |
| --- | --- |
| Which builds | Every tagged build the release workflow makes: release, alpha and beta (B47). Builds without a tag (Xcode, the CI checks' archive) stay unsigned |
| What is signed | `Runnir.app` and everything in it, and the macOS binaries of the Core CLI published beside it. Linux and Windows binaries are not signed |
| How | Our own scripts sign after the archive is built, inside out, with `codesign`; the Xcode project's signing settings do not change (`CODE_SIGNING_ALLOWED = NO` stays). The same scripts run on a Mac and in CI |
| Notarization | `xcrun notarytool` with an App Store Connect API key in CI, a `notarytool` keychain profile on a Mac. The app is stapled; a bare command-line binary cannot be, so macOS checks it online |
| Team ID | Never in the repository: the GitHub variable `APPLE_TEAM_ID` of the `release` environment in CI, the environment variable `APPLE_TEAM_ID` on a Mac. The scripts find the Developer ID identity of that team in the keychain |
| Missing credentials | A tag fails, naming what is missing. No unsigned build is published |
| Package | A zip of the stapled app, as today, named `Runnir-<tag>.zip` (no `-unsigned`) |

## Credentials

GitHub environment `release`, deployable only from tags matching `v*`:

| Kind | Name | Holds |
| --- | --- | --- |
| Secret | `DEVELOPER_ID_P12` | The Developer ID Application certificate and its private key, `.p12`, base64 |
| Secret | `DEVELOPER_ID_P12_PASSWORD` | The `.p12`'s password |
| Secret | `NOTARY_KEY_P8` | The App Store Connect API key, `.p8`, base64 |
| Secret | `NOTARY_KEY_ID` | The API key's ID |
| Secret | `NOTARY_ISSUER_ID` | The API key's issuer ID |
| Variable | `APPLE_TEAM_ID` | The Apple Developer team ID |

The user sets them; they are never written to the repository, the logs or a file outside the job's temporary folder.

## Scripts

### `scripts/sign-app.sh APP`

Signs a built `Runnir.app` with the Developer ID Application identity of `$APPLE_TEAM_ID`, inside out:

1. Every `.dylib` and `.framework` in `Contents/Frameworks`.
2. `Contents/Helpers/runnir-core` with the identifier `io.dil8.runnir.core`, and `Contents/Helpers/act` with `io.dil8.runnir.act`.
3. The app, with `apps/macos/Runnir/Runnir.entitlements` (empty: no sandbox, no exceptions).

Every signature uses `--options runtime` (the hardened runtime) and `--timestamp`. Afterwards the script checks `codesign --verify --deep --strict` and that the app's and each helper's `TeamIdentifier` is `$APPLE_TEAM_ID`, and exits 1 on any difference.

The identity is `SIGNING_IDENTITY` (a certificate's SHA-1) when set; otherwise the one valid `Developer ID Application: … ($APPLE_TEAM_ID)` that `security find-identity -v -p codesigning` lists. When several are valid (a renewed certificate beside the old one), the script stops and lists their SHA-1s and expiry dates, so the caller sets `SIGNING_IDENTITY` or removes the old one. It is passed to `codesign` by its SHA-1, so two certificates with one name never mix. In CI the temporary keychain holds one certificate.

### `scripts/sign-binary.sh FILE IDENTIFIER`

Signs one command-line binary the same way (hardened runtime, timestamp, the given identifier) and checks it. Used for the Core CLI's darwin binaries (`io.dil8.runnir.cli`).

### `scripts/notarize.sh FILE`

Submits a zip to Apple and waits (at most 60 minutes). Credentials: with `NOTARY_PROFILE` set, that keychain profile (on a Mac); otherwise `NOTARY_KEY_FILE`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID` (in CI). A result other than Accepted prints Apple's log for the submission and exits 1.

### `scripts/staple-app.sh APP`

Staples the ticket to the app, then checks `xcrun stapler validate` and `spctl --assess --type execute`, which must say `source=Notarized Developer ID`.

## The release workflow

`release.yml`'s job runs in the `release` environment, with a 90-minute limit. After picking the build (B47):

1. **Check credentials**: each secret and the variable is present, else fail naming the missing ones.
2. **Keychain**: a temporary keychain with a random password, the `.p12` imported into it for `codesign` only (`security set-key-partition-list`), added to the search list. The `.p8` is written to the job's temporary folder.
3. **Core binaries**: built as today; the two darwin binaries are signed with `sign-binary.sh`, zipped together and notarized.
4. **Archive**: as today, unsigned, then checked against the build (B47).
5. **App**: `sign-app.sh`, a zip, `notarize.sh`, `staple-app.sh`, and the final zip of the stapled app, `Runnir-<tag>.zip`.
6. **Publish**: the draft release as today, its notes saying the app and the macOS binaries are signed with Developer ID and notarized by Apple.
7. **Clean up**, whatever happened before: the temporary keychain is deleted and the search list restored, the `.p8` removed.

`app-build.yml` does not change: pull requests build unsigned, and pull requests from forks never see the secrets.

## On a Mac

The same scripts sign and notarize a local archive, with the certificate in the login keychain and the `runnir-notary` profile (`xcrun notarytool store-credentials`):

```bash
export APPLE_TEAM_ID=… NOTARY_PROFILE=runnir-notary
scripts/sign-app.sh build/Runnir.xcarchive/Products/Applications/Runnir.app
```

`README.md` documents this next to the release section.

## Not in this change

- Apple Development signing of dev builds on a Mac, and the data-protection keychain.
- A DMG or an installer package.
- Updates.

## Tests

- `shellcheck` on the four scripts and actionlint on `release.yml`.
- `sign-app.sh` and `notarize.sh` refuse to run without `APPLE_TEAM_ID`, without an identity of that team, with several identities and no `SIGNING_IDENTITY`, or without notarization credentials, each with a message naming what is missing.
- On a Mac, the whole path on a Release archive of a beta build (`RUNNIR_BUILD=beta`): sign, verify, notarize, staple, `spctl` says `Notarized Developer ID`; the signed darwin Core binary is notarized; the app then opens, reads a chosen folder, keeps its sign-in in Keychain and starts its Core under the hardened runtime.
- The CI path is checked by the first tag; until then the release workflow's signing is written but not verified.

## Delivery

Branch `dilbarov/signing`, one pull request opened once the build marks (#56) are merged, rebased onto `main`. With it: this spec, the B48 row of the checklist, `README.md`, and, after the check on a Mac, ADR 0005's "Not Yet Verified" and the Release row of `docs/architecture/gap-analysis.md`.
