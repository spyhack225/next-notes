import Foundation

enum ShellToolCatalogue {
    static let all: [AgentTool] = [
        .native(
            namespace: .shell,
            name: "run",
            description: "Run a shell command in a chosen working directory. Long-running "
                + "commands become a task and can be cancelled. Privileged commands "
                + "(sudo, installer) are refused here and must go through a stronger grant.",
            risk: .modify,
            parameters: [
                .init(name: "command", description: "The command to run."),
                .init(name: "directory", description: "Working directory.", isRequired: false),
            ],
            executionMode: .task
        ),
        .native(
            namespace: .shell,
            name: "status",
            description: "Status of a shell command started earlier, by its process id.",
            risk: .observe,
            parameters: [
                .init(name: "id", description: "The shell process id this app assigned.")
            ]
        ),
        .native(
            namespace: .shell,
            name: "cancel",
            description: "Cancel a running shell command.",
            risk: .modify,
            parameters: [
                .init(name: "id", description: "The shell process id this app assigned.")
            ]
        ),
    ]
}

enum BrowserToolCatalogue {
    static let all: [AgentTool] = [
        .native(
            namespace: .browser,
            name: "navigate",
            description: "Open a URL in the default browser.",
            risk: .modify,
            parameters: [
                .init(name: "url", description: "The URL to open.")
            ]
        ),
        .native(
            namespace: .browser,
            name: "snapshot",
            description: "A structured accessibility snapshot of the frontmost browser window.",
            risk: .observe,
            title: "Browser snapshot"
        ),
        .native(
            namespace: .browser,
            name: "click",
            description: "Click an element in the frontmost browser, by snapshot id.",
            risk: .modify,
            parameters: [
                .init(name: "id", description: "The element id from snapshot.")
            ]
        ),
        .native(
            namespace: .browser,
            name: "fill",
            description: "Type into an element in the frontmost browser, by snapshot id.",
            risk: .modify,
            parameters: [
                .init(name: "id", description: "The element id from snapshot."),
                .init(name: "text", description: "The text to type.", kind: .multiline),
            ]
        ),
        .native(
            namespace: .browser,
            name: "select",
            description: "Choose an option in a popup button, by snapshot id.",
            risk: .modify,
            parameters: [
                .init(name: "id", description: "The element id from snapshot."),
                .init(name: "value", description: "The option to choose."),
            ]
        ),
        .native(
            namespace: .browser,
            name: "download",
            description: "Open a download URL in the default browser. The browser owns the file.",
            risk: .modify,
            parameters: [
                .init(name: "url", description: "The URL to download.")
            ]
        ),
    ]
}
