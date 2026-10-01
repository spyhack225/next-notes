import Foundation
import AppKit
import os
struct WorkspaceTool: Sendable, Identifiable {
    let name: String
    let summary: String
    let risk: AgentRisk
    let parameters: [Parameter]
    /// One line for the card. Takes the arguments because "Create a Doc" is not as useful
    /// as the title of the document being created.
    let titleBuilder: @Sendable ([String: String]) -> String
    /// The full text of what would be said, for the tools that say things.
    let previewBuilder: (@Sendable ([String: String]) -> String?)?

    var id: String { name }

    func title(for arguments: [String: String]) -> String { titleBuilder(arguments) }
    func preview(for arguments: [String: String]) -> String? { previewBuilder?(arguments) }

    /// A named argument, in the shape both the JSON schema and the editor need.
    struct Parameter: Sendable, Identifiable, Equatable {
        let name: String
        let description: String
        var isRequired = true
        var kind = Kind.text

        var id: String { name }

        /// What the editor should show, and how the runner reads the value back. Everything
        /// crosses the boundary as a string — these say what kind of string.
        enum Kind: Sendable, Equatable {
            /// One line.
            case text
            /// Several lines: an email body, a document.
            case multiline
            /// Comma-separated, split by the runner. `gws` takes comma-separated recipients
            /// and repeated `--attendee` flags, and both come from one field here.
            case list
            /// ISO 8601, or a plain `YYYY-MM-DD`.
            case date
            /// An identifier issued by a tool or the person: a document id, a message number, a
            /// file id. P1-25's kind, and **marked here rather than guessed from the name** — a
            /// heuristic on the name would have to encode "id", "_id" and "message" and would be
            /// wrong the first time a tool called something `reference`.
            case identifier
        }

        /// The JSON-schema type. Everything is a string: the model writes command-line
        /// arguments, and a schema that promises an array produces one that then has to be
        /// flattened back into a flag anyway.
        var schema: [String: Any] {
            var schema: [String: Any] = ["type": "string", "description": description]
            switch kind {
            case .list: schema["description"] = "\(description) Comma-separated."
            case .date: schema["description"] = "\(description) ISO 8601."
            case .identifier: schema["description"] = "\(description) Copy it exactly from a "
                + "search result or from what the user said; do not invent one."
            case .text, .multiline: break
            }
            return schema
        }
    }
}
enum AgentRisk: String, Codable, Sendable, CaseIterable, Comparable {
    /// Looks at what is already on screen or in a meeting. Automatic.
    case observe
    /// Looks something up. Runs without asking when `Settings.agentAutoRunReadTools` is on.
    case read
    /// Changes a local file or UI the user already owns. Confirmation depends on scope.
    case modify
    /// Creates or changes something the user owns. One click.
    case write
    /// Says something as the user. One click, and the full message is shown first.
    ///
    /// This is the "communicate" class in the v2 roadmap. The raw value stays `send` so a
    /// proposal written before the rename still decodes as the same thing.
    case send
    /// Spends the user's money. One click, and the card shows the exact amount, the
    /// payment method and the cap it was checked against.
    ///
    /// Ranked between `send` and `destructive`: money out is harder to take back than a
    /// sent message and easier to replace than deleted data. Never auto-runs.
    ///
    /// Documented choice (roadmap AGENT-COMPETITOR-GAP P1/D5): a distinct risk class
    /// rather than a `requiresCapCheck` flag on the tool, so `max` over a plan, the
    /// permission broker and the approval card all see it without special-casing one
    /// tool id. The cap itself stays per-call (`capCents`), checked in
    /// `BrowserToolExecutor.purchase`, not in the class.
    case purchase
    /// Deletes or irreversibly destroys something. Strong confirmation.
    case destructive
    /// Installs software, runs as root, or otherwise leaves the user's machine. Strong
    /// confirmation, and never an "always allow everything" escape.
    case privileged

    var displayName: String {
        switch self {
        case .observe: "Observes"
        case .read: "Reads"
        case .modify: "Edits"
        case .write: "Creates"
        case .send: "Sends"
        case .purchase: "Purchases"
        case .destructive: "Deletes"
        case .privileged: "Privileged"
        }
    }

    /// Whether running this changes something outside the app.
    ///
    /// Not the same question as `mayAutoRun`, and deliberately named apart from it: that one
    /// is a permission policy, this one is a fact about the world, and a policy change must not
    /// silently move which replies count as claims of an action. The two agree today, and
    /// `ToolClaimGuard` wants the fact — a reply that says it *sent* something is claiming an
    /// effect, and a `filesystem.search` does not have one.
    var changesSomething: Bool {
        switch self {
        case .observe, .read: false
        case .modify, .write, .send, .purchase, .destructive, .privileged: true
        }
    }

    /// Whether this class may ever run without a person pressing a button.
    var mayAutoRun: Bool {
        switch self {
        case .observe, .read: true
        case .modify, .write, .send, .purchase, .destructive, .privileged: false
        }
    }

    /// Whether executing this leaves something another person can see.
    var speaksForTheUser: Bool { self == .send }

    /// Ordered by consequence, so `max` over a set of tools answers "what is the worst this
    /// could do".
    private var rank: Int {
        switch self {
        case .observe: 0
        case .read: 1
        case .modify: 2
        case .write: 3
        case .send: 4
        case .purchase: 5
        case .destructive: 6
        case .privileged: 7
        }
    }

