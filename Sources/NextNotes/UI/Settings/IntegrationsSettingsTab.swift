import SwiftUI

/// Cloud apps beyond native Google Workspace, plus user-configured MCP servers.
struct IntegrationsSettingsTab: View {
    @State private var settings = Settings.shared
    @State private var mcp = MCPClientStore.shared
    @State private var newName = ""
    @State private var newCommand = ""
    @State private var newURL = ""
    @State private var status = ""
    @State private var isSigningIn = false
    @State private var showAdvanced = false
    @State private var advancedKey = ""

    var body: some View {
        Form {
            workspace
            composio
            mcpServers
        }
        .formStyle(.grouped)
    }

    private var workspace: some View {
        Section {
            LabeledContent("Google Workspace") {
                Text("Native")
                    .foregroundStyle(DS.Color.success)
            }
        } header: {
            Text("Built in")
        } footer: {
            SettingsNote(text: "Gmail, Calendar, Drive and Docs stay on the Workspace tab. "
                         + "A native tool is preferred whenever one exists.")
        }
    }

    private var composio: some View {
        Section {
            LabeledContent("Account") {
                Text(ComposioProvider.isSignedIn ? "Signed in" : "Not signed in")
                    .foregroundStyle(ComposioProvider.isSignedIn ? DS.Color.success : DS.Color.textSecondary)
            }

            if ComposioProvider.isSignedIn {
                Toggle("Use Composio for more apps", isOn: $settings.composioEnabled)
                Button("Refresh tools") {
                    Task { @MainActor in await refreshTools() }
                }
                .disabled(!settings.composioEnabled || isSigningIn)
                Button("Sign out of Composio", role: .destructive) {
                    Task { @MainActor in
                        await ComposioProvider.signOut()
                        status = "Signed out of Composio."
                    }
                }
                .disabled(isSigningIn)
            } else {
                Button {
                    Task { @MainActor in await signIn() }
                } label: {
                    if isSigningIn {
                        Label("Waiting for browser…", systemImage: "safari")
                    } else {
                        Label("Sign in with Composio", systemImage: "person.badge.key")
                    }
                }
                .disabled(isSigningIn)
            }

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                TextField("MCP URL", text: $settings.composioURL)
                SecureField("Consumer key (ck_…)", text: $advancedKey)
                    .textContentType(.password)
                Button("Save key & refresh") {
                    Task { @MainActor in
                        do {
                            try ComposioCredentialStore.save(apiKey: advancedKey)
                            settings.composioAPIKey = ""
                            settings.composioEnabled = true
                            advancedKey = ""
                            await refreshTools()
                        } catch {
                            status = error.localizedDescription
                        }
                    }
                }
                .disabled(advancedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("More apps")
        } footer: {
            SettingsNote(text: isSigningIn
                         ? "A browser window asked Composio to authorize Next Notes. Click Authorize, then come back here."
                         : "Sign in opens your browser — no API key to copy. After that, asking the agent about "
                         + "GitHub, Slack, Notion or Linear will prompt to connect each app the same way.")
        }
    }

    private var mcpServers: some View {
        Section {
            ForEach(mcp.servers) { server in
                LabeledContent(server.name) {
                    Text(server.enabled ? "Connected" : "Off")
                        .foregroundStyle(server.enabled ? DS.Color.success : DS.Color.textSecondary)
                }
            }
            TextField("Name", text: $newName)
            TextField("stdio command", text: $newCommand)
            TextField("or HTTP URL", text: $newURL)
            Button("Add server") {
                let transport: MCPServerConfig.Transport = newURL.isEmpty ? .stdio : .http
                mcp.add(MCPServerConfig(
                    name: newName,
                    transport: transport,
                    command: newCommand,
                    url: newURL
                ))
                newName = ""
                newCommand = ""
                newURL = ""
            }
            .disabled(newName.isEmpty || (newCommand.isEmpty && newURL.isEmpty))
            if !status.isEmpty {
                Text(status)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        } header: {
            Text("MCP servers")
        } footer: {
            SettingsNote(text: "stdio or Streamable HTTP. Every discovered tool is allowlisted "
                         + "here and authorised by Next Notes, not by the server’s own annotations.")
        }
    }

    @MainActor
    private func signIn() async {
        isSigningIn = true
        status = "Browser opened — click Authorize in Composio."
        defer { isSigningIn = false }
        do {
            let tools = try await ComposioProvider.signInAndRefresh()
            status = tools.isEmpty
                ? "Signed in. Tools will appear on the next refresh."
                : "Signed in — \(tools.count) Composio tools ready."
        } catch {
            status = error.localizedDescription
        }
    }

    @MainActor
    private func refreshTools() async {
        do {
            let tools = try await ComposioProvider.connectAndRefresh()
            status = tools.isEmpty
                ? "Composio saved, but no tools came back."
                : "Composio ready — \(tools.count) tools registered."
        } catch {
            status = error.localizedDescription
        }
    }
}
