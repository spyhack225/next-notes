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
            name: "screenshot",
            description: "A screenshot of the frontmost browser tab via CDP Page.captureScreenshot "
                + "(memory-only, never stored). Use only after a stub snapshot or when asked for "
                + "pixels. The image reaches a vision model only with per-run consent; otherwise "
                + "it backs the live working view and is never uploaded.",
            risk: .observe,
            parameters: [
                .init(name: "targetId", description: "The CDP target id from snapshot.", isRequired: false),
                .init(name: "reason", description: "Why pixels are needed, e.g. the seat-picker has no accessibility labels.", isRequired: false),
            ],
            title: "Browser screenshot"
        ),
        .native(
            namespace: .browser,
            name: "click",
            description: "Click an element in the frontmost browser, by snapshot id.",
            risk: .modify,
            parameters: [
                .init(name: "id", description: "The element id from snapshot."),
                .init(name: "expectedText", description: "Text that must appear after this click or submit. Supply this or expectedURL for verification.", isRequired: false),
                .init(name: "expectedURL", description: "Destination URL that must be reached after this click. Supply this or expectedText for verification.", isRequired: false),
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
        .native(
            namespace: .browser,
            name: "purchase",
            description: "Complete a purchase in the frontmost browser tab. Refused before anything "
                + "runs when the amount is over the cap. The approval card shows the exact amount, "
                + "the payment method and the cap; the receipt is kept as an artifact.",
            risk: .purchase,
            parameters: [
                .init(name: "targetId", description: "The CDP target id from snapshot.", isRequired: false),
                .init(name: "amountCents", description: "Total charged, in cents — 3350 for $33.50."),
                .init(name: "capCents", description: "Budget cap in cents. Above it the run is refused."),
                .init(name: "paymentRef", description: "Payment method shown on the card, e.g. Visa on file.", isRequired: false),
            ],
            title: "Purchase",
            preview: { BrowserPurchaseCard.preview(for: $0) }
        ),
    ]
}
