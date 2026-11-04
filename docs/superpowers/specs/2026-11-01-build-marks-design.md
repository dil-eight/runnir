# Build marks (B47)

Status: design approved on 2026-11-01, built on branch dilbarov/build-marks. Drawn in `runnir.pen` (journey F, Row — Menu bar, `S19 / Menu bar icon / Build marks`). Builds on the app icon script (`scripts/make-app-icon.swift`), the menu bar icon (S19, `MenuBarIcon`), the release workflow and ADR 0005.

## Problem

Every Runnir build looks the same: a build made in Xcode, a pre-release from a tag and a release share the icon, the menu bar glyph, the bundle ID, the data folder, the Keychain items and the sign-in. Someone who runs a release and develops Runnir on the same Mac cannot tell the two apart in the Dock or the menu bar, and the two copies read and write the same data. The first public builds will be alpha and beta pre-releases, which must not be taken for a release either.

## Decisions

| Question | Decision |
| --- | --- |
| Which builds there are | Four: `release`, `alpha`, `beta` and `dev`. B48 adds a fifth, `local`, for a build signed on a Mac: Runnir Local, an app of its own like dev, with a pink LOCAL mark ([B48 spec](2026-11-01-signing-notarization-design.md#the-local-build)) |
| What decides the build | The tag the release workflow builds: `v1.2.3` is release, `v1.2.3-alpha.N` is alpha, `v1.2.3-beta.N` is beta. Any other suffix (`-rc.1`) stops the release workflow with an error. Everything built without a tag is dev: Xcode on a Mac, Debug or Release, and the CI checks' archive |
| Where the build is set | One build setting, `RUNNIR_BUILD`, `dev` unless the release workflow passes another value. Xcode derives the bundle ID, the display name and the app icon from it; the app reads it from Info.plist |
| Release, alpha and beta | One app: bundle ID `com.runnir.app`, name Runnir, the same data, Keychain items and sign-in. An alpha is replaced in place by a beta and a beta by a release |
| Dev | A separate app, Runnir Dev: bundle ID `com.runnir.app.dev`, its own data, logs, caches, Keychain items, preferences and notification permission. It runs beside an installed release with its own Core |
| The app icon | Release: as today. Dev, alpha and beta: a pill inside the tile's lower edge with DEV, ALPHA or BETA, amber, violet and blue. The pill never leaves the tile: macOS puts an icon whose shape leaves the rounded tile on a plain backing tile |
| The menu bar icon | Release: as today. Dev, alpha and beta: a capsule with the word to the right of the glyph, in the menu bar's text color with the word cut out of it. Color keeps meaning the CI state only; the dot stays on the glyph's corner |
| The windows | Dev only: DEV in an amber capsule, as on its Dock icon, next to the workspace switcher in a workspace window's title strip, beside the logo in the Workspace Manager, before Refresh in the Pull Requests window and after the version on the splash. Alpha, beta and release windows look as today |
| The names | From runnir.com, the product's domain. The apps are under `com.runnir.app`, and a build's Keychain services begin with its bundle ID; none of the release's begins with another app's (`run-values`, not `local-run`, which began like Runnir Local's `com.runnir.app.local`). The names that are not an app's are under `com.runnir`, the same for every build: the notification categories and actions, the in-app notification name and the Core's container label. No name of the earlier domains is kept. (From 2026-11-01 to 2026-11-04 the names were under `io.dil8.runnir`, from the company's domain, and for part of 2026-11-04 the apps' were under `com.runnir`; no release used them, so they changed in place) |
| Data of earlier builds | No migration (AGENTS.md). The data folder `Runnir` stays with release, alpha and beta; the sign-in, the local run values in Keychain and the preferences of earlier builds are not read again, so the first new build is signed in again. Runnir Dev starts empty |

## Build settings

The `Runnir` target gets, in both configurations:

- `RUNNIR_BUILD = dev`.
- `RUNNIR_BUNDLE_SUFFIX_dev = .dev`, and `PRODUCT_BUNDLE_IDENTIFIER = com.runnir.app$(RUNNIR_BUNDLE_SUFFIX_$(RUNNIR_BUILD))`. The other builds have no suffix setting, so theirs is empty.
- `RUNNIR_DISPLAY_NAME_dev = Runnir Dev`, `RUNNIR_DISPLAY_NAME_alpha`, `_beta` and `_release` = `Runnir`, and `INFOPLIST_KEY_CFBundleDisplayName = $(RUNNIR_DISPLAY_NAME_$(RUNNIR_BUILD))`.
- `RUNNIR_APPICON_dev = AppIcon-Dev`, `_alpha = AppIcon-Alpha`, `_beta = AppIcon-Beta`, `_release = AppIcon`, and `ASSETCATALOG_COMPILER_APPICON_NAME = $(RUNNIR_APPICON_$(RUNNIR_BUILD))`. Only the chosen set is compiled into the app (`ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS` stays `NO`).
- `INFOPLIST_FILE = Runnir/Info.plist`, a partial Info.plist merged with the generated one (`GENERATE_INFOPLIST_FILE` stays `YES`), holding one key: `RunnirBuild = $(RUNNIR_BUILD)`.

`PRODUCT_NAME` stays `Runnir`: the bundle is `Runnir.app` and the module `Runnir` for every build, so the tests' host and `@testable import Runnir` do not change. The test targets' bundle IDs become `com.runnir.app.tests` and `com.runnir.app.uitests`.

## The app

### The build

A new `enum RunnirBuild: String { case dev, alpha, beta, release }` in `App/RunnirBuild.swift`:

- `static let current` reads `RunnirBuild` from `Bundle.main`'s Info.plist. A missing or unknown value is `dev`, so a build that lost the key shows DEV instead of passing for a release.
- `init(infoValue: String?)` does the reading, for tests.
- `mark: String?`: nil for release, else `DEV`, `ALPHA` or `BETA`.
- `marksWindows: Bool`: true for dev only.
- `spokenName: String`: `Runnir`, `Runnir Dev`, `Runnir Alpha` or `Runnir Beta`, for VoiceOver.
- `folderName: String`: `Runnir Dev` for dev, `Runnir` for the others.
- `keychainPrefix: String`: `com.runnir.app.dev` for dev, `com.runnir.app` for the others: the bundle ID.

### What dev keeps apart

| What | Release, alpha, beta | Dev |
| --- | --- | --- |
| Data (`RunnirSupportDirectory`), also the Core's `--data-dir` | `~/Library/Application Support/Runnir` | `~/Library/Application Support/Runnir Dev` |
| Core log (`CoreProcessSupervisor.logURL`) | `~/Library/Logs/Runnir/core.log` | `~/Library/Logs/Runnir Dev/core.log` |
| Core caches, passed as `--cache-dir` | `~/Library/Caches/Runnir` | `~/Library/Caches/Runnir Dev` |
| github.com and Enterprise tokens (`KeychainCredentialStore.defaultService`) | `com.runnir.app.github` | `com.runnir.app.dev.github` |
| Local run values (`KeychainLocalRunValueStore`) | `com.runnir.app.run-values` | `com.runnir.app.dev.run-values` |
| Preferences, notification permission | by bundle ID | by bundle ID |

Each place takes `RunnirBuild.current` through its existing seam (a default argument or a static), so tests pass a build instead of reading the bundle. The UI-testing paths and Keychain services (`--ui-testing`) still win over the build; their services become `com.runnir.app.github.ui-testing` and `com.runnir.app.run-values.ui-testing`. The Core socket is already per bundle path (`CoreProcessSupervisor.instanceTag`).

The other reverse-DNS names are under `com.runnir`, the same for every build: the notification categories and action `com.runnir.run`, `com.runnir.checks.failed` and `com.runnir.open-run` (`RunNotifications`), and `Notification.Name("com.runnir.localRunValuesChanged")`.

### The menu bar icon (S19)

`MenuBarIcon.image(badge:dimmed:build:)`:

- Release: as today, the template glyph when there is nothing to show.
- Dev, alpha, beta: the image is the glyph's area as today (at least 21 by 18 points, where the dot sits), a 2-point gap and a capsule 11 points high with a 3-point corner radius and 3 points of padding each side. The capsule is drawn in the menu bar's text color, like the glyph with a dot; its word, in the system font at 7.5 points, bold, with 0.4 points of tracking, is cut out of it (`.clear`). The image is not a template and is drawn again for each appearance, as the dot case is now.
- The dot keeps its place and its clear ring on the glyph's lower right corner, never on the capsule.
- A dimmed glyph (signed out) dims the capsule too.

`MenuBarIcon.accessibilityLabel` begins with the build's `spokenName`, then the states as today ("Runnir Beta, a run failed").

### The windows

`DevBuildBadge` (next to `BrandLogo` in `DesktopViews.swift`) shows DEV when `RunnirBuild.current.marksWindows`, and nothing otherwise: the system font at 10 points, heavy, 0.6 points of tracking, `#14161A` on an `#FBBF24` capsule with 7 by 2 points of padding. VoiceOver reads it as Runnir Dev; its tooltip says the build has its own data and sign-in. It sits after the workspace switcher in a workspace window's title strip, after the logo in the Workspace Manager's header, before Refresh in the Pull Requests window's header, and after the version on the startup splash.

### The app icon

`scripts/make-app-icon.swift` renders four icon sets into `Assets.xcassets`: `AppIcon`, `AppIcon-Dev`, `AppIcon-Alpha` and `AppIcon-Beta`. The marked sets draw the tile and the mark as today, then a pill on the 1024 canvas: 170 points high, centered, its lower edge 40 points above the tile's (140 above the canvas's), so pill and outline stay inside the tile, 60 points of padding each side of the word, a 14-point outline in `#0E0F12`, and the word in the system font, heavy, 112 points, 6 points of tracking, in `#14161A`. Colors: DEV `#FBBF24`, ALPHA `#A78BFA`, BETA `#7C9CFF`. The generated PNGs are committed, as today.

## The Core

The label the Core puts on local run containers becomes `com.runnir.execution` (`localrun.Label`). Containers labelled by an earlier build are no longer found or removed by the Core.

`runnir serve` gets `--cache-dir <dir>`; the Core keeps act's cache in `<dir>/act` (`server.Options.ActCache`). Without the flag the cache stays in the user cache folder's `Runnir/act`, as today, for the CLI. The app always passes the build's folder (`ProcessCoreLauncher.arguments`).

## Workflows

- `release.yml` maps the tag to `RUNNIR_BUILD` (`release`, `alpha`, `beta`; any other suffix fails the job with the tag in the message) and passes it to `xcodebuild archive`. The draft release is marked as a pre-release for alpha and beta, as it is for any suffix today.
- After the archive, `release.yml` checks the built app's Info.plist: `CFBundleIdentifier` is `com.runnir.app`, `RunnirBuild` is the expected build and `CFBundleIconName` is the expected icon set.
- `app-build.yml` makes the same check on its archive for dev: `com.runnir.app.dev`, `dev`, `AppIcon-Dev`.

## States drawn

`S19 / Menu bar icon / Build marks / Dark / 560x640` in journey F, after `S19 / Menu bar icon / Glyph, sizes and CI states`: the app icon of the four builds at 96 and 32 points, the menu bar glyph of the four builds in a light and a dark menu bar, and the four with a failed check. `S19 / Build marks / DEV in the windows / Dark / 560x640` after it: the DEV capsule in a workspace window's title strip, the Workspace Manager's header, the Pull Requests window's header and the splash.

## Not in this change

- Developer ID signing and notarization (ADR 0005): its own change, once the certificates and the notarization key exist.
- Updates from one build to the next, and channels to receive them.
- An alpha's or beta's build in its windows, the About panel or Settings.
- Moving the data of earlier development builds to Runnir Dev.

## Tests

Swift (RunnirTests):

- `RunnirBuild(infoValue:)`: each of the four values, nil and an unknown value (dev).
- Each build's `mark`, `spokenName`, `folderName`, `keychainPrefix` and `marksWindows`.
- `RunnirSupportDirectory`, the Core log URL, the cache folder and the two Keychain services for dev and for release; the UI-testing overrides still win.
- `KeychainLocalRunValueStore.service(prefix:workspaceID:)` with the new prefix, and the notification identifiers.
- `ProcessCoreLauncher.arguments` carries `--cache-dir`.
- `MenuBarIcon.image`: release keeps the glyph's size and is a template with nothing to show; dev, alpha and beta are wider than the glyph by the gap and the capsule, and are not templates; the dot case is as wide as without the dot.
- `MenuBarIcon.accessibilityLabel` begins with the build's name.

Go: `serve --cache-dir` puts act's cache under the folder; without it the default is kept. The local run tests expect the `com.runnir.execution` label.

Workflows: actionlint, and the Info.plist checks above run in CI on every app build.

By hand: a dev build from Xcode shows Runnir Dev with the DEV icon in the Dock and the menu bar, starts signed out with an empty Workspace Manager, and runs beside a release build with its own Core.

## Delivery

One branch and one pull request: the build settings and Info.plist, `RunnirBuild` and its uses, the move to `com.runnir.app` and `com.runnir`, the menu bar icon, the icon sets and script, the Core flag and label, the workflows, this spec, the B47 row of the checklist and the `runnir.pen` frame. Docs that name the current identifiers are updated with them: `README.md` (the ad-hoc signing command), `docs/architecture/github-enterprise.md`, `docs/architecture/workspace-persistence.md` and `docs/security/github-authentication.md`. Records of earlier checks and earlier plans keep the names they used.
