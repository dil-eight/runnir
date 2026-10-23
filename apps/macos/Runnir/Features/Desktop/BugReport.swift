import AppKit
import SwiftUI

/// A bug report for Runnir's public repository: the sections of
/// .github/ISSUE_TEMPLATE/bug_report.md with the environment filled in.
/// Nothing from the user's repositories, paths or accounts goes in it.
struct BugReportDraft: Equatable {
    static let newIssue = URL(string: "https://github.com/dil-eight/runnir/issues/new")!

    let appVersion: String
    let coreVersion: String?
    let macOSVersion: String
    let architecture: String

    static func current(coreVersion: String?, bundle: Bundle = .main) -> BugReportDraft {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return BugReportDraft(appVersion: build.map { "\(version) (\($0))" } ?? version, coreVersion: coreVersion,
                              macOSVersion: "\(os.majorVersion).\(os.minorVersion)", architecture: architecture)
    }

    var title: String { "[Bug] " }

    /// The environment lines, as the template names them.
    var environment: [String] {
        ["- Runnir version/build: \(appVersion)",
         "- Core version (if known): \(coreVersion ?? "unknown")",
         "- macOS major/minor version: \(macOSVersion)",
         "- Architecture (arm64/amd64): \(architecture)"]
    }

    var body: String {
        """
        ## Summary

        Describe the problem without repository names, source code, workflow YAML, logs, secrets or personal data.

        ## Steps To Reproduce

        Use a minimal synthetic example or describe UI actions. Do not paste private project content.

        ## Expected And Actual Behavior

        Expected:

        Actual:

        ## Environment

        \(environment.joined(separator: "\n"))

        ## Privacy Check

        - [ ] I reviewed this report and removed repository content, secrets and personal data.
        - [ ] I understand that this issue and my GitHub identity will be public.

        For suspected security vulnerabilities, follow SECURITY.md instead of publishing details here.
        """
    }

    /// The new-issue page with title and body filled in.
    var url: URL {
        var components = URLComponents(url: Self.newIssue, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
        return components.url!
    }
}

/// Shows what a bug report will contain before it opens on GitHub.
struct BugReportSheet: View {
    let draft: BugReportDraft
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Report a Bug").font(.system(size: 15, weight: .semibold))
            Text("Runnir opens a new issue in its public GitHub repository in your browser, with these details filled in. Nothing is sent before you open it; once you submit it, the issue and your GitHub name are public.")
                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(draft.environment, id: \.self) { line in
                    Text(line).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 6))
            Text("Describe the problem there without repository names, code, logs or secrets. Security problems go through SECURITY.md, not a public issue.")
                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Copy Details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(draft.environment.joined(separator: "\n"), forType: .string)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open on GitHub") {
                    openURL(draft.url)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(DesignButtonStyle(primary: true))
            }
            .buttonStyle(DesignButtonStyle())
        }
        .padding(20).frame(width: 460)
    }
}
