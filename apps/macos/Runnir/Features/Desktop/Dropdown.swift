import SwiftUI

// Runnir's own dropdowns, as drawn in Pen: an opaque panel under its button,
// with a border, rounded corners and a shadow; no arrow and no system
// material. Every list of actions or choices behind a button uses these,
// never SwiftUI's Menu, a popover or a menu-style Picker:
//
// - DropdownMenu: a button that opens DropdownItems.
// - DropdownPicker: a choice among values, the chosen one on the button.
// - .dropdown(isPresented:): any content in the panel, for panels of their own.
// - DropdownPrompt: a question in the panel (a name to save, a removal to
//   confirm) instead of a system alert or confirmation dialog.
// - .hoverTip(_:): a panel under a view while the pointer rests on it, which
//   never takes a click.
// - .dropdownHost(): at the root of every window and sheet; it draws the open
//   panel above everything, so a list or a scroll view never clips it.

extension View {
    /// The panel's look.
    func dropdownPanelStyle() -> some View {
        background(RunnirTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(RunnirTheme.border))
            .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
    }

    /// Shows `content` in the panel under this view while `isPresented`, its
    /// leading or trailing edge lined up with the view's.
    func dropdown<Content: View>(isPresented: Binding<Bool>, alignment: HorizontalAlignment = .leading,
                                 @ViewBuilder content: @escaping () -> Content) -> some View {
        let presented = isPresented.wrappedValue
        return anchorPreference(key: DropdownKey.self, value: .bounds) { anchor in
            presented ? DropdownRequest(anchor: anchor, trailing: alignment == .trailing, passive: false, content: AnyView(content()),
                                        close: { isPresented.wrappedValue = false }) : nil
        }
    }

    /// Shows `tip` in the panel under this view once the pointer has rested
    /// on it for a moment, until it leaves. Clicks go through to the view.
    func hoverTip<Tip: View>(@ViewBuilder _ tip: @escaping () -> Tip) -> some View {
        modifier(HoverTip(tip: tip))
    }

    /// Draws the open dropdown of a view inside this one. A click outside
    /// the panel or Escape closes it, and the click does nothing else, as
    /// with a menu.
    func dropdownHost() -> some View { modifier(DropdownHost()) }
}

private struct DropdownRequest {
    let anchor: Anchor<CGRect>
    let trailing: Bool
    /// A tip: drawn only, without catching clicks or Escape.
    let passive: Bool
    let content: AnyView
    let close: @MainActor () -> Void
}

private struct DropdownKey: PreferenceKey {
    static var defaultValue: DropdownRequest? { nil }
    static func reduce(value: inout DropdownRequest?, nextValue: () -> DropdownRequest?) { value = value ?? nextValue() }
}

enum DropdownPlacement {
    static let gap: CGFloat = 4
    /// The least room between a panel and the window's side.
    static let margin: CGFloat = 8

    /// The panel's top: under the button, or above it when the panel fits
    /// there and not under it.
    static func top(button: CGRect, panelHeight: CGFloat, space: CGFloat) -> CGFloat {
        let below = button.maxY + gap
        let above = button.minY - gap - panelHeight
        return below + panelHeight > space && above >= 0 ? above : below
    }

    /// How far the panel moves sideways from the button's edge it lines up
    /// with, so that it stays inside the window: left from the right side,
    /// right from the left one.
    static func shift(button: CGRect, panelWidth: CGFloat, space: CGFloat, trailing: Bool) -> CGFloat {
        let left = trailing ? button.maxX - panelWidth : button.minX
        return max(margin, min(left, space - margin - panelWidth)) - left
    }
}

