import Foundation

/// Polls a main-actor condition for up to four seconds.
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

/// Polls an asynchronous condition for up to ten seconds.
func eventuallyAsync(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<500 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}
