# 0005 Developer ID Distribution Without the App Sandbox

Status: accepted, 2026-10-20.

## Context

Local workflow runs (FR-06) need the user's container engine (Docker Desktop, OrbStack, Colima) and tools such as `act`. Under the App Sandbox every process Runnir starts, including a `docker` or `act` command line, inherits the sandbox, and the sandbox refuses connections to Unix sockets outside the app's container, which is where the Docker API lives (`~/.docker/run/docker.sock`, `~/.orbstack/run/docker.sock`, `/var/run/docker.sock`). Temporary-exception entitlements for those paths are fragile and vary by engine. Running an own container engine inside the sandbox (a Linux VM through Virtualization.framework with `dockerd` and `act` inside) is possible in principle, but it is a large, separate product (kernel and engine updates, hundreds of megabytes, a second image cache) and does not need the sandbox either.

Runnir is not planned for the Mac App Store, the only channel that requires the sandbox. Comparable developer tools (Docker Desktop, OrbStack, Visual Studio Code, GitHub Desktop) ship signed with Developer ID and without it.

## Decision

- Runnir and its bundled `runnir-core` helper ship signed with Developer ID, with the hardened runtime and notarization, and without the App Sandbox. `Runnir.entitlements` and the helper's signature carry no sandbox, network, file-access or `inherit` entitlements.
- The user's own container engine and tools are used for local runs. A built-in engine for users without one may come later as a separate feature; it is not a reason to keep the sandbox.
- The Mac App Store is out of scope.

## Consequences

- **Runnir's own limits are the protection.** Without the sandbox the operating system does not contain a mistake in Runnir or the Core. The existing rules stay mandatory and are tested: read only inside the folder the user chose; refuse symlinks and `..` out of it; bound every read; never run repository code, start a run or change GitHub state without the user's confirmation (single-use confirmations in the Core); never write credentials outside the Keychain.
- **Folder access.** Security-scoped bookmarks keep working without the sandbox and stay the way Runnir remembers chosen folders, including stale-bookmark refresh and Locate. macOS privacy prompts (TCC) for protected locations such as Documents or Desktop still apply; the Core's readability probe keeps reporting a denied folder as an error, not as an empty repository.
- **Data locations.** Application Support, Logs and the temporary directory are the user's own: `~/Library/Application Support/Runnir`, `~/Library/Logs/Runnir` (`Runnir Dev` for a build made without a tag, B47; `Runnir Local` for a local build signed on a Mac, B48) and the per-user temporary directory.
- **Keychain.** With a stable Developer ID signature, Keychain access does not prompt after every rebuild. B48 adopts the data protection keychain through a Developer ID provisioning profile per app, so access follows the app's identifier and team and never prompts item by item ([B48](../superpowers/specs/2026-11-01-signing-notarization-design.md#the-data-protection-keychain)).
- **Updates** need Runnir's own signed update mechanism (planned; not affected by this decision).
- **Other clients.** The Core socket is in the per-user temporary directory, which keeps discovery for a future MCP adapter simple; access control for other clients is still required (see [MCP readiness](../architecture/mcp.md)).

## Not Yet Verified

A build signed by the release workflow from a tag. On 2026-11-04 a local build (Runnir Local) signed with Developer ID and its provisioning profile by the same scripts on a Mac, notarized and stapled (B48), passed `spctl` as Notarized Developer ID, opened from quarantine, kept its GitHub sign-in in the data protection keychain across a relaunch without a prompt, opened a chosen folder as a workspace and started its Core under the hardened runtime. Local runs with act were not tried in it.
