import SwiftUI

/// Asks, in Runnir's own dialog over a workspace window, whether to save the
/// values an MCP client sent
/// (docs/superpowers/specs/2026-11-08-mcp-value-sets-design.md). Only Save
/// writes Keychain; a click outside does nothing, so the change is never
/// decided by accident, and Escape cancels until the save starts.
struct McpValuesPanel: View {
    let prompt: McpValuesPrompt
    let store: any LocalRunValueStoring

    var body: some View {
        panel.accessibilityIdentifier("mcp-values")
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            DesignDivider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(prompt.rows) { row in
                        McpValueRowView(row: row, toggle: { prompt.toggleShown(row.name) })
                        if row.id != prompt.rows.last?.id { DesignDivider() }
                    }
                }
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            DesignDivider()
            Text("Secret values given to an agent pass through it and its model. Runnir keeps them in Keychain on this Mac and never sends them back.")
                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20).padding(.vertical, 10)
            DesignDivider()
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { prompt.cancel() }
                    .buttonStyle(DesignButtonStyle())
                    .disabled(prompt.isSaving)
                Button(prompt.isSaving ? "Saving…" : "Save") { Task { await prompt.save(store: store) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(DesignButtonStyle(primary: true))
                    .disabled(prompt.isSaving)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 560)
        .background(RunnirTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(RunnirTheme.border))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "key.horizontal").font(.system(size: 14)).foregroundStyle(RunnirTheme.primary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Save values for local runs?").font(.system(size: 14, weight: .semibold))
                Text("\(prompt.client) asks to save \(McpValuesPanel.count(prompt.rows)) into \(prompt.workspace.name) › \(prompt.setName).")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    /// "2 secrets and 1 variable".
    static func count(_ rows: [McpValuesPrompt.Row]) -> String {
        let secrets = rows.filter { $0.kind == .secret }.count
        let variables = rows.count - secrets
        var parts: [String] = []
        if secrets > 0 { parts.append("\(secrets) \(secrets == 1 ? "secret" : "secrets")") }
        if variables > 0 { parts.append("\(variables) \(variables == 1 ? "variable" : "variables")") }
        return parts.joined(separator: " and ")
    }
}

private struct McpValueRowView: View {
    let row: McpValuesPrompt.Row
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(row.kind == .secret ? "Secret" : "Variable")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(RunnirTheme.secondaryForeground)
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text(row.shown ? row.value : String(repeating: "•", count: 10))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(RunnirTheme.secondaryForeground)
                    .lineLimit(2).truncationMode(.middle)
                    .textSelection(.disabled)
                if row.replaces {
                    Text("Replaces the saved value").font(.system(size: 11)).foregroundStyle(RunnirTheme.warning)
                }
            }
            Spacer(minLength: 8)
            if row.kind == .secret {
                Button(row.shown ? "Hide" : "Show", action: toggle)
                    .buttonStyle(DesignButtonStyle(compact: true))
                    .accessibilityLabel(row.shown ? "Hide \(row.name)" : "Show \(row.name)")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }
}
