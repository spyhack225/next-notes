import Foundation
import FoundationModels

/// Experimental structured contract for the local voice frontend. It classifies
/// the user's request without owning tools; the coordinator remains the only
/// effect owner and resolves capabilities from its authoritative registry.
@Generable(description: "A safe decision for one voice turn in this app.")
struct LocalVoiceDecision {
    @Generable(description: "The kind of response the application should produce.")
    enum Intent {
        case answer
        case capabilities
        case newWork
        case revise
        case cancel
    }

    @Guide(description: "Choose capabilities for an overview or follow-up about the application's supported features or tools; choose answer for an ordinary question; choose newWork only when the person asks to perform external work; choose revise or cancel only for a referenced running task.")
    var intent: Intent

    @Guide(description: "The 1-based running task number for revise or cancel. Leave empty for answer, capabilities, and newWork.")
    var taskNumber: Int?

    @Guide(description: "A short spoken answer only for answer. Leave empty for capabilities, newWork, revise, and cancel.")
    var speech: String
}

enum LocalVoiceTypedResponse {
    static var isEnabled: Bool {
        SelfTest.isRunning && CommandLine.arguments.contains("--voice-legacy-envelope")
            && CommandLine.arguments.contains("--voice-typed-response")
    }

    /// Concise typed-mode instructions. The schema carries the response shape;
    /// no raw XML envelope instructions are mixed into this experiment.
    static let instructions = """
        You are the decision layer for this on-device voice assistant.
        Respond to the latest user turn through the structured response fields. Use the
        supplied application facts and conversation as evidence. An overview or
        follow-up about the application's supported capabilities or tools is
        informational: choose capabilities, including when account or permission
        availability is unknown. A question about one feature or its permissions
        is an ordinary question: choose answer and explain it in speech.
        Choose answer for an ordinary question and put the actual complete answer
        in speech. Never leave speech empty for answer. Choose
        newWork only when the person asks you to perform an external action or
        retrieve current information not already supplied. Choose revise or cancel
        only for the referenced running task number. If a user corrects a name,
        scope or detail of a running task, choose revise for that task; the revised
        instructions must reach the worker, even if they also say to continue.
        Do not answer with a promise to apply the correction yourself.
        Do not invent capabilities,
        task numbers, results, or account state. Put spoken prose only in speech
        when intent is answer; leave speech empty for every other intent.
        """
}

/// A two-stage conversation contract. Routing is deliberately a smaller
/// structured response than the spoken answer, so the model cannot fill an
/// answer field while it is deciding whether a turn is an effect request.
@Generable(description: "The route for one voice turn in this app.")
struct LocalVoiceRoute {
    @Generable(description: "The action that the application should take for the latest turn.")
    enum Intent {
        case answerQuestion
        case describeCapabilities
        case startExternalTask
        case reviseRunningTask
        case cancelRunningTask
        case checkTaskStatus
        case answerApproval
        case notAddressedToMe
    }

    @Guide(description: "Choose answerQuestion for an ordinary question or a specific feature question. Choose describeCapabilities for an overview of supported features. Choose startExternalTask only for a NEW requested external action or information retrieval, including requests phrased as questions. Choose reviseRunningTask for a correction to an active task, cancelRunningTask for its explicit cancellation, or checkTaskStatus for a question about running or recent work. Choose answerApproval only for an actual current offered approval; carry its explicit approve/deny answer and any requested correction, never invent a proposal. Choose notAddressedToMe only when the latest speech is plainly people talking to each other or to someone else.")
    var intent: Intent

    @Guide(description: "The exact 1-based supplied task number for reviseRunningTask, a selected cancelRunningTask, or an explicitly referenced checkTaskStatus. Leave empty for cancelRunningTask when cancelling the newest running task, for all-task status, and for every other intent.")
    var taskNumber: Int?

    @Guide(description: "Only for startExternalTask or reviseRunningTask: one faithful self-contained instruction, resolving pronouns from the supplied conversation while preserving every name, date, number and condition. Empty otherwise.")
    var objective: String

    @Guide(description: "Only for startExternalTask: one short natural clause of at most eight words saying what you are doing, without waiting filler or claiming completion. Empty otherwise.")
    var acknowledgement: String

    @Guide(description: "Only for answerApproval with an actual offered approval: approve or deny. Explicit yes only; yes plus a change is deny. Empty otherwise.")
    var approvalDecision: String
    @Guide(description: "Only for answerApproval when the person changes the proposal: the requested change. Empty otherwise.")
    var approvalChange: String
}

enum LocalVoiceSplitResponse {
    static var isEnabled: Bool {
        // Production always uses the verified route/answer boundary. The old
        // variants remain available only for explicit causal self-test probes.
        !SelfTest.isRunning || !CommandLine.arguments.contains("--voice-legacy-envelope")
    }

