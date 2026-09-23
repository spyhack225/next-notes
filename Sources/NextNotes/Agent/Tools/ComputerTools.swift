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
                + "fields and tabs with stable element ids the click/set_text tools accept. "
                + "The default output is a compact list, one short line per control with "
                + "labels cut to about forty characters and window chrome skipped; "
                + "ask for verbose to get the full tree.",
            risk: .observe,
            parameters: [
                .init(name: "verbose", description: "The full tree, including unlabeled containers. Default is the compact list.", isRequired: false),
            ],
            title: "Inspect UI"
        ),
        .native(
            namespace: .computer,
            name: "screenshot",
            description: "A screenshot of the focused window only: downscaled to 1280px, kept "
                + "in memory, never stored. Use only when inspect_ui returns a stub tree or "
                + "when asked for pixels. The image reaches a vision model only with per-run "
                + "consent; otherwise it backs the live working view and is never uploaded.",
            risk: .observe,
            parameters: [
                .init(name: "reason", description: "Why pixels are needed, e.g. the seat-picker has no accessibility labels.", isRequired: false),
            ],
            title: "Screenshot"
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
                .init(name: "id", description: "The element id from inspect_ui."),
                .init(name: "expectedText", description: "Text expected in the window after clicking; required to verify the effect.", isRequired: false),
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
        .native(
            namespace: .computer,
            name: "scroll",
            description: "Scroll the focused window at an element's position, or at its centre when "
                + "no id is given. Amount is wheel clicks. A scroll whose visible text did not "
                + "change comes back as unverified, never as success.",
            risk: .modify,
            parameters: [
                .init(name: "direction", description: "up, down, left or right."),
                .init(name: "amount", description: "Wheel clicks, 1 to 30. Default 3.", isRequired: false),
                .init(name: "id", description: "Optional element id from inspect_ui.", isRequired: false),
            ]
        ),
        .native(
            namespace: .computer,
            name: "drag",
            description: "Press at one element's centre and drag to another's, by the ids inspect_ui "
                + "returned. The drag is posted as a real mouse drag; when accessibility cannot "
                + "observe its effect, the result says so instead of claiming success.",
            risk: .modify,
            parameters: [
                .init(name: "fromId", description: "The element id to press at, from inspect_ui."),
                .init(name: "toId", description: "The element id to drag to, from inspect_ui."),
            ]
        ),
        .native(
            namespace: .computer,
            name: "double_click",
            description: "Double-click an accessibility element by the id inspect_ui returned, at the "
                + "centre of the part of it that is visible. Selects a word in a text field; opens "
                + "what a single press would not.",
            risk: .modify,
            parameters: [
                .init(name: "id", description: "The element id from inspect_ui."),
            ]
        ),
        .native(
            namespace: .computer,
            name: "right_click",
            description: "Right-click an accessibility element by the id inspect_ui returned. A context "
                + "menu may open; inspect_ui afterwards shows it, and press_key with escape closes it.",
            risk: .modify,
            parameters: [
                .init(name: "id", description: "The element id from inspect_ui."),
            ]
        ),
        .native(
            namespace: .computer,
            name: "wait_for",
            description: "Poll the focused window every quarter second until text appears — the "
                + "alternative to re-inspecting blindly. A timeout comes back as a named failure, "
                + "never as success.",
            risk: .observe,
            parameters: [
                .init(name: "expectedText", description: "The text to wait for."),
                .init(name: "timeoutSeconds", description: "How long to wait, up to 30. Default 5.", isRequired: false),
            ]
        ),
    ]
}