    static func < (lhs: AgentRisk, rhs: AgentRisk) -> Bool { lhs.rank < rhs.rank }

    /// A proposal written by a newer build may name a class this build has never heard
    /// of. A decoding surprise must never auto-run and must never take the file with
    /// it, so an unknown raw value reads as `.send`: the most cautious class that still
    /// renders a card a person can approve or refuse.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentRisk(rawValue: raw) ?? .send
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
struct WorkspaceToolResult: Sendable {
    /// What the model — or the log — should be told. Trimmed to something readable.
    let summary: String
    /// The identifier Google gave back: a document id, an event id, a message id.
    let reference: String?
    /// Where the user can go and look at it.
    let link: URL?
    /// A concrete postcondition checked by the native executor, separate from its
    /// human-readable success sentence and provider-created identifier.
    let verification: String?
    /// P1-21: the write left and nothing came back, so what is here is a **read's** answer
    /// about it — or the absence of one. Not a failure, and never a retry.
    ///
    /// A field rather than a sentence a caller matches on. The first version of the wiring keyed
    /// on `summary.hasPrefix("I\u{2019}m not sure")`, which is the text-rule `AgentReplyRenderer`
    /// and P0-17 exist to remove: a reworded sentence silently stops being recognised and the
    /// duplicate-send bug comes back with nobody testing it.
    var outcomeUnknown: Bool = false

    init(summary: String, reference: String? = nil, link: URL? = nil,
         verification: String? = nil, outcomeUnknown: Bool = false) {
        self.summary = summary
        self.reference = reference
        self.link = link
        self.verification = verification
        self.outcomeUnknown = outcomeUnknown
    }
}
typealias AgentToolResult = WorkspaceToolResult
enum VerifyRetry {
    struct Attempt: Sendable {
        var summary: String
        var verification: String?
    }

    /// Run `act` once; on an unverified result with `risk <= .modify`, re-inspect via
    /// `reinspect` and run `act` exactly once more. Returns every attempt plus the
    /// user-facing sentence for the mismatch case.
    static func run(
        risk: AgentRisk,
        title: String,
        expected: String,
        observed: () -> String,
        reinspect: () -> Void,
        act: () throws -> Attempt
    ) throws -> (attempts: [Attempt], mismatchMessage: String?) {
        let first = try act()
        guard first.verification == nil, risk <= .modify else {
            return ([first], nil)
        }
        reinspect()
        let second = try act()
        guard second.verification == nil else {
            return ([first, second], nil)
        }
        let outcome = second.verification == nil ? "still off" : "ok"
        let message =
            "I clicked \(title) expecting \(expected) but saw \(observed()). "
            + "Re-checked and tried once more — \(outcome)."
        return ([first, second], message)
    }
}
private actor RaceGate<T: Sendable> {
    private var waiter: CheckedContinuation<T?, Never>?
    private var settled = false
    private var result: T?

    func settle(_ value: T?) {
        guard !settled else { return }
        settled = true
        result = value
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: value)
        }
    }

    func value() async -> T? {
        if settled { return result }
        return await withCheckedContinuation { waiter = $0 }
    }
}
func withBoundedWait<T: Sendable>(
    _ limit: Duration,
    _ work: @escaping @Sendable () async -> T
) async -> T? {
    let gate = RaceGate<T>()
    let job = Task(priority: .userInitiated) { await gate.settle(await work()) }
    let timer = Task {
        try? await Task.sleep(for: limit)
        await gate.settle(nil)
    }

    return await withTaskCancellationHandler {
        let result = await gate.value()
        timer.cancel()
        if result == nil { job.cancel() }
        return result
    } onCancel: {
        // A new spoken turn cancels the old planner's parent task. Without
        // forwarding that cancellation, its unstructured model job kept
        // running until the deadline and competed with live ASR/TTS.
        job.cancel()
        timer.cancel()
        Task { await gate.settle(nil) }
    }
}

struct AgentError: LocalizedError {
 let errorDescription: String?
 static func backendUnavailable(_ text:String)->Self{.init(errorDescription:text)}
 static func permissionDenied(_ text:String)->Self{.init(errorDescription:text)}
 static func unknownTool(_ text:String)->Self{.init(errorDescription:text)}
 static func missingArgument(name:String,tool:String)->Self{.init(errorDescription:"Missing " + name)}
}
@MainActor struct AgentToolRegistry {
 static let shared = Self()
 func tool(named id:String)->AgentTool? { BrowserToolCatalogue.all.first{$0.id == id} }
}
// Presentation dependencies only. No named action/yield behavior is stubbed.
enum AgentWorkPresentationScope { @TaskLocal static var binding:String? }
@MainActor final class AgentActivityStore {
 static let shared=AgentActivityStore()
 func noteWindow(_ text:String, binding:String? = nil) {}
 func noteHumanYield() {}
}
enum BrowserPurchaseCard { static func preview(for args:[String:String])->String? { fatalError("Purchase is outside this driver") } }
enum SelfTest { static let isRunning = true }
enum Log { static let agent=Logger(subsystem:"NextNotesCUFixture",category:"fixture") }
struct LLMImage { var thumbnail:Data; var pixelWidth:Int; var pixelHeight:Int }
enum ScreenCapture { static func encode(cgImage:CGImage)throws->LLMImage { fatalError("Screenshot is outside this driver; cannot fake it") } }
enum ComputerToolExecutor { @MainActor static func publishCapture(_ image:LLMImage,for key:String,summary:String){ fatalError("Screenshot is outside this driver") } }
