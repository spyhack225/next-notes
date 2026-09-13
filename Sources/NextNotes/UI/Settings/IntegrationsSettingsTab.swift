import SwiftUI

/// Cloud apps beyond native Google Workspace, plus user-configured MCP servers.
struct IntegrationsSettingsTab: View {
    @State private var settings = Settings.shared
    @State private var mcp = MCPClientStore.shared
    @State private var newName = ""
    @State private var newCommand = ""
    @State private var newURL = ""
    @State private var status = ""

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
            Toggle("Connect through Composio", isOn: $settings.composioEnabled)
            SecureField("API key", text: $settings.composioAPIKey)
                .textContentType(.password)
            TextField("MCP URL", text: $settings.composioURL)
            Button("Save connection") {
                ComposioProvider.connect()
                status = "Composio saved. Tools appear after a refresh."
            }
            .disabled(!settings.composioEnabled || settings.composioAPIKey.isEmpty)
        } header: {
            Text("More apps")
        } footer: {
            SettingsNote(text: "GitHub, Slack, Notion, Linear and the rest of Composio’s "
                         + "catalogue arrive as MCP tools and still pass the permission broker. "
                         + "You never have to think about MCP during normal use.")
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
}
