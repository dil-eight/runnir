# 0008 Apache License 2.0

Status: accepted, 2026-11-04.

## Context

The repository started with GPLv3 in `LICENSE`, while the product brief proposed Apache-2.0, and the choice was left open until a release. The first alpha, a signed build anyone can download, needs the license settled. Every commit so far is the maintainer's, so the license can still change without asking other authors.

## Decision

- Runnir is licensed under the Apache License 2.0. `LICENSE` holds its text, unchanged from apache.org.
- Contributions are accepted under the same license, as the license's section 5 says; there is no separate contributor agreement.
- The bundled and linked third-party code keeps its own licenses: act and the Core's Go modules (MIT, BSD, Apache-2.0) and the app's Swift packages (Apache-2.0). Their license texts and NOTICE files ship with each release.

## Consequences

- Anyone may use, change and redistribute Runnir, also in closed or paid products, keeping the license and its notices; a fork does not have to publish its changes. The license's patent grant protects users and contributors.
- Companies whose rules exclude copyleft licenses can use and contribute to Runnir.
- A paid edition or a Mac App Store build stays possible.
- Before the first release tag the app and the Core binaries must carry the third-party notices: today only act's license ships, in `Contents/Resources/Licenses`.
