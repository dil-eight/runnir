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

    /// `claude mcp add` for Claude Code, paths quoted for the shell.
    static func claudeCommand(name: String, helper: String, dataDir: String) -> String {
        "claude mcp add \(name) -- \(shellQuoted(helper)) mcp --data-dir \(shellQuoted(dataDir))"
    }

    /// The block for Codex's ~/.codex/config.toml. Codex waits 60 seconds
    /// for a tool by default, less than a person may take to confirm.
    static func codexBlock(name: String, helper: String, dataDir: String) -> String {
        """
        [mcp_servers.\(name)]
        command = \(tomlQuoted(helper))
        args = ["mcp", "--data-dir", \(tomlQuoted(dataDir))]
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

    private var dataDir: String? { try? RunnirSupportDirectory.url().path }
    private var name: String { McpSettings.serverName(for: .current) }

    var body: some View {
        Section("MCP clients") {
            status
            Text("Claude Code, Codex and other MCP clients can list the secrets and variables local runs of a workspace read, and save values into one of its sets. Runnir asks you to confirm every change in the workspace's window.")
                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let dataDir {
            Section("Claude Code") {
                snippet(McpSettings.claudeCommand(name: name, helper: McpSettings.helper.path, dataDir: dataDir), id: "claude",
                        caption: "Run in a terminal; add --scope user to use it in every project.")
            }
            Section("Codex") {
                snippet(McpSettings.codexBlock(name: name, helper: McpSettings.helper.path, dataDir: dataDir), id: "codex",
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
