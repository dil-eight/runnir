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
- **Data locations.** Application Support, Logs and the temporary directory are the user's own: `~/Library/Application Support/Runnir`, `~/Library/Logs/Runnir` and the per-user temporary directory.
- **Keychain.** With a stable Developer ID signature, Keychain access does not prompt after every rebuild; the data-protection keychain can be adopted with the team ID as part of signing work.
- **Updates** need Runnir's own signed update mechanism (planned; not affected by this decision).
- **Other clients.** The Core socket is in the per-user temporary directory, which keeps discovery for a future MCP adapter simple; access control for other clients is still required (see [MCP readiness](../architecture/mcp.md)).

## Not Yet Verified

A Developer ID signed, notarized build. Until then the claims above rest on unsigned and ad-hoc signed builds.