    /// The previous complete exchange is bounded, labelled context inside the
    /// current prompt, never native transcript demonstrations. The coordinator
    /// already filters repairs and scrubs old tool claims before this boundary.
    /// The authoritative current work package and speech remain unchanged.
    static func routePlan(messages: [LLMChatMessage]) -> LocalVoicePrompt.Plan? {
        guard let context = LocalVoicePrompt.plan(system: routeInstructions,
            messages: messages.filter { $0.role != .system }) else { return nil }
        guard let assistantIndex = context.history.lastIndex(where: { $0.role == .assistant }),
              let person = context.history[..<assistantIndex].last(where: { $0.role == .user }) else {
            return LocalVoicePrompt.Plan(instructions: context.instructions, history: [], latestUser: context.latestUser)
        }
        func quoted(_ text: String) -> String {
            let oneLine = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return String(oneLine.prefix(300))
        }
        let previousPerson = quoted(person.content)
        let previousAssistant = quoted(context.history[assistantIndex].content)
        guard !previousPerson.isEmpty, !previousAssistant.isEmpty else {
            return LocalVoicePrompt.Plan(instructions: context.instructions, history: [], latestUser: context.latestUser)
        }
        let previous = "Previous exchange (context only; route the latest speech):\n"
            + "Person: " + previousPerson + "\nAssistant: " + previousAssistant + "\n\n"
        return LocalVoicePrompt.Plan(instructions: context.instructions, history: [], latestUser: previous + context.latestUser)
    }

    /// Assembled through `AgentPromptContext`: routing carries no persona and no memory.
    static var routeInstructions: String {
        AgentPromptContext.assemble(.voiceRoute, rules: routeRules).system
    }

    /// Answer-stage native plan. `system` is the instructions the coordinator passed, which
    /// in production is `answerInstructions` — so the prompt the caller names is the prompt
    /// the model hears.
    ///
    /// The latest user message must carry the `Latest user speech:` marker. An answer
    /// prompt built without the actual utterance is what made the on-device model ask
    /// the person to repeat a complete question, so it fails loudly here instead of
    /// being handed to a model that can only guess what was said.
    static func answerPlan(system: String, messages: [LLMChatMessage]) -> LocalVoicePrompt.Plan? {
        guard let plan = LocalVoicePrompt.plan(system: system, messages: messages),
              let latest = messages.last(where: { $0.role == .user }),
              latest.content.contains("Latest user speech:\n") else { return nil }
        return plan
    }

    static let routeRules = """
        You are the routing layer for this on-device voice assistant.
        Classify the latest user turn into exactly one route. Use the supplied
        latest work status as context for running tasks.
        Choose answerQuestion for an ordinary question or a question about one
        specific feature. Choose describeCapabilities only when the person asks
        for an overview of what the application supports or can do. Choose
        startExternalTask when the person asks the application to perform a NEW
        action, inspect or check something, or retrieve current information; a
        request phrased as a question can still ask for action. Asking the
        application to remember, change or forget something about the person is
        startExternalTask. A question about
        how running or recent work is going, whether it is done, or what is being worked on is checkTaskStatus;
        it must not start the same task again. Choose
        reviseRunningTask for a correction to a referenced active task, and
        cancelRunningTask only for an explicit request to cancel one. Preserve
        the exact active task number for reviseRunningTask or
        cancelRunningTask. For checkTaskStatus preserve a referenced task number, otherwise leave taskNumber empty. Leave taskNumber empty for every other route. Do not
        invent task numbers or perform any action.
        Choose notAddressedToMe only when the latest speech is clearly people talking to each other or to someone else, not to you: it asks you nothing, asks you to do nothing, and does not reply to anything you said. Half of a conversation about an unrelated subject is notAddressedToMe. If it could be meant for you — a question, a greeting, a thank-you, a request, or a reply to what you just said — choose one of the other routes.
        For startExternalTask and reviseRunningTask, supply one self-contained objective.
        Resolve it, that, him and there from the supplied conversation. Preserve every name,
        date, time, number and condition; do not add steps or details the person did not ask for.
        For startExternalTask, supply one short acknowledgement of at most eight words saying
        what you are doing. Do not ask them to wait, promise speed or claim it is finished.
        Leave objective and acknowledgement empty for every other route.
        The supplied frontend control schemas are application-owned controls, not grants
        to run mail, calendar, files or writes yourself. All external work is startExternalTask.
        Choose answerApproval only when Approval offered is yes and the person answers
        that current proposal. Preserve their actual approve or deny choice. Explicit yes
        only may approve; yes plus a requested change is deny plus that change. Never invent
        an offer or turn unrelated speech into approval. Leave approvalDecision and
        approvalChange empty for every other route.
        """

    /// The spoken answer: the persona's short card, then these rules, then (from the
    /// caller's system messages) the capability facts. Memory is the profile only.
    static var answerInstructions: String {
        AgentPromptContext.assemble(.voiceAnswer, rules: answerRules).system
    }

    static let answerRules = """
        Answer the latest user question naturally and briefly. Use your general
        knowledge for ordinary questions and advice. Use the supplied application
        facts only when relevant to a question about this app; a tool inventory
        is not an answer to an unrelated question. Use supplied work status for
        progress questions. Qualify application features needing setup or permission.
        Use everyday words and never mention tools, files, settings, models or
        anything technical; if something needs setting up, say what to do in the app
        in one short sentence. Be warm and personal, never flattering, and offer the
        useful next step when it helps. Return plain spoken prose only: no XML,
        labels, markdown, tool calls, routing discussion, or promises to perform work.
        Open with the answer itself. Do not greet, say sure or great question, repeat the
        question, thank them for waiting or promise updates. Do not read identifiers, paths,
        web addresses, codes or long numbers unless they ask for the exact value. Never call
        unfinished work finished.
        """

    static let routeMaximumResponseTokens = 128
}
