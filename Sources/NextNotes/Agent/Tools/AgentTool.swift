import Foundation

/// Which family a tool belongs to. The model sees `id`; routing and Settings group by this.
enum AgentToolNamespace: String, Codable, Sendable, CaseIterable {
    case meeting
    case computer
    case shell
    case filesystem
    case browser
    case workspace
    case github
    case notion
    case slack
    case mcp
}

/// Where the implementation lives. The model is not told this — `ToolRouter` is.
enum AgentToolSource: String, Codable, Sendable, CaseIterable {
    case native
    case mcp
    case composio
    case acp
}

/// Whether the realtime loop may run this itself, or must hand it to `AgentTaskManager`.
enum AgentToolExecutionMode: String, Codable, Sendable {
    /// Bounded, expected to finish in a couple of seconds: calendar read, active app.
    case immediate
    /// Sustained work: a search across a disk, a shell command, an ACP coding session.
    case task
}

/// One thing the agent can do, described once for the model, the user and the executor.
///
/// Workspace tools keep the short names they already had (`search_email`) so a proposal
/// sitting on disk still finds its catalogue entry. Newer tools use `namespace.name`.
struct AgentTool: Sendable, Identifiable {
    let id: String
    let namespace: AgentToolNamespace
    let name: String
    let description: String
    let parameters: [WorkspaceTool.Parameter]
    let risk: AgentRisk
    let source: AgentToolSource
    let executionMode: AgentToolExecutionMode
    let titleBuilder: @Sendable ([String: String]) -> String
    let previewBuilder: (@Sendable ([String: String]) -> String?)?

    func title(for arguments: [String: String]) -> String { titleBuilder(arguments) }
    func preview(for arguments: [String: String]) -> String? { previewBuilder?(arguments) }

    /// The existing Workspace catalogue, wrapped rather than rewritten.
    static func workspace(_ tool: WorkspaceTool) -> AgentTool {
        AgentTool(
            id: tool.name,
            namespace: .workspace,
            name: tool.name,
            description: tool.summary,
            parameters: tool.parameters,
            risk: tool.risk,
            source: .native,
            executionMode: tool.risk <= .read ? .immediate : .task,
            titleBuilder: tool.titleBuilder,
            previewBuilder: tool.previewBuilder
        )
    }

    /// A native tool defined in this build.
    static func native(
        namespace: AgentToolNamespace,
        name: String,
        description: String,
        risk: AgentRisk,
        parameters: [WorkspaceTool.Parameter] = [],
        executionMode: AgentToolExecutionMode? = nil,
        title: String? = nil,
        preview: (@Sendable ([String: String]) -> String?)? = nil
    ) -> AgentTool {
        let id = "\(namespace.rawValue).\(name)"
        return AgentTool(
            id: id,
            namespace: namespace,
            name: name,
            description: description,
            parameters: parameters,
            risk: risk,
            source: .native,
            executionMode: executionMode ?? (risk <= .read ? .immediate : .task),
            titleBuilder: { arguments in
                if let title { return title }
                if let first = arguments.values.first(where: { !$0.isEmpty }) {
                    return "\(name) \(first)"
                }
                return id
            },
            previewBuilder: preview
        )
    }
}
