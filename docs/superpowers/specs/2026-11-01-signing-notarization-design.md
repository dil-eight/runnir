# Signing and notarization (B48)

Status: design approved on 2026-11-01; the local build added on 2026-11-02; the data protection keychain added on 2026-11-04. Builds on the build marks (B47), ADR 0005 (Developer ID without the App Sandbox) and the release workflow.

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
| A build signed on a Mac | A local build (`RUNNIR_BUILD=local`): Runnir Local, an app of its own with a pink LOCAL mark, so it is never taken for a tagged build ([below](#the-local-build)) |
| Keychain | The data protection keychain, through a Developer ID provisioning profile per app: access follows the app's identifier and team, so macOS never asks for the login password item by item ([below](#the-data-protection-keychain)) |

## Credentials

GitHub environment `release`, deployable only from tags matching `v*`:

| Kind | Name | Holds |
| --- | --- | --- |
| Secret | `DEVELOPER_ID_P12` | The Developer ID Application certificate and its private key, `.p12`, base64 |
| Secret | `DEVELOPER_ID_P12_PASSWORD` | The `.p12`'s password |
| Secret | `NOTARY_KEY_P8` | The App Store Connect API key, `.p8`, base64 |
| Secret | `NOTARY_KEY_ID` | The API key's ID |
| Secret | `NOTARY_ISSUER_ID` | The API key's issuer ID |
| Secret | `DEVELOPER_ID_PROFILE` | The Developer ID provisioning profile of `com.runnir.app`, base64 |
| Variable | `APPLE_TEAM_ID` | The Apple Developer team ID |

The user sets them; they are never written to the repository, the logs or a file outside the job's temporary folder.

## Scripts

`scripts/signing-identity.sh` prints the identity's SHA-1 by the rule below, and `scripts/check-signature.sh CODE...` checks each signature's team, hardened runtime and timestamp; `sign-app.sh` and `sign-binary.sh` both use them.

### `scripts/sign-app.sh APP`

Signs a built `Runnir.app` with the Developer ID Application identity of `$APPLE_TEAM_ID`, inside out:

1. Every `.dylib` and `.framework` in `Contents/Frameworks`.
2. `Contents/Helpers/runnir-core` with the identifier `com.runnir.core`, and `Contents/Helpers/act` with `com.runnir.act`.
3. The app, with `apps/macos/Runnir/Runnir.entitlements` (no sandbox, no exceptions) and the entitlements of its provisioning profile, which `embed-profile.sh` puts into `Contents/embedded.provisionprofile`.

Every signature uses `--options runtime` (the hardened runtime) and `--timestamp`. Afterwards the script checks `codesign --verify --deep --strict`, that the app's and each helper's `TeamIdentifier` is `$APPLE_TEAM_ID`, and that the app embeds a profile and carries the application identifier `$APPLE_TEAM_ID.<bundle identifier>`, and exits 1 on any difference. The profile is `RUNNIR_PROFILE`, else `~/.config/runnir/release.provisionprofile` for `com.runnir.app` and `local.provisionprofile` for `com.runnir.app.local`; without one the script stops.

### `scripts/embed-profile.sh APP PROFILE ENTITLEMENTS_OUT [IDENTITY]`

Decodes the profile (`security cms -D`) and refuses one that is not for the app's bundle identifier, is of another team than `$APPLE_TEAM_ID` when that is set, has expired, or does not list the certificate of `IDENTITY`. It then copies the profile into the app and writes the entitlements: `Runnir.entitlements` with `com.apple.application-identifier` and `com.apple.developer.team-identifier` from the profile, and `keychain-access-groups` narrowed from the profile's `TEAM.*` to the app's own identifier. The team comes from the profile, never from the repository.

The identity (`signing-identity.sh`) is `SIGNING_IDENTITY` (a certificate's SHA-1) when set; otherwise the one valid `Developer ID Application: … ($APPLE_TEAM_ID)` that `security find-identity -v -p codesigning` lists. When several are valid (a renewed certificate beside the old one), the script stops and lists their SHA-1s and expiry dates, so the caller sets `SIGNING_IDENTITY` or removes the old one. It is passed to `codesign` by its SHA-1, so two certificates with one name never mix. In CI the temporary keychain holds one certificate.

### `scripts/sign-binary.sh FILE IDENTIFIER`

Signs one command-line binary the same way (hardened runtime, timestamp, the given identifier) and checks it. Used for the Core CLI's darwin binaries (`com.runnir.cli`).

### `scripts/notarize.sh FILE`

Submits a zip to Apple and waits (at most 60 minutes). Credentials: with `NOTARY_PROFILE` set, that keychain profile (on a Mac); otherwise `NOTARY_KEY_FILE`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID` (in CI). A result other than Accepted prints Apple's log for the submission and exits 1.

### `scripts/staple-app.sh APP`

Staples the ticket to the app, then checks `xcrun stapler validate` and `spctl --assess --type execute`, which must say `source=Notarized Developer ID`.

## The release workflow

`release.yml`'s job runs in the `release` environment, with a 90-minute limit. It picks the build (B47) first, so a bad tag fails before any work, then:

1. **Check credentials**: each secret and the variable is present, else fail naming the missing ones.
2. **Keychain**: a temporary keychain with a random password, the `.p12` imported into it for `codesign` only (`security set-key-partition-list`), added to the search list. Apple's Developer ID G2 intermediate (from apple.com) is imported into it too, so the chain does not depend on the runner image, and the step checks that exactly one identity of the team is there. The `.p8` and the provisioning profile (`RUNNIR_PROFILE`) are written to the job's temporary folder.
3. **Core binaries**: built as today; the two darwin binaries are signed with `sign-binary.sh`, zipped together and notarized.
4. **Archive**: as today, unsigned, then checked against the build (B47).
5. **App**: `sign-app.sh`, a zip, `notarize.sh`, `staple-app.sh`, and the final zip of the stapled app, `Runnir-<tag>.zip`.
6. **Publish**: the draft release as today, its notes saying the app and the macOS binaries are signed with Developer ID and notarized by Apple.
7. **Clean up**, whatever happened before: the temporary keychain is deleted and the search list restored, the `.p8` and the profile removed.

`app-build.yml` does not change: pull requests build unsigned, and pull requests from forks never see the secrets. `ci.yml` runs `scripts/test-signing.sh`.

## On a Mac

The same scripts sign and notarize a local archive, with the certificate in the login keychain and the `runnir-notary` profile (`xcrun notarytool store-credentials`). The archive is a local build:

```bash
xcodebuild archive -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'generic/platform=macOS' -archivePath "$PWD/build/Runnir.xcarchive" RUNNIR_BUILD=local CODE_SIGNING_ALLOWED=NO
export APPLE_TEAM_ID=… NOTARY_PROFILE=runnir-notary
scripts/sign-app.sh build/Runnir.xcarchive/Products/Applications/Runnir.app
```

`README.md` documents this next to the release section.

### The local build

A build signed on a Mac would otherwise be archived as a beta, and a signed beta from a Mac looks exactly like one from a tag. It is a fifth build of B47's kind instead, `local`, which only a person passes to `xcodebuild` (`RUNNIR_BUILD=local`); Xcode's own builds stay dev and the release workflow never makes one.

| What | Local |
| --- | --- |
| The app | Runnir Local, `com.runnir.app.local`: an app of its own, as Runnir Dev is, that runs beside an installed Runnir and Runnir Dev |
| Data, logs, caches | `~/Library/Application Support/Runnir Local`, `~/Library/Logs/Runnir Local`, `~/Library/Caches/Runnir Local` |
| Keychain services | `com.runnir.app.local.github`, `com.runnir.app.local.local-run` |
| The app icon | `AppIcon-Local`: the pill of B47 with LOCAL in pink, `#F472B6`; amber, violet, blue, green and red already mean dev, alpha, beta, success and failure |
| The menu bar | The LOCAL capsule after the glyph, as for dev, alpha and beta |
| The windows | LOCAL in a pink capsule where a dev build shows DEV (`BuildBadge`, formerly `DevBuildBadge`); its tooltip says it is signed on this Mac, with its own data and sign-in |

`RunnirBuild` gets `case local` (palette `pink400`); `marksWindows`, `folderName` and `keychainPrefix` treat dev and local as apps of their own. The build settings gain `RUNNIR_BUNDLE_SUFFIX_local = .local`, `RUNNIR_DISPLAY_NAME_local = Runnir Local` and `RUNNIR_APPICON_local = AppIcon-Local`. Drawn in `runnir.pen`, journey F: `S19 / Menu bar icon / Build marks / Dark / 680x640` (a fifth app icon and the LOCAL capsule in the menu bar) and `S19 / Build marks / DEV and LOCAL in the windows / Dark / 560x640`.

### A signed dev build (added 2026-11-03)

Xcode's own builds keep the linker's ad hoc signature, which names a build by its hash. Keychain took each new build of Runnir Dev for another app and asked for the login password again after every build. On a Mac with a code signing identity, the Runnir scheme's build post-action, `scripts/sign-dev-build.sh`, signs a dev build with it, inside out: Swift's libraries in `Contents/Frameworks`, the helpers, a test bundle Xcode put into the app, then the app. Keychain then knows Runnir Dev by its identifier and certificate, and "Always Allow" holds across builds. The bundle identifier becomes the signing identifier, so macOS also lets the build post notifications.

- The SHA-1 comes from `RUNNIR_DEV_SIGNING_IDENTITY` or the first line of `~/.config/runnir/dev-signing-identity`, never from the repository. Without either the build stays ad hoc, as in CI; with an identity that is not in the keychain search list it stays ad hoc with a warning.
- No hardened runtime and no timestamp: the unit tests load into the app, the debugger attaches to it, and a build needs no network.
- A post-action, not a build phase: Xcode copies Swift's compatibility libraries into `Contents/Frameworks` after the last build phase, which broke a signature made in one. A post-action's failure does not fail the build; the build is then left ad hoc or with a broken seal, and Keychain asks again.
- Local and tagged builds skip it; `sign-app.sh` signs them.

```bash
security find-identity -v -p codesigning
mkdir -p ~/.config/runnir && echo SHA-1 > ~/.config/runnir/dev-signing-identity
```

With the Developer ID profile of `com.runnir.app.dev` in `RUNNIR_DEV_PROFILE` or `~/.config/runnir/dev.provisionprofile`, the build also embeds it and takes its application identifier, so it uses the data protection keychain ([below](#the-data-protection-keychain)). A profile that does not fit leaves the build on the file-based keychain, with a warning.

### The data protection keychain (added 2026-11-04)

A signature alone did not stop the prompts. The file-based keychain keeps a list of allowed programs on each item, so a build Keychain did not know yet asked once for every item it read: Secrets and Variables reads every variable, a local run every value, so a new signature meant a prompt per value. The data protection keychain has no such list: an item belongs to a keychain access group, and the app's entitlements, which a provisioning profile authorizes, say which groups it may use. Runnir's items are then the app's own and are read without a prompt, whatever the build.

- **Profiles**: an explicit App ID and a Developer ID provisioning profile, made with the Developer ID Application certificate, for each app: `com.runnir.app` (release, alpha and beta), `com.runnir.app.local` and `com.runnir.app.dev`. No capability is needed; a profile carries the application identifier, the team and `keychain-access-groups` `TEAM.*`. On a Mac they are `~/.config/runnir/release.provisionprofile`, `local.provisionprofile` and `dev.provisionprofile`; in CI the release one is the secret `DEVELOPER_ID_PROFILE`. Never in the repository: a profile names the team.
- **The app**: `GenericPassword` adds `kSecUseDataProtectionKeychain` to every query when the build's signature carries `com.apple.application-identifier` (`SecTaskCopyValueForEntitlement`). A build without it (ad hoc, CI, a Mac without the dev profile) keeps the file-based keychain; the data protection keychain refuses it (`errSecMissingEntitlement`). The default access group is the app's identifier, so Runnir, Runnir Local and Runnir Dev keep apart as before.
- **Data**: items in the file-based keychain stay there and are not read; a dev or local build signs in to GitHub again and its values are entered again. No release has stored any, so there is nothing to move ([AGENTS.md](../../../AGENTS.md): no compatibility before the first tag). Signing out or forgetting a value deletes only from the data protection keychain: deleting a file-based item the build is not listed on would ask for the password again. The old items, a dev build's GitHub token among them, are removed in Keychain Access (search `com.runnir.app.dev`, or `runnir.dev` for the earlier `com.runnir.dev` and `io.dil8.runnir.dev`), and the token revoked on GitHub if it should stop working.
- **Debugging**: a dev build with its profile also gets `com.apple.security.get-task-allow`, as Xcode's development signing does, so the unit tests are injected and the debugger attaches although the profile's entitlements make macOS guard the process. Local and tagged builds never get it.

## Not in this change

- A DMG or an installer package.
- Updates.

## Tests

- `shellcheck` on the signing scripts and actionlint on `release.yml`.
- `scripts/test-signing.sh`, in CI's build job, runs the scripts against a stand-in for `security`: `signing-identity.sh`, `sign-app.sh` and `sign-binary.sh` refuse without `APPLE_TEAM_ID`, without an identity of that team, and with several identities and no `SIGNING_IDENTITY`; `check-signature.sh` refuses unsigned and ad hoc code; `notarize.sh` refuses without credentials, naming the missing ones.
- `test-signing.sh` also runs `sign-dev-build.sh`: it skips a build that is not dev, a Mac without an identity, and an identity missing from the keychain (with a warning), and reads the file's SHA-1 in any case.
- `test-signing.sh` runs `sign-dev-build.sh` with a profile against a stand-in for `codesign`: the app takes the profile's entitlements and `get-task-allow`; a profile of another app is left out with a warning, the app signed without entitlements and without the profile.
- `test-signing.sh` runs `embed-profile.sh` on stand-in profiles: it refuses a missing file, one that is not a profile, a profile of another app or team, an expired one and one without the signing certificate, embeds nothing then, and otherwise copies the profile and writes the app's identifier, team and access group.
- `LocalRunValuesTests` checks that the Keychain queries ask for the data protection keychain only when the build is entitled.
- On a Mac, a dev build with its profile keeps Runnir Dev's sign-in and values in the data protection keychain without a prompt after a rebuild.
- On a Mac, a dev build signed with the Developer ID identity passes `codesign --verify --deep --strict`, also after the unit tests ran in it (2026-11-03).
- `RunnirBuildTests` and the menu bar test cover the local build: its Info.plist value, mark, spoken name, folders, Keychain prefix, window mark and menu bar capsule.
- On a Mac, the whole path on a Release archive of a local build (`RUNNIR_BUILD=local`): sign, verify, notarize, staple, `spctl` says `Notarized Developer ID`; the signed darwin Core binary is notarized; the app then opens, reads a chosen folder, keeps its sign-in in Keychain and starts its Core under the hardened runtime.
- The CI path is checked by the first tag; until then the release workflow's signing is written but not verified.

## Delivery

Branch `dilbarov/signing`, one pull request opened once the build marks (#56) are merged, rebased onto `main`. With it: this spec, the B48 row of the checklist, `README.md`, and, after the check on a Mac, ADR 0005's "Not Yet Verified" and the Release row of `docs/architecture/gap-analysis.md`.
