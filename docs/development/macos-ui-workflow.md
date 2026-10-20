# macOS UI Development And Component Catalog

Status: development guidance, updated 2026-10-15. DesktopViews.swift now contains named empty-Manager and splash #Preview declarations; neither starts persistence, GitHub or the helper. A populated fixture catalog and separate catalog target remain planned. No Storybook package is installed.

## Run On My Mac

Open apps/macos/Runnir.xcodeproj, select scheme Runnir and destination My Mac, then use Product > Run (Command-R). The macOS app runs directly on the development Mac; everyday development does not require an iOS-style macOS simulator.

Use breakpoints and the debugger for real application flows. Test GitHub mutations against a controlled repository and local workflow execution against explicit fixtures. Other macOS versions require appropriate separate environments, such as another Mac or a supported VM; cross-compilation alone does not test runtime behavior.

## Fast Visual Iteration

Use named SwiftUI #Preview declarations beside components/screens and Xcode's preview canvas for layout, appearance and isolated interactions. Xcode can update previews as view code changes; previews still depend on compilable code and a working build environment. Do not promise instant updates for every change.

Preview updates are distinct from hot-reloading a running production-style app. The baseline workflow for a full app code change remains build/run; do not rely on preserving application state across restarts. No code-injection or hot-reload package is required.

Source: [Apple: Previews in Xcode](https://developer.apple.com/documentation/swiftui/previews-in-xcode).

## Runnir Preview Conventions

Use the stable Sxx/Cxx state references from the [design plan](../design/README.md) when mapping approved screens/components to preview fixtures. The [screen/state matrix](../design/screens-and-states.md) defines representative scenarios, not an existing preview implementation.

Use deterministic fixture data and injected small protocol-backed services. Previews must not authenticate, read real Keychain tokens, access user repositories, call GitHub, launch the Go helper or execute tools/workflows automatically. Inject dependencies before presentation; merely detecting preview mode is not a substitute for isolation.

Name scenarios by feature and state, such as Repositories / Loading or Workflow Inputs / Invalid. Cover applicable loading, empty, populated, failure, permission-denied and long-content states. Check light/dark appearance, supported window sizes and accessibility. Interactive previews can exercise local form/selection state with fakes.

Preview fixtures are development data, not seeded production state. Keep source/log examples synthetic and non-secret. Verify Keychain, IPC, file permissions, process lifecycle and folder access in the actual app and relevant signed configuration; a preview is not evidence of integration correctness.

## Storybook-Style Options

| Option | Use | Runnir direction |
| --- | --- | --- |
| Native #Preview groups | Named component/screen states in Xcode | Default starting point; no external dependency |
| Small native UI catalog | Browse shared components and feature scenarios in one macOS window | Add only when repeated UI work justifies it; separate development target/scheme with fake services |
| swift-storybook / StorybookKit | Package that discovers #Preview declarations and displays an in-app catalog; its README documents macOS 14+ hosting | Evaluation candidate, not installed or verified in Runnir |

The package is a native Swift option, independent of the web Storybook stack. Its documented limitations include unsupported grouped/parameterized preview content and possible linker configuration for static-library discovery. Review the pinned version, license, dependencies and Xcode compatibility before adoption. A catalog organizes scenarios; it does not itself promise hot reload.

Source: [swift-storybook README](https://github.com/eure/swift-storybook).

## Proposed Native Catalog Scope

When needed, start with shared empty/error/loading states, repository rows, workflow input fields, run status, validation diagnostics and log presentation. Add whole-screen scenarios after reusable components. Reuse the same fixture factories as previews where practical.

Prefer a separate development host that composes views with fakes and skips RunnirApp's live startup handshake. Keep catalog entry points and fixtures out of the shipped product; a hidden menu alone does not exclude development code from release builds. This is supporting development tooling, not a new user-facing v0.1 feature or release gate.

## Window/Offline Development Scenarios

The [desktop lifecycle](../architecture/desktop-lifecycle.md) adds real-app scenarios beyond preview coverage: manual close versus Cmd+Q, Dock activation with no windows, same repo in independent windows, missing monitors and durable session recovery. Preview the proposed Manager/Splash/recovery/environment states with synthetic registry/cache/config and a fake sync service; previews must not restore actual sessions or open local databases/grants.

## Verification

Inspect visuals in previews/catalog, then exercise actual integration flows in the app. Previews and screenshots do not replace unit/UI tests. For code changes, run the build/test commands in AGENTS.md and Core checks when Go changes. Documentation-only updates do not require a rebuild.
