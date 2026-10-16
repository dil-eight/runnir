import Testing
@testable import Runnir

@MainActor
struct AppStateTests {
    @Test
    func defaultStateStartsOnDashboard() {
        let state = AppState()

        #expect(state.selectedSection == .dashboard)
        #expect(state.authenticationState == .unknown)
    }
}
