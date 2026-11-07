import XCTest

final class RunnirUITests: XCTestCase {
    private var directory: URL!
    private var state: URL { directory.appendingPathComponent("state") }
    private var repository: URL { directory.appendingPathComponent("ui-repo") }

    override func setUpWithError() throws {
        continueAfterFailure = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor func testAppLaunchesAndShowsWorkspaceManager() {
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Import Repository..."].waitForExistence(timeout: 10))
    }

    /// L02, L03: windows open at quit come back with their identities; a
    /// window closed by hand does not; with none left the Manager opens.
    @MainActor func testQuitRestoresOpenWindowsAndAManualCloseIsKept() throws {
        try makeRepository()
        var app = launch(importing: repository)
        XCTAssertTrue(workspaceWindows(app).firstMatch.waitForExistence(timeout: 15))
        try openSecondWindow(app)
        XCTAssertEqual(workspaceWindows(app).count, 2)
        let saved = try windowIDs()
        XCTAssertEqual(saved.count, 2)

        quit(app)
        app = launch()
        XCTAssertTrue(waitFor(2, in: app))
        XCTAssertEqual(try windowIDs(), saved, "the same windows come back")

        // Close the window in front by hand, then quit: only the other returns.
        closeFrontWindow(app)
        XCTAssertTrue(waitFor(1, in: app))
        let remaining = try windowIDs()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(saved.isSuperset(of: remaining))
        quit(app)
        app = launch()
        XCTAssertTrue(waitFor(1, in: app))
        XCTAssertEqual(try windowIDs(), remaining)

        // The last window closed by hand: the next launch shows the Manager.
        closeFrontWindow(app)
        XCTAssertTrue(waitFor(0, in: app))
        XCTAssertTrue(try windowIDs().isEmpty)
        quit(app)
        app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Import Repository..."].waitForExistence(timeout: 10))
        XCTAssertEqual(workspaceWindows(app).count, 0)
    }

    /// L06: two windows of one workspace keep their own section.
    @MainActor func testTwoWindowsOfOneWorkspaceKeepTheirOwnSection() throws {
        try makeRepository()
        let app = launch(importing: repository)
        defer { app.terminate() }
        XCTAssertTrue(workspaceWindows(app).firstMatch.waitForExistence(timeout: 15))
        try openSecondWindow(app)
        XCTAssertEqual(workspaceWindows(app).count, 2)

        let front = workspaceWindows(app).firstMatch
        let runs = front.buttons["Runs"].firstMatch
        XCTAssertTrue(runs.waitForExistence(timeout: 5))
        runs.click()
        let sections = expectation(description: "one window on Runs, the other on Overview")
        for _ in 0..<50 {
            if let saved = try? sectionsByWindow(), saved.sorted() == ["dashboard", "runs"] { sections.fulfill(); break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        wait(for: [sections], timeout: 1)
    }

    // MARK: Helpers

    @MainActor private func launch(importing folder: URL? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["RUNNIR_UI_TEST_STATE_DIRECTORY"] = state.path
        if let folder { app.launchEnvironment["RUNNIR_UI_TEST_IMPORT_PATHS"] = folder.path }
        app.launch()
        return app
    }

    /// Quits through the app menu, as Cmd+Q does, so the app saves its
    /// session. Keystrokes do not reach the menus in a UI test run.
    @MainActor private func quit(_ app: XCUIApplication) {
        app.menuBars.menuBarItems.element(boundBy: 1).click()
        app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Quit '")).firstMatch.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 20), "the app did not quit")
    }

    /// Closes the window in front by hand, as Cmd+W does.
    @MainActor private func closeFrontWindow(_ app: XCUIApplication) {
        workspaceWindows(app).firstMatch.click()
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Close"].click()
    }

    @MainActor private func workspaceWindows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.windows.matching(NSPredicate(format: "title ENDSWITH %@", "ui-repo - Runnir"))
    }

    @MainActor private func waitFor(_ count: Int, in app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if workspaceWindows(app).count == count { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// Opens the Manager (File › Open Workspace...) and its row's Open New Window.
    @MainActor private func openSecondWindow(_ app: XCUIApplication) throws {
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Open Workspace..."].click()
        let manager = app.windows["Workspaces"]
        XCTAssertTrue(manager.waitForExistence(timeout: 10))
        let actions = manager.buttons["Workspace actions"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.click()
        let item = app.buttons["Open New Window"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        XCTAssertTrue(waitFor(2, in: app))
    }

    private func savedState() throws -> [String: Any] {
        let data = try Data(contentsOf: state.appendingPathComponent("desktop-state.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func windowIDs() throws -> Set<String> {
        let windows = try XCTUnwrap(savedState()["windows"] as? [[String: Any]])
        return Set(windows.compactMap { $0["id"] as? String })
    }

    private func sectionsByWindow() throws -> [String] {
        let windows = try XCTUnwrap(savedState()["windows"] as? [[String: Any]])
        return windows.map { ($0["section"] as? String) ?? "dashboard" }
    }

    private func makeRepository() throws {
        let workflows = repository.appendingPathComponent(".github/workflows")
        try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
        try Data("name: CI\non: push\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n".utf8)
            .write(to: workflows.appendingPathComponent("ci.yml"))
        // The runner is sandboxed and cannot start git; an empty repository
        // is these files, as `git init` writes them.
        let git = repository.appendingPathComponent(".git")
        for folder in ["objects", "refs/heads", "refs/tags"] {
            try FileManager.default.createDirectory(at: git.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data("ref: refs/heads/main\n".utf8).write(to: git.appendingPathComponent("HEAD"))
        try Data("[core]\n\trepositoryformatversion = 0\n\tbare = false\n".utf8).write(to: git.appendingPathComponent("config"))
    }
}
