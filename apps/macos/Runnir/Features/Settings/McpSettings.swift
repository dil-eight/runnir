import AppKit
import SwiftUI

/// How an MCP client starts Runnir's MCP server: the Core binary inside this
/// app with this build's data folder, so each build answers its own clients
/// (docs/superpowers/specs/2026-11-08-mcp-value-sets-design.md).
enum McpSettings {
    /// The server's name in a client: one per build, so Runnir Dev and an
    /// installed Runnir can both be added.
    static func serverName(for build: RunnirBuild) -> String {
        switch build {
        case .dev: "runnir-dev"
        case .local: "runnir-local"
        case .alpha, .beta, .release: "runnir"
        }
    }

    static var helper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/runnir-core") }

    /// Settings › MCP › Allow actions: agents may start, stop, dispatch,
    /// cancel, re-run and save values. On unless the user turned it off.
    static let allowActionsKey = "mcp.allowActions"

    static var allowActions: Bool { UserDefaults.standard.object(forKey: allowActionsKey) as? Bool ?? true }

    /// Where the Runnir plugin (plugins/runnir) starts the server: the same
    /// for every user, so only Runnir in /Applications is reached by it.
    static let pluginHelper = "/Applications/Runnir.app/Contents/Helpers/runnir-core"

    /// The plugin serves the builds of a tag, one app, in /Applications.
    static func pluginReaches(build: RunnirBuild, helper: String) -> Bool {
        [.alpha, .beta, .release].contains(build) && helper == pluginHelper
    }

    /// The Runnir plugin from its marketplace, this repository on GitHub.
    static let claudePluginCommands = "claude plugin marketplace add dil-eight/runnir\nclaude plugin install runnir@runnir"
    static let codexPluginCommands = "codex plugin marketplace add dil-eight/runnir\ncodex plugin add runnir@runnir"

    /// `claude mcp add` for Claude Code in every project, the path quoted
    /// for the shell. The Core finds this build's data folder itself.
    static func claudeCommand(name: String, helper: String) -> String {
        "claude mcp add --scope user \(name) -- \(shellQuoted(helper)) mcp"
    }

    /// The block for Codex's ~/.codex/config.toml. Codex waits 60 seconds
    /// for a tool by default, less than a person may take to confirm.
    static func codexBlock(name: String, helper: String) -> String {
        """
        [mcp_servers.\(name)]
        command = \(tomlQuoted(helper))
        args = ["mcp"]
        tool_timeout_sec = 300
        """
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func tomlQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Settings › MCP: whether MCP clients can reach Runnir, and how to add it
/// to Claude Code and Codex.
struct McpSettingsSection: View {
    let hub: CoreHub?
    @State private var copied: String?
    @AppStorage(McpSettings.allowActionsKey) private var allowActions = true

    private var dataDir: String? { try? RunnirSupportDirectory.url().path }
    private var name: String { McpSettings.serverName(for: .current) }

    var body: some View {
        Section("MCP clients") {
            status
            Text("Claude Code, Codex and other MCP clients can read your workspaces' workflows, what a scenario starts, runs on GitHub with their jobs and logs, and local runs, and list the values local runs read.")
                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $allowActions) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow actions")
                    Text("Agents can also start and stop local runs, start workflows on GitHub, cancel and re-run runs, and ask to save values, without a click. Runnir still asks you in the workspace's window before saving values and before running macOS jobs without the sandbox. Off: agents can only read.")
                        .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .handPointer()
        }
        if McpSettings.pluginReaches(build: .current, helper: McpSettings.helper.path) {
            Section("Claude Code") {
                snippet(McpSettings.claudePluginCommands, id: "claude",
                        caption: "Run in a terminal. Installs the Runnir plugin in every project: these tools and a skill on using them.")
            }
            Section("Codex") {
                snippet(McpSettings.codexPluginCommands, id: "codex",
                        caption: "Run in a terminal with the Codex CLI. Installs the Runnir plugin.")
            }
        } else {
            Section("Claude Code") {
                snippet(McpSettings.claudeCommand(name: name, helper: McpSettings.helper.path), id: "claude",
                        caption: "Run in a terminal. Adds these tools in every project.")
            }
            Section("Codex") {
                snippet(McpSettings.codexBlock(name: name, helper: McpSettings.helper.path), id: "codex",
                        caption: "Add to ~/.codex/config.toml.")
            }
        }
        Section("Secrets") {
            Text("A secret you give an agent passes through it and its model before it reaches Runnir. Runnir keeps it in Keychain on this Mac and never returns it to a client; only names and variables' values are listed.")
                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var status: some View {
        let listening = dataDir.map { FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent("mcp.sock")) } ?? false
        HStack(spacing: 8) {
            Image(systemName: listening ? "checkmark.circle.fill" : "exclamationmark.triangle")
                .foregroundStyle(listening ? RunnirTheme.success : RunnirTheme.warning)
            Text(listening ? "MCP clients can reach Runnir while it runs."
                 : hub?.status.coreVersion == nil ? "Runnir Core is not running, so MCP clients cannot reach Runnir."
                 : "Another copy of this Runnir serves MCP clients, or its folder's path is too long for a socket.")
                .font(.system(size: 12))
        }
    }

    private func snippet(_ text: String, id: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(copied == id ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = id
                }
                .buttonStyle(DesignButtonStyle(compact: true))
            }
            Text(caption).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
        }
    }
}
