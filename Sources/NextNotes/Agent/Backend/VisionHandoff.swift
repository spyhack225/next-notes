import Foundation

/// The one seam between a parked screenshot and the model that may see it.
///
/// `ScreenshotStore` exists because a capture cannot cross `AgentToolResult` without
/// either persisting bytes or widening a shape owned elsewhere; this is its other half.
/// When the tool loop catches a screenshot step it takes the parked image here, and
/// what the vision model says flows back into the loop as the tool's observation —
/// so the planner that asked for pixels can act on them in its next round.
///
/// Consent lives with the call, in this order, and both halves fail closed:
/// `VisionScope.maySend` (the persistent cloud switch, with the reader set to the
/// model that would receive the image) runs inside the providers' `contentPart`,
/// and `VisionConsentGate.requestApproval` — the per-run thumbnail sheet, nil
/// hook denies — runs inside `completeWithImages` at the moment bytes would leave.
/// No image byte is ever logged or written here; only the model's own sentences
/// travel, as tool observations.
///
/// Model choice is never made here: the loop passes the provider it already
/// resolved through `AgentModelRouting`, which is the same mechanism that picks
/// the "Controlling your Mac" role for a screen request. A provider without this
/// capability is answered honestly in the observation, never silently skipped and
/// never thrown past the planner.
enum VisionHandoff {
    /// The store keys one screenshot step may have parked under. `browser.screenshot`
    /// via CDP parks under `browser.screenshot:<targetId>`; when the call's arguments
    /// name a target that key is known here, and the AX fallback uses the fixed key.
    /// A CDP capture whose target was resolved internally reaches only the live view
    /// — `ScreenshotStore` has no key enumeration, so its own summary stands instead.
    private static func keys(toolID: String, arguments: [String: String]) -> [String] {
        switch toolID {
        case "computer.screenshot":
            return ["computer.screenshot"]
        case "browser.screenshot":
            let target = arguments["targetId"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return target.isEmpty ? ["browser.screenshot:ax"] : ["browser.screenshot:\(target)"]
        default:
            return []
        }
    }

    private static func parkedImage(
        toolID: String, arguments: [String: String], remove: Bool
    ) -> LLMImage? {
        for key in keys(toolID: toolID, arguments: arguments) {
            if let image = remove ? ScreenshotStore.take(for: key) : ScreenshotStore.peek(for: key) {
                return image
            }
        }
        return nil
    }

    /// What the screenshot step's observation becomes: the model's description of the
    /// capture, or an honest sentence about why there is none. Never throws and never
    /// returns empty — the planner reads whatever comes back as the tool's result.
    static func describe(
        provider: any LLMProvider,
        toolID: String,
        arguments: [String: String],
        parkSummary: String,
        cloudConsent: Bool,
        request: String
    ) async -> String {
        guard let image = parkedImage(toolID: toolID, arguments: arguments, remove: false) else {
            // The capture policy refused, or the capture went to a key this call
            // cannot name: the executor's own summary is the truthful observation.
            return parkSummary
        }
        guard let reader = provider as? ScreenshotReading else {
            return "The current model cannot see screenshots, so it was not sent; "
                + "the accessibility snapshot is the only description I have."
        }
        guard let capture = parkedImage(toolID: toolID, arguments: arguments, remove: true) else {
            return parkSummary
        }
        let observation: String
        do {
            // The reader must name the model that is about to see the pixels before
            // any content part is built; that is `VisionScope`'s whole contract.
            let completion = try await VisionScope.$reader.withValue(provider.id) {
                try await reader.completeWithImages(
                    system: Self.system,
                    user: Self.user(request: request, reason: arguments["reason"]),
                    images: [capture], consent: cloudConsent, maxTokens: maxTokens
                )
            }
            Log.agent.info(
                "parked screenshot described by \(provider.displayModelName, privacy: .public)"
            )
            let text = completion.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var described = text.isEmpty
                ? "The model saw the screenshot but described nothing."
                : "What the screenshot shows: \(text)"
            if asksToAct(on: request, or: arguments["reason"] ?? ""), let target = parseTargetLine(from: text) {
                described += String(
                    format: "\nThe control to act on is at target: %.2f, %.2f.", target.x, target.y
                )
            }
            observation = described
        } catch {
            // Consent denial and refused requests both arrive here; the providers'
            // own error sentences say that nothing left the Mac, so the planner
            // learns the capture stayed local rather than a step having failed.
            observation = "The screenshot was not described: \(error.localizedDescription)"
        }
        return observation
    }

    /// One description's length. The planner prompt must absorb it alongside the
    /// tool catalogue; a longer answer is cut off, not continued.
    private static let maxTokens = 320

    private static let system = """
        You are describing one screenshot of the user's screen for a tool-planning
        assistant. Name the application and the window or page, then list the visible
        controls, texts and values a person could act on, in reading order. Plain
        sentences, no preamble, and never describe the image as an image.
        """

    private static func user(request: String, reason: String?) -> String {
        var lines: [String] = []
        let stated = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stated.isEmpty {
            lines.append("Why the screenshot was taken: \(stated).")
        }
        lines.append("The user's current request: \(String(request.prefix(600)))")
        lines.append("Describe this screenshot so the task can continue.")
        if asksToAct(on: request, or: stated) {
            lines.append("""
                The image maps to the application's focused window. If the request names \
                something to click, press or tap, end your reply with one final line of \
                exactly this form — `target: 0.37, 0.62` — the control's position as two \
                normalized fractions of the image's width and height (0…1, origin top-left), \
                and nothing after that line.
                """)
        }
        return lines.joined(separator: "\n\n")
    }

    /// Whether this turn wants a pixel grounded into a coordinate. Deliberately a word
    /// gate over the request and the stated reason, not a model decision: the ask is
    /// cheap, and the executor only honours the coordinate when its own rules allow it.
    private static func asksToAct(on request: String, or reason: String) -> Bool {
        let haystack = "\(request) \(reason)".lowercased()
        return ["click", "press", "tap", "select"].contains { haystack.contains($0) }
    }

    /// The one machine-readable line a click-grounding answer is allowed to end with.
    ///
    /// Tolerant by direction: optional spaces around the colon and the comma, decimals
    /// with or without a leading zero, and everything after the two numbers ignored so a
    /// chatty model's tail line cannot fail the whole description. Values are clamped to
    /// 0…1 rather than rejected — a model that writes 1.02 meant the edge — while the
    /// executor's own range check is the one that refuses, so a clamped value can never
    /// post an event the executor was never asked for.
    static func parseTargetLine(from text: String) -> (x: Double, y: Double)? {
        guard let line = text
            .split(whereSeparator: \.isNewline)
            .reversed()
            .first(where: { $0.lowercased().contains("target:") }) else {
            return nil
        }
        let numbers = line
            .split(whereSeparator: { !$0.isNumber && $0 != "." && $0 != "-" })
            .compactMap { Double($0) }
        guard numbers.count >= 2 else { return nil }
        let x = min(max(numbers[0], 0), 1)
        let y = min(max(numbers[1], 0), 1)
        return (x, y)
    }
}

/// A provider that can be handed an image at all.
///
/// The vision entry points live as extensions on the two OpenAI-wire providers —
/// the chat protocol (`LLMProvider`) is deliberately untouched — so the loop asks
/// capability with one cast. The in-process models (Gemma, Apple Foundation) have
/// no image path and never conform; that miss is what produces the honest
/// "cannot see screenshots" observation.
protocol ScreenshotReading: LLMProvider {
    func completeWithImages(
        system: String, user: String, images: [LLMImage], consent: Bool, maxTokens: Int
    ) async throws -> LLMCompletion
}

extension OpenRouterLLMProvider: ScreenshotReading {}

extension OpenAICompatibleLLMProvider: ScreenshotReading {}
