# 0001 Native macOS SwiftUI

## Decision

Build Runnir as a native macOS application using Swift 6, SwiftUI, Observation, Foundation networking, and Keychain Services.

## Rationale

The product brief prioritizes native macOS behavior, low resource usage, secure credential handling, and minimal dependencies.

## Consequences

- No Electron, Tauri, Node.js, npm, pnpm, React, Rust, CocoaPods, or Carthage.
- GitHub integration uses official REST APIs through `URLSession`.
- CI runs on macOS GitHub-hosted runners.
