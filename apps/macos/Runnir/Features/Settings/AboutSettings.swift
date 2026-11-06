import AppKit
import SwiftUI

/// The third-party components Runnir ships and their license texts, read
/// from `Licenses/notices.json` in the app bundle. scripts/update-notices.sh
/// generates the file (B49).
struct LicenseCatalog: Decodable, Equatable, Sendable {
    struct Component: Decodable, Equatable, Sendable, Identifiable {
        let name: String
        let version: String
        let license: String
        let source: String
        let texts: [String]
        var id: String { name }
    }

    struct Group: Decodable, Equatable, Sendable, Identifiable {
        let name: String
        let components: [Component]
        var id: String { name }
    }

    let groups: [Group]
    /// License and notice texts by id; components name theirs.
    let texts: [String: String]

    var count: Int { groups.reduce(0) { $0 + $1.components.count } }

    /// The groups with only the components whose name or license contains
    /// the query; groups left empty are left out. An empty query keeps all.
    func groups(matching query: String) -> [Group] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let components = group.components.filter {
                $0.name.localizedCaseInsensitiveContains(query) || $0.license.localizedCaseInsensitiveContains(query)
            }
            return components.isEmpty ? nil : Group(name: group.name, components: components)
        }
    }

    static func load(from url: URL) -> LicenseCatalog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LicenseCatalog.self, from: data)
    }

    static func licensesFolder(_ bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?.appending(path: "Licenses", directoryHint: .isDirectory)
    }

    static func bundled(_ bundle: Bundle = .main) -> LicenseCatalog? {
        licensesFolder(bundle).flatMap { load(from: $0.appending(path: "notices.json")) }
    }

    /// Runnir's own license, Apache 2.0.
    static func runnirLicense(_ bundle: Bundle = .main) -> String? {
        licensesFolder(bundle).flatMap { try? String(contentsOf: $0.appending(path: "Runnir-LICENSE.txt"), encoding: .utf8) }
    }
}

/// Where Settings › About links to.
enum AboutLink {
    static let website = URL(string: "https://runnir.com")!
    static let privacy = URL(string: "https://runnir.com/privacy")!
    static let terms = URL(string: "https://runnir.com/terms")!
}

/// A license text shown in Runnir's panel over Settings.
struct SettingsLicenseText: Equatable, Identifiable {
    let title: String
    let subtitle: String
    let text: String
    var id: String { title }
}

extension EnvironmentValues {
    /// Shows a license text in a panel over Settings; set by SettingsOverlay.
    @Entry var showSettingsLicense: (@MainActor (SettingsLicenseText) -> Void)? = nil
}

/// Settings › About (S12, B49): the versions, Runnir's license, links, and
/// the third-party software the app, the Core and act include.
struct AboutSettingsSection: View {
    let coreVersion: String?
    /// Updates (B50); nil in builds that never update.
    var updates: UpdateCenter?
    var catalog: LicenseCatalog? = LicenseCatalog.bundled()
    var runnirLicense: String? = LicenseCatalog.runnirLicense()
    @Environment(\.showSettingsLicense) private var showLicense
    @State private var query = ""
    @State private var openGroups: Set<String> = []
    @State private var openComponent: String?

    var body: some View {
        Section { header }
        if let updates { UpdateSettingsSection(center: updates) }
        Section {
            if let catalog {
                searchField
                let groups = catalog.groups(matching: query)
                if groups.isEmpty {
                    VStack(spacing: 4) {
                        Text("No component matches “\(query.trimmingCharacters(in: .whitespaces))”.")
                        Text("Search by a name, such as grpc, or a license, such as MIT.")
                            .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                }
                ForEach(groups) { group in
                    // A search shows every match without opening groups by hand.
                    let open = openGroups.contains(group.name) || !query.trimmingCharacters(in: .whitespaces).isEmpty
                    groupRow(group, open: open)
                    if open {
                        ForEach(group.components) { component in
                            componentRow(component, in: group, catalog: catalog)
                        }
                    }
                }
            } else {
                Text("Licenses are missing from this build.").foregroundStyle(RunnirTheme.secondaryForeground)
            }
        } header: {
            HStack {
                Text("Third-party software")
                Spacer()
                if let catalog { Text(catalog.count == 1 ? "1 component" : "\(catalog.count) components").textCase(nil) }
            }
        }
    }

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Runnir"
    }

