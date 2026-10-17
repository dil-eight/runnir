import XCTest

final class RunnirUITests: XCTestCase {
    @MainActor func testAppLaunchesAndShowsWorkspaceManager() {
        let app = XCUIApplication()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["RUNNIR_UI_TEST_STATE_DIRECTORY"] = directory.path
        app.launch()

        let managerReady = app.buttons["Import Repository..."].waitForExistence(timeout: 10)
        XCTAssertTrue(managerReady)
    }
}
