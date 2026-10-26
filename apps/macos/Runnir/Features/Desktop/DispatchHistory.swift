import Foundation

/// What the Run Workflow sheet shows of the dispatches already sent from this
/// Mac: one line each, what is left out, and a comparison of two.
enum DispatchHistory {
    static let maxShownInputs = 3
    static let maxSummaryLength = 40

    /// "dry_run=false, environment=staging" in name order; "no inputs" for none.
    static func summary(_ record: CoreDispatchRecord) -> String {
        guard !record.inputs.isEmpty else { return "no inputs" }
        let pairs = record.inputs.sorted { $0.key < $1.key }
        let shown = pairs.prefix(maxShownInputs).map { "\($0.key)=\(shortened($0.value))" }
        let more = pairs.count - shown.count
        return shown.joined(separator: ", ") + (more > 0 ? " +\(more) more" : "")
    }

    private static func shortened(_ value: String) -> String {
        value.count > 20 ? String(value.prefix(19)) + "…" : value
    }

    /// Which inputs were not kept, or nil when all were.
    static func leftOut(_ record: CoreDispatchRecord) -> String? {
        guard !record.omittedInputs.isEmpty else { return nil }
        let names = record.omittedInputs.joined(separator: ", ")
        return record.omittedInputs.count == 1 ? "Left out because it looks secret: \(names)"
                                               : "Left out because they look secret: \(names)"
    }

    /// How long ago an entry was sent, from `now`.
    static func age(of record: CoreDispatchRecord, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: record.sentAt, relativeTo: now)
    }

    /// A menu line: when, the branch or tag and the values.
    static func menuTitle(_ record: CoreDispatchRecord, now: Date = Date()) -> String {
        let when = age(of: record, now: now)
        let summary = summary(record)
        return "\(when) · \(record.ref) · \(summary.count > maxSummaryLength ? String(summary.prefix(maxSummaryLength - 1)) + "…" : summary)"
    }

    struct Difference: Equatable, Identifiable {
        let name: String
        /// nil when the first entry did not send this input.
        let first: String?
        let second: String?
        var id: String { name }
        var changed: Bool { first != second }
    }

    static let branchRowName = "Branch or tag"

    /// The branch or tag, then every input either entry sent, in name order.
    static func compare(_ first: CoreDispatchRecord, _ second: CoreDispatchRecord) -> [Difference] {
        var rows = [Difference(name: branchRowName, first: first.ref, second: second.ref)]
        for name in Set(first.inputs.keys).union(second.inputs.keys).sorted() {
            rows.append(Difference(name: name, first: first.inputs[name], second: second.inputs[name]))
        }
        return rows
    }

    static func changedCount(_ rows: [Difference]) -> Int { rows.count { $0.changed } }

    /// The entry as a preset, so the form applies it the way it applies one:
    /// the branch, then the values, saying what no longer fits.
    static func preset(from record: CoreDispatchRecord, workspaceID: UUID) -> DispatchPreset {
        DispatchPreset(id: UUID(), name: "Sent " + record.sentAt.formatted(date: .abbreviated, time: .shortened), workspaceID: workspaceID,
                       workflowPath: record.workflowPath, ref: record.ref, inputs: record.inputs, updatedAt: record.sentAt)
    }
}
