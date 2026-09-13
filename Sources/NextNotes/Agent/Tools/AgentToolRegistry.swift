import Foundation

/// Everything the agent is allowed to name, regardless of who implements it.
///
/// Workspace tools stay first-class and keep their original names. Everything else is
/// registered beside them so `MeetingAgent` and `RealtimeAgent` ask one place.
@MainActor
final class AgentToolRegistry {
    static let shared = AgentToolRegistry()

    private var tools: [String: AgentTool] = [:]
    /// Secondary keys (`workspace.search_email`) that resolve to the same tool.
    private var aliases: [String: String] = [:]

    private init() {
        registerNativeCatalogue()
    }

    /// The tools a planning pass may be told about.
    func tools(upTo risk: AgentRisk, namespace: AgentToolNamespace? = nil) -> [AgentTool] {
        tools.values
            .filter { $0.risk <= risk && (namespace == nil || $0.namespace == namespace) }
            .sorted { $0.id < $1.id }
    }

    func tool(named name: String) -> AgentTool? {
        if let tool = tools[name] { return tool }
        if let canonical = aliases[name] { return tools[canonical] }
        return nil
    }

    func register(_ tool: AgentTool, aliases extra: [String] = []) {
        tools[tool.id] = tool
        for alias in extra where alias != tool.id {
            aliases[alias] = tool.id
        }
        if tool.namespace != .workspace {
            aliases["\(tool.namespace.rawValue).\(tool.name)"] = tool.id
        }
    }

    func unregister(id: String) {
        tools[id] = nil
        aliases = aliases.filter { $0.value != id }
    }

    /// Hermes JSON, one object per line — the same shape `WorkspaceTools.schemaJSON` emits.
    func schemaJSON(for tools: [AgentTool]) -> String {
        let shaped = tools.map { tool in
            WorkspaceTool(
                name: tool.id,
                summary: tool.description,
                risk: tool.risk,
                parameters: tool.parameters,
                titleBuilder: tool.titleBuilder,
                previewBuilder: tool.previewBuilder
            )
        }
        return WorkspaceTools.schemaJSON(for: shaped)
    }

    /// Puts the built-in catalogues in. Called once from `init`; MCP/Composio register later.
    func registerNativeCatalogue() {
        for tool in WorkspaceTools.all {
            register(AgentTool.workspace(tool), aliases: ["workspace.\(tool.name)"])
        }
        for tool in MeetingToolCatalogue.all { register(tool) }
        for tool in ComputerToolCatalogue.all { register(tool) }
        for tool in FilesystemToolCatalogue.all { register(tool) }
        for tool in ShellToolCatalogue.all { register(tool) }
        for tool in BrowserToolCatalogue.all { register(tool) }
    }
}