    private var versions: BugReportDraft { BugReportDraft.current(coreVersion: coreVersion) }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(Self.appName).font(.system(size: 17, weight: .semibold))
                Text("Version \(versions.appVersion) · Core \(coreVersion ?? "not running")")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Text("Runnir is licensed under the Apache License 2.0.")
                    if let runnirLicense {
                        Button("View License") {
                            showLicense?(SettingsLicenseText(title: "Apache License 2.0", subtitle: "The license of Runnir", text: runnirLicense))
                        }
                        .buttonStyle(.link)
                        .pointerStyle(.link)
                        .accessibilityIdentifier("about-view-license")
                    }
                }
                .font(.system(size: 12))
                HStack(spacing: 14) {
                    link("Website", AboutLink.website)
                    link("GitHub", ProjectLink.url)
                    link("Privacy Policy", AboutLink.privacy)
                    link("Terms of Use", AboutLink.terms)
                }
                .font(.system(size: 12))
            }
            Spacer(minLength: 0)
            Button("Copy") {
                let v = versions
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(Self.appName) \(v.appVersion) · Core \(v.coreVersion ?? "unknown") · macOS \(v.macOSVersion) (\(v.architecture))", forType: .string)
            }
            .help("Copy the app, Core and macOS versions")
        }
        .padding(.vertical, 4)
    }

    private func link(_ title: String, _ url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "arrow.up.right.square").font(.system(size: 10))
            }
        }
        .pointerStyle(.link)
        .help(url.absoluteString)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
            TextField("Search by name or license", text: $query).textFieldStyle(.plain)
                .accessibilityIdentifier("about-license-search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(RunnirTheme.secondaryForeground)
                }
                .buttonStyle(.hit)
                .accessibilityLabel("Clear search")
            }
        }
    }

    private func groupRow(_ group: LicenseCatalog.Group, open: Bool) -> some View {
        Button {
            if openGroups.contains(group.name) { openGroups.remove(group.name) } else { openGroups.insert(group.name) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).frame(width: 12)
                    .foregroundStyle(RunnirTheme.secondaryForeground)
                Text(group.name).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(group.components.count == 1 ? "1 component" : "\(group.components.count) components")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.hit)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("about-group-\(group.name)")
    }

    @ViewBuilder
    private func componentRow(_ component: LicenseCatalog.Component, in group: LicenseCatalog.Group, catalog: LicenseCatalog) -> some View {
        let key = "\(group.name)/\(component.name)"
        let open = openComponent == key
        Button { openComponent = open ? nil : key } label: {
            HStack(spacing: 10) {
                Text(component.name).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                Text(component.version).font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
                Spacer(minLength: 8)
                Text(component.license).font(.system(size: 11)).lineLimit(1)
                    .foregroundStyle(RunnirTheme.info)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(RunnirTheme.info.opacity(0.14)))
            }
            .padding(.leading, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hit)
        .listRowBackground(open ? RunnirTheme.selected : nil)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        if open {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(component.texts, id: \.self) { id in
                    if let text = catalog.texts[id] { licenseBox(text) }
                }
                if let source = URL(string: component.source) {
                    HStack(spacing: 4) {
                        Text("Source:").foregroundStyle(RunnirTheme.secondaryForeground)
                        link(source.absoluteString.replacingOccurrences(of: "https://", with: ""), source)
                    }
                    .font(.system(size: 12))
                }
            }
            .padding(.leading, 18)
        }
    }

    private func licenseBox(_ text: String) -> some View {
        ScrollView {
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .frame(height: text.count > 400 ? 160 : nil)
        .background(RoundedRectangle(cornerRadius: 6).fill(RunnirTheme.editor))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(RunnirTheme.border))
    }
}

/// A license text in Runnir's own panel over Settings (S12, View License).
struct SettingsLicensePanel: View {
    let license: SettingsLicenseText
    let close: () -> Void

    var body: some View {
        ZStack {
            // No hand pointer: a click outside the panel closes it.
            Color.black.opacity(0.55).contentShape(Rectangle()).onTapGesture { close() }.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(license.title).font(.system(size: 15, weight: .semibold))
                    Text(license.subtitle).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
                ScrollView {
                    Text(license.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(RunnirTheme.editor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(RunnirTheme.border))
                HStack {
                    Spacer()
                    Button("Done") { close() }
                        .buttonStyle(DesignButtonStyle(primary: true))
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
            .frame(width: 600, height: 500)
            .background(RoundedRectangle(cornerRadius: 12).fill(RunnirTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(RunnirTheme.border))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(license.title)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