private struct DropdownHost: ViewModifier {
    @State private var panelSize: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(DropdownKey.self) { request in
                if let request {
                    GeometryReader { proxy in
                        let button = proxy[request.anchor]
                        ZStack(alignment: .topLeading) {
                            if !request.passive {
                                // No hand pointer: a click outside the panel closes it.
                                Color.clear.contentShape(Rectangle()).onTapGesture(perform: request.close).accessibilityHidden(true)
                            }
                            request.content
                                .environment(\.dismissDropdown, DropdownDismiss(action: request.close))
                                .dropdownPanelStyle()
                                .fixedSize()
                                .onGeometryChange(for: CGSize.self) { $0.size } action: { panelSize = $0 }
                                // A dropdown inside the panel opens over it.
                                .modifier(DropdownHost())
                                .frame(width: request.trailing ? button.maxX : nil, alignment: .topTrailing)
                                .offset(x: (request.trailing ? 0 : button.minX)
                                            + DropdownPlacement.shift(button: button, panelWidth: panelSize.width, space: proxy.size.width,
                                                                      trailing: request.trailing),
                                        y: DropdownPlacement.top(button: button, panelHeight: panelSize.height, space: proxy.size.height))
                                .allowsHitTesting(!request.passive)
                            if !request.passive {
                                Button("Close", action: request.close)
                                    .keyboardShortcut(.cancelAction).buttonStyle(.hit).opacity(0).frame(width: 0, height: 0)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
            }
            // An outer host does not draw this host's dropdown again.
            .transformPreference(DropdownKey.self) { $0 = nil }
    }
}

/// Shows a tip after the pointer rests on the view, hides it when it leaves.
private struct HoverTip<Tip: View>: ViewModifier {
    let tip: () -> Tip
    @State private var shown = false
    @State private var wait: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                wait?.cancel()
                guard inside else {
                    shown = false
                    return
                }
                wait = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    if !Task.isCancelled { shown = true }
                }
            }
            .onDisappear { wait?.cancel() }
            .anchorPreference(key: DropdownKey.self, value: .bounds) { anchor in
                shown ? DropdownRequest(anchor: anchor, trailing: false, passive: true, content: AnyView(tip().accessibilityHidden(true)),
                                        close: {}) : nil
            }
    }
}

/// What a tip says: a title, then lines of detail. A job's tip has its full
/// name, how it starts, its condition, environment, status and needs.
struct TipCard: View {
    let title: String
    let detail: String

    var body: some View {
        UpToWidth(maxWidth: 316) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(RunnirTheme.foreground)
                ForEach(Array(detail.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

/// Gives its content the width it wants, up to `maxWidth`: a short tip stays
/// narrow and a long one wraps.
private struct UpToWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        return content.sizeThatFits(width(of: content))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if let content = subviews.first { content.place(at: bounds.origin, proposal: width(of: content)) }
    }

    private func width(of content: LayoutSubview) -> ProposedViewSize {
        ProposedViewSize(width: min(content.sizeThatFits(.unspecified).width, maxWidth), height: nil)
    }
}

/// Closes the dropdown a view is in; DropdownItem calls it after its action.
struct DropdownDismiss {
    let action: @MainActor () -> Void
    @MainActor func callAsFunction() { action() }
}

private struct DropdownDismissKey: EnvironmentKey {
    static var defaultValue: DropdownDismiss { DropdownDismiss {} }
}

extension EnvironmentValues {
    var dismissDropdown: DropdownDismiss {
        get { self[DropdownDismissKey.self] }
        set { self[DropdownDismissKey.self] = newValue }
    }
}

/// The rows of a dropdown, padded as drawn; past `maxHeight` they scroll.
struct DropdownList<Content: View>: View {
    var minWidth: CGFloat = 200
    var maxHeight: CGFloat = 360
    @ViewBuilder let content: () -> Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(6)
                .frame(minWidth: minWidth, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .frame(height: min(max(height, 1), maxHeight))
    }
}

/// A row of a dropdown: highlighted under the pointer, red when it removes
/// something, dimmed when disabled. With `checked` it has a check column;
/// a `detail` sits dimmed at its trailing edge; a `monospaced` title is a
/// path or a name from code.
struct DropdownItem: View {
    let title: String
    var systemImage: String?
    var detail: String?
    var monospaced = false
    var checked: Bool?
    var destructive = false
    let action: () -> Void
    @Environment(\.dismissDropdown) private var dismiss
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    init(_ title: String, systemImage: String? = nil, detail: String? = nil, monospaced: Bool = false, checked: Bool? = nil,
         destructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
        self.monospaced = monospaced
        self.checked = checked
        self.destructive = destructive
        self.action = action
    }

    var body: some View {
        Button {
            dismiss()
            action()
        } label: {
            HStack(spacing: 8) {
                if let checked {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(RunnirTheme.primary).opacity(checked ? 1 : 0).frame(width: 12)
                }
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 12)).frame(width: 16)
                }
                Text(title).font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 12)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(RunnirTheme.mutedForeground).lineLimit(1).fixedSize()
                }
            }
            .foregroundStyle(!isEnabled ? RunnirTheme.mutedForeground : destructive ? RunnirTheme.destructive : RunnirTheme.foreground)
            .padding(.horizontal, 10).frame(height: 30)
            .background(hovering && isEnabled ? RunnirTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hit)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(checked == true ? .isSelected : [])
    }
}

