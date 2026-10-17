import SwiftUI

struct AuthenticationView: View {
    var body: some View {
        EmptyStateView(
            title: "GitHub authentication is not configured",
            message: "Create a GitHub OAuth or device-flow application, then wire its client identifier into the authentication service.",
            systemImage: "person.crop.circle.badge.exclamationmark"
        )
    }
}
