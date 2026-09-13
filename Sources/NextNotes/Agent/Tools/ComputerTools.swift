import Foundation

enum ComputerToolCatalogue {
    static let all: [AgentTool] = [
        .native(
            namespace: .computer,
            name: "active_app",
            description: "The frontmost application, its window title and bundle identifier.",
            risk: .observe,
            title: "Active app"
        ),
        .native(
            namespace: .computer,
            name: "windows",
            description: "Visible windows of the frontmost application.",
            risk: .observe,
            title: "Windows"
        ),
        .native(
            namespace: .computer,
            name: "inspect_ui",
            description: "A structured accessibility snapshot of the focused window: buttons, "
                + "fields and tabs with stable element ids the click/set_text tools accept.",
            risk: .observe,
            title: "Inspect UI"
        ),
        .native(
            namespace: .computer,
            name: "get_selection",
            description: "The currently selected text, when the focused field exposes it.",
            risk: .observe,
            title: "Current selection"
        ),
        .native(
            namespace: .computer,
            name: "clipboard",
            description: "The current clipboard string, if any.",
            risk: .read,
            title: "Clipboard"
        ),
        .native(
            namespace: .computer,
            name: "open_app",
            description: "Open an installed application by name.",
            risk: .modify,
            parameters: [
                .init(name: "name", description: "The application name, e.g. Xcode.")
            ]
        ),
        .native(
            namespace: .computer,
            name: "open_url",
            description: "Open a URL in the default browser.",
            risk: .modify,
            parameters: [
                .init(name: "url", description: "The URL to open.")
            ]
        ),
        .native(
            namespace: .computer,
            name: "focus",
            description: "Bring an application to the front by name.",
            risk: .modify,
            parameters: [
                .init(name: "name", description: "The application name.")
            ]
        ),
        .native(
            namespace: .computer,
            name: "click",
            description: "Click an accessibility element by the id inspect_ui returned.",
            risk: .modify,
            parameters: [
                .init(name: "id", description: "The element id from inspect_ui.")
            ]
        ),
        .native(
            namespace: .computer,
            name: "press_key",
            description: "Post a keypress. Use a named key such as return, escape, tab, "
                + "or a single character. Optional modifiers: command, shift, option, control.",
            risk: .modify,
            parameters: [
                .init(name: "key", description: "The key to press."),
                .init(name: "modifiers", description: "Comma-separated modifiers.", isRequired: false),
            ]
        ),
        .native(
            namespace: .computer,
            name: "set_text",
            description: "Replace the value of an accessibility text field by element id.",
            risk: .modify,
            parameters: [
                .init(name: "id", description: "The element id from inspect_ui."),
                .init(name: "text", description: "The text to write.", kind: .multiline),
            ]
        ),
        .native(
            namespace: .computer,
            name: "type",
            description: "Type text into the focused field, or into the inspect_ui id if given.",
            risk: .modify,
            parameters: [
                .init(name: "text", description: "The text to type.", kind: .multiline),
                .init(name: "id", description: "Optional element id from inspect_ui.", isRequired: false),
            ]
        ),
    ]
}