/// A group's title in a dropdown, as the scenario picker draws it.
struct DropdownHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.5)
            .foregroundStyle(RunnirTheme.mutedForeground)
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A line of explanation among a dropdown's rows.
struct DropdownNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(RunnirTheme.mutedForeground)
            .padding(.horizontal, 10).padding(.vertical, 6).fixedSize(horizontal: false, vertical: true)
    }
}

/// A question in the panel instead of a system alert: a title, a line of
/// explanation, a name field when it asks for one, and Cancel beside the
/// action. Return answers it; Escape, Cancel or a click outside leaves it.
struct DropdownPrompt: View {
    let title: String
    let message: String
    var name: Binding<String>?
    let action: String
    var destructive = false
    let confirm: () -> Void
    @Environment(\.dismissDropdown) private var dismiss
    @FocusState private var focused: Bool

    private var canConfirm: Bool { name.map { !$0.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(message).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
            if let name {
                TextField("Name", text: name).textFieldStyle(.plain).font(.system(size: 13))
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(RunnirTheme.editor, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? RunnirTheme.primary : RunnirTheme.border))
                    .focused($focused)
                    .onSubmit(answer)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(DesignButtonStyle())
                Button(action: answer) {
                    Text(action).foregroundStyle(destructive ? RunnirTheme.destructive : RunnirTheme.primaryButtonText)
                }
                .buttonStyle(DesignButtonStyle(primary: !destructive))
                .disabled(!canConfirm)
            }
        }
        .padding(14).frame(width: 290, alignment: .leading)
        .onAppear { focused = true }
    }

    private func answer() {
        guard canConfirm else { return }
        dismiss()
        confirm()
    }
}

struct DropdownDivider: View {
    var body: some View { DesignDivider().padding(.vertical, 4).padding(.horizontal, 8) }
}

/// A button that opens a menu of DropdownItems in Runnir's panel. It takes
/// the button style around it; the label gets whether the menu is open.
struct DropdownMenu<Label: View, Items: View>: View {
    private let alignment: HorizontalAlignment
    private let items: () -> Items
    private let label: (Bool) -> Label
    @State private var open = false

    init(alignment: HorizontalAlignment = .leading, @ViewBuilder items: @escaping () -> Items,
         @ViewBuilder label: @escaping (_ open: Bool) -> Label) {
        self.alignment = alignment
        self.items = items
        self.label = label
    }

    var body: some View {
        Button { open.toggle() } label: { label(open) }
            .dropdown(isPresented: $open, alignment: alignment) { DropdownList(content: items) }
    }
}

/// A choice among values in Runnir's panel: the chosen title and a chevron
/// on the button, the options with a check, grouped under headers when they
/// have sections.
struct DropdownPicker<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        var section: String?
    }

    private let label: String
    @Binding private var selection: Value
    private let options: [Option]
    private let placeholder: String
    @Environment(\.isEnabled) private var isEnabled
    @State private var open = false

    /// `label` names the choice for VoiceOver; the button shows the value.
    init(_ label: String, selection: Binding<Value>, options: [Option], placeholder: String = "Choose") {
        self.label = label
        _selection = selection
        self.options = options
        self.placeholder = placeholder
    }

    private var title: String { options.first { $0.value == selection }?.title ?? placeholder }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(RunnirTheme.secondaryForeground)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10).frame(height: 26)
            .background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(open ? RunnirTheme.primary : RunnirTheme.border))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.hit)
        .fixedSize()
        .accessibilityLabel(label)
        .accessibilityValue(title)
        .dropdown(isPresented: $open) {
            DropdownList {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    if let section = option.section, index == 0 || options[index - 1].section != section {
                        if index > 0 { DropdownDivider() }
                        DropdownHeader(section)
                    }
                    DropdownItem(option.title, checked: option.value == selection) { selection = option.value }
                }
            }
        }
    }
}
