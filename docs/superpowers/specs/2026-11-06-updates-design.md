# Updates By A Click (B50)

Status: design approved and built on 2026-11-06 on branch dilbarov/updates; not yet tried between two signed tags. Backlog: B50 in the [MVP checklist](../../product/mvp-implementation-checklist.md), part of the distribution work of the B17 release gate. Builds on signed and notarized releases (B48), the build kinds (B47) and Settings › About (B49). Drawn in `runnir.pen` (journey G, Row — Updates (B50)).

## Problem

A signed Runnir can only be replaced by downloading the next zip from GitHub and moving it into Applications by hand; nothing tells the user that a new version exists. The first public builds are alphas, which will be followed quickly by more alphas, betas and a release.

## Decisions

| Question | Decision |
| --- | --- |
| Mechanism | Runnir's own, in Swift with Foundation and Security; no Sparkle and no other dependency. The Core is not involved: code signatures and replacing the bundle are macOS-only |
| Where versions come from | `GET https://api.github.com/repos/dil-eight/runnir/releases?per_page=30`, without a token, published releases only (no drafts), each with its `Runnir-<tag>.zip` |
| Which versions a build is offered | By the running build (B47). Alpha: any newer version (alpha, beta or release). Beta: a newer beta of the same version (`0.2.0-beta.1 → 0.2.0-beta.2`) or a newer release. Release: newer releases only; with "Get beta versions" also newer betas. Runnir Dev and Runnir Local never check. Never a lower version |
| "Get beta versions" | A setting in Settings › About, off by default, shown only in a release build of 1.0.0 or later; turned off, a beta build is offered nothing until the next release |
| When it checks | At launch and once a day while "Check for updates automatically" is on (default), and on Check for Updates in Settings › About and in the app menu. Nothing installs by itself |
| Where it shows | A card above the GitHub account at the bottom of the sidebar of every workspace window, and the Updates part of Settings › About |
| Installing | One click: download with progress, check the signature, replace the app, restart it. A local run that is going asks first, as quitting does |
| Trust | The new app must have the running app's bundle identifier, be signed by the same Developer ID team (read from the running app's own signature, never from the repository) and be notarized. Anything else is refused and nothing changes |

## Versions

Tags are `v<major>.<minor>.<patch>` with an optional `-alpha.N` or `-beta.N` (B47). They are compared by semantic version precedence: `0.2.0-alpha.3 < 0.2.0-beta.1 < 0.2.0 < 0.2.1-alpha.1`. A tag that does not parse is skipped. The running version is `CFBundleShortVersionString`, which the release workflow sets from the tag.

From the releases a build may take (above), the newest wins. Equal or lower versions are never offered.

## Flow

States, shared by the sidebar card and Settings › About:

| State | Card | About |
| --- | --- | --- |
| idle | hidden | "Runnir is up to date · Checked 2 minutes ago", Check for Updates |
| checking | hidden | "Checking for updates…", the button disabled |
| available(version) | "Update available · Runnir 0.1.1 · What's New", Update | "Runnir 0.1.1 is available · What's New", Update |
| downloading(fraction) | "Downloading 0.1.1 · 42%", a bar filling, "8.1 of 19.2 MB", Cancel | the same line and bar |
| installing | "Installing 0.1.1…", a segment sweeping the bar, "Runnir checks the signature, installs the new version and restarts." | the same |
| restartPending(version) | "0.1.1 is installed", "It opens when Runnir quits.", Restart Now | the same |
| failed(reason) | "Couldn't update", the reason, "Nothing was changed.", Try Again, Download | the same, Try Again |
| outsideApplications | "Move to Applications": macOS runs this copy from a temporary folder; Download | the same |

What's New and Download open the release page on GitHub. The card appears with a short slide up and fade; Update turns into the bar.

1. **Check**: the request above, unauthenticated, with a 20-second timeout. A failed automatic check stays silent and retries at the next one; a failed Check for Updates says so in About. The result and the time are kept in user defaults, so About can say when it last checked.
2. **Download**: `URLSession` download task of the zip into a temporary folder on the volume of the running app (`FileManager.url(for: .itemReplacementDirectory, …, appropriateFor: Bundle.main.bundleURL)`), with progress. Cancel stops it and deletes the file.
3. **Unpack**: `/usr/bin/ditto -x -k` into the same folder; exactly one `Runnir.app` must come out.
4. **Check**: `SecStaticCodeCreateWithPath` and `SecStaticCodeCheckValidity` with all architectures and nested code checked, against the requirement `anchor apple generic and identifier "<own identifier>" and certificate leaf[subject.OU] = "<own team>" and notarized`. Its `CFBundleShortVersionString` must be the offered version.
5. **Replace**: `FileManager.replaceItemAt(Bundle.main.bundleURL, withItemAt: newApp)`, which swaps the two on the same volume in one step; the old bundle is deleted with the temporary folder.
6. **Restart**: a detached `/bin/sh` waits until this process has ended and runs `open` on the app's path; then the app quits through the usual path (`applicationShouldTerminate`), which asks about unsaved edits and local runs as it always does and stops the Core. When the user cancels that, the new version is already in place and opens at the next quit (restartPending, Restart Now); if the waiting process could not start, the user opens Runnir again.

Refused before downloading: a build that may not update (dev, local); an app the user cannot write (`FileManager.isWritableFile` on the bundle and its folder); an app macOS translocated (its path is under `/AppTranslocation/`) — the card says to move Runnir to Applications.

## Privacy

The check sends GitHub an anonymous request: the IP address and Runnir's user agent (`Runnir/<version>`), no token and no identifier. The privacy policy (site and `docs/legal/security-privacy-policy.md`) says so; "Check for updates automatically" turns the automatic checks off.

## Code

- `Features/Updates/UpdateVersion.swift`: parsing and precedence of tags; which releases a build may take (`UpdatePolicy`).
- `Features/Updates/UpdateFeed.swift`: the GitHub request behind a protocol, decoding releases and picking the zip.
- `Features/Updates/UpdateInstaller.swift`: download, unpack, signature check, replace, restart; each step behind a protocol so tests use fakes.
- `Features/Updates/UpdateCenter.swift`: the observable state machine, the daily timer, the settings (`checksAutomatically`, `getsBetas`) and the last check.
- Views: the sidebar card (`UpdateCard`), the Updates part of Settings › About, the app menu's Check for Updates….

## Testing

Unit tests, with fakes for the feed, the download and the installer:

- Tag parsing and precedence, including pre-release ordering and tags that do not parse.
- The policy table: alpha, beta and release builds with and without "Get beta versions", dev and local, never lower or equal.
- The state machine: available → downloading → installing → restart; Cancel; each failure leaves the app untouched and offers Try Again; automatic check failures stay silent; dev and local never check.
- The signature requirement names the running app's identifier and team and `notarized`; a build of another team, an unsigned build or one whose version differs is refused.
- A translocated path and an unwritable folder are refused before downloading.

Not checkable before two signed releases exist: an update from one tag to the next. Updates are not claimed to work until that has been done on a Mac (AGENTS.md).

## Not In This Change

Delta updates; installing while the app keeps running; updating Runnir Dev or Local; release notes inside the app (What's New opens GitHub); a feed of Runnir's own.
