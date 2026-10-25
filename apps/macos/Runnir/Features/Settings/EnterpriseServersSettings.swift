import SwiftUI

/// The add-server form: URLs are checked as typed; the token is checked
/// against the server's API before Add is offered.
@MainActor
@Observable
final class EnterpriseServerForm {
    var name = ""
    var webURL = "" { didSet { if webURL != oldValue { check = nil } } }
    var apiURL = "" { didSet { if apiURL != oldValue { check = nil } } }
    var token = "" { didSet { if token != oldValue { check = nil } } }
    private(set) var check: CoreGitHubTokenCheck?
    private(set) var isChecking = false
    @ObservationIgnored private let existing: [EnterpriseServer]
    @ObservationIgnored private let id = UUID()

    init(existing: [EnterpriseServer]) {
        self.existing = existing
    }

    /// What keeps the fields from being a server, in the order of the form.
    var problems: [String] {
        (nameProblem.map { [$0] } ?? []) + urlProblems
    }

    private var nameProblem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || trimmed.count > EnterpriseServer.maxNameLength else { return nil }
        return "Name: use 1 to \(EnterpriseServer.maxNameLength) characters."
    }

    /// What keeps the URLs from being a server the token can be checked on;
    /// the name matters only for Add.
    private var urlProblems: [String] {
        var out: [String] = []
        if case .failure(let problem) = EnterpriseServerURL.check(webURL) { out.append("Web URL: " + problem.message) }
        if case .failure(let problem) = EnterpriseServerURL.check(apiURL) { out.append("API URL: " + problem.message) }
        if let draft, existing.contains(where: { $0.webHost == draft.webHost }) {
            out.append("Web URL: \(draft.webHost) is already in the list.")
        }
        return out
    }

    /// The URLs are a server and a token is typed.
    var canCheck: Bool {
        urlProblems.isEmpty && !token.isEmpty && !isChecking
    }

    /// The server the fields describe, when both URLs pass.
    var draft: EnterpriseServer? {
        guard case .success(let web) = EnterpriseServerURL.check(webURL),
              case .success(let api) = EnterpriseServerURL.check(apiURL) else { return nil }
        return EnterpriseServer(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), webURL: web, apiURL: api,
                                login: check?.login ?? "")
    }

    /// What to show under the form: a field left empty is not a mistake
    /// yet, so only filled-in fields are judged.
    var shownProblems: [String] {
        var out: [String] = []
        // An empty name is said once the token passed and Add waits for it.
        if let nameProblem, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || check?.access == .ok {
            out.append(nameProblem)
        }
        if !webURL.isEmpty, case .failure(let problem) = EnterpriseServerURL.check(webURL) { out.append("Web URL: " + problem.message) }
        if !apiURL.isEmpty, case .failure(let problem) = EnterpriseServerURL.check(apiURL) { out.append("API URL: " + problem.message) }
        if let draft, existing.contains(where: { $0.webHost == draft.webHost }) {
            out.append("Web URL: \(draft.webHost) is already in the list.")
        }
        return out
    }

    /// The fields are valid and the server accepted this very token.
    var canAdd: Bool {
        problems.isEmpty && check?.access == .ok && !isChecking
    }

    func runCheck(hub: CoreHub) async {
        guard let draft, canCheck else { return }
        isChecking = true
        defer { isChecking = false }
        let asked = (token, webURL, apiURL)
        let result = await hub.checkGitHubToken(token, server: draft.ref)
        // A field changed while the check ran: its answer is for other values.
        guard asked == (token, webURL, apiURL) else { return }
        check = result
    }
}

/// Settings › Account › GitHub Enterprise: the servers next to github.com.
struct EnterpriseServersSection: View {
    let servers: EnterpriseServers
    let hub: CoreHub?
    @State private var adding = false
    @State private var removing: EnterpriseServer?

    var body: some View {
        Section("GitHub Enterprise") {
            ForEach(servers.servers) { server in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name)
                        Text(server.login.isEmpty ? server.webHost : "\(server.login) on \(server.webHost)")
                            .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                    }
                    Spacer()
                    Button("Remove...") { removing = server }
                }
            }
            if let problem = servers.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(RunnirTheme.warning)
            }
            HStack {
                Button("Add Enterprise Server...") { adding = true }
                    .disabled(hub == nil || servers.servers.count >= EnterpriseServers.maxServers)
                Spacer()
            }
            Text("Runnir signs in to an Enterprise server with a personal access token, kept in your Keychain. Working trees whose origin is on that server use it.")
                .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $adding) {
            if let hub { AddEnterpriseServerSheet(servers: servers, hub: hub) }
        }
        .confirmationDialog("Remove \(removing?.name ?? "")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let removing { Task { await servers.remove(removing.id) } }
            }
        } message: {
            Text("Runnir forgets this server and deletes its token from your Keychain. The token stays valid on the server until you revoke it.")
        }
    }
}

/// Adds an Enterprise server: name, URLs and a token that its API accepted.
struct AddEnterpriseServerSheet: View {
    let servers: EnterpriseServers
    let hub: CoreHub
    @State private var form: EnterpriseServerForm
    @State private var saveProblem: String?
    @Environment(\.dismiss) private var dismiss

    init(servers: EnterpriseServers, hub: CoreHub) {
        self.servers = servers
        self.hub = hub
        _form = State(initialValue: EnterpriseServerForm(existing: servers.servers))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Enterprise Server").font(.headline)
            Form {
                TextField("Name", text: $form.name, prompt: Text("Company GitHub"))
                TextField("Web URL", text: $form.webURL, prompt: Text("https://github.company.com"))
                TextField("API URL", text: $form.apiURL, prompt: Text("https://github.company.com/api/v3"))
                SecureField("Token", text: $form.token, prompt: Text("github_pat_… or ghp_…"))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(form.shownProblems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                    }
                    if let check = form.check {
                        GitHubTokenCheckView(check: check)
                    }
                    if let web = form.draft?.webURL {
                        GitHubTokenAdvice(emphasized: form.check.map { $0.access == .ok && !$0.suitable } ?? false, webURL: web, enterprise: true)
                    }
                    if let saveProblem {
                        Label(saveProblem, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(RunnirTheme.warning)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(form.isChecking ? "Checking..." : "Check Token") { Task { await form.runCheck(hub: hub) } }
                    .disabled(!form.canCheck)
                Button("Add") { Task { await add() } }
                    .buttonStyle(DesignButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!form.canAdd)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func add() async {
        guard let draft = form.draft else { return }
        do {
            try await servers.add(draft, token: form.token)
            dismiss()
        } catch EnterpriseServers.AddError.duplicateHost {
            saveProblem = "\(draft.webHost) is already in the list."
        } catch {
            saveProblem = "Runnir could not save the server or its token in your Keychain."
        }
    }
}
