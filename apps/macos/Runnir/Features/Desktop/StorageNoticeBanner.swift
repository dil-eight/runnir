import AppKit
import SwiftUI

/// Says, above a workspace window's content, that the workspace's saved data
/// was recovered when it was opened (closable) or lives in memory only (it
/// stays while that lasts). The note is the Core's own.
struct StorageNoticeBanner: View {
    let notice: CoreStorageNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "externaldrive.badge.exclamationmark").font(.system(size: 14)).foregroundStyle(RunnirTheme.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.title(notice)).font(.system(size: 13, weight: .semibold))
                if !notice.note.isEmpty { Text(notice.note) }
                if let detail = Self.detail(notice) { Text(detail).foregroundStyle(RunnirTheme.secondaryForeground) }
                if let path = notice.recoveryPath {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
                    }
                    .buttonStyle(DesignButtonStyle())
                    .padding(.top, 4)
                }
            }
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if Self.canDismiss(notice) {
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(RunnirTheme.secondaryForeground).handPointer()
                    .help("Hide this notice in every window of this workspace")
                    .accessibilityLabel("Close")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(RunnirTheme.warning.opacity(0.12))
        .overlay(alignment: .bottom) { DesignDivider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storage-notice")
    }

    static func title(_ notice: CoreStorageNotice) -> String {
        notice.state == .memoryOnly ? "Runnir cannot save this workspace's data." : "Saved data of this workspace was recovered."
    }

    static func detail(_ notice: CoreStorageNotice) -> String? {
        notice.state == .memoryOnly ? "Runs, logs and local run history shown here are lost when Runnir quits." : nil
    }

    static func canDismiss(_ notice: CoreStorageNotice) -> Bool { notice.state != .memoryOnly }
}
