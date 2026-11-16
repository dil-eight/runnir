import SwiftUI

/// Asks, in Runnir's own dialog over a workspace window, whether an MCP
/// client may run macOS jobs on this Mac without the macOS sandbox
/// (docs/superpowers/specs/2026-11-09-mcp-full-control-design.md). Only Run
/// starts them; a click outside does nothing, and Escape cancels.
struct McpRunPanel: View {
    let prompt: McpUnsandboxedPrompt

    var body: some View {
        panel.accessibilityIdentifier("mcp-unsandboxed-run")
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 14)).foregroundStyle(RunnirTheme.destructive)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Run macOS jobs without the sandbox?").font(.system(size: 14, weight: .semibold))
                    Text("\(prompt.client) asks to run \(prompt.jobs.joined(separator: ", ")) of \(prompt.workspace.name) on this Mac without the macOS sandbox, for this run only.")
                        .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            DesignDivider()
            Text(LocalRunSheet.unsandboxedWarning)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .background(RunnirTheme.destructive.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 20).padding(.vertical, 14)
            DesignDivider()
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { prompt.cancel() }
                    .buttonStyle(DesignButtonStyle())
                Button("Run Without Sandbox") { prompt.run() }
                    .buttonStyle(DesignButtonStyle(primary: true))
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 560)
        .background(RunnirTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RunnirTheme.border))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
    }
}

extension View {
    /// The questions of MCP clients in this window, in Runnir's own dialog
    /// over everything in it, Settings included. Escape cancels them.
    func mcpPrompts(desktop: DesktopCoordinator, windowID: UUID) -> some View {
        let values = desktop.mcpPrompt.flatMap { $0.windowID == windowID ? $0 : nil }
        let run = desktop.mcpRunPrompt.flatMap { $0.windowID == windowID ? $0 : nil }
        return dialog(isPresented: Binding(get: { values != nil }, set: { if !$0 { values?.cancel() } })) {
            if let values { McpValuesPanel(prompt: values, store: desktop.localRunValues) }
        }
        .dialog(isPresented: Binding(get: { run != nil }, set: { if !$0 { run?.cancel() } })) {
            if let run { McpRunPanel(prompt: run) }
        }
    }
}
