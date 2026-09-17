import Foundation
import FoundationModels

/// Experimental structured contract for the local voice frontend. It classifies
/// the user's request without owning tools; the coordinator remains the only
/// effect owner and resolves capabilities from its authoritative registry.
@Generable(description: "A safe decision for one voice turn in Next Notes.")
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
        You are the decision layer for Next Notes, an on-device voice assistant.
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
@Generable(description: "The route for one Next Notes voice turn.")
struct LocalVoiceRoute {
    @Generable(description: "The action that the application should take for the latest turn.")
    enum Intent {
        case answerQuestion
        case describeCapabilities
        case startExternalTask
        case reviseRunningTask
        case cancelRunningTask
    }

    @Guide(description: "Choose answerQuestion for an ordinary question, a specific feature question, or a status question about already-running work. Choose describeCapabilities for an overview of supported features. Choose startExternalTask only for a NEW requested external action or information retrieval, including requests phrased as questions. Choose reviseRunningTask for a correction to an active task, or cancelRunningTask for its explicit cancellation.")
    var intent: Intent

    @Guide(description: "The exact 1-based active task number, only for reviseRunningTask or cancelRunningTask. Leave empty for every other intent.")
    var taskNumber: Int?
}

enum LocalVoiceSplitResponse {
    static var isEnabled: Bool {
        // Production always uses the verified route/answer boundary. The old
        // variants remain available only for explicit causal self-test probes.
        !SelfTest.isRunning || !CommandLine.arguments.contains("--voice-legacy-envelope")
    }

    /// This classifier selects an operation from the current request and the
    /// authoritative active-work status. Old conversational answers are not
    /// outputs of this classifier and must not become routing demonstrations.
    /// The answer and tool-worker lanes retain the complete bounded dialogue
    /// to resolve subjects and follow-ups after this operation is selected.
    static func routePlan(messages: [LLMChatMessage]) -> LocalVoicePrompt.Plan? {
        guard let context = LocalVoicePrompt.plan(system: routeInstructions,
            messages: messages.filter { $0.role != .system }) else { return nil }
        return LocalVoicePrompt.Plan(instructions: context.instructions, history: [],
            latestUser: context.latestUser)
    }

    /// Assembled through `AgentPromptContext`: routing carries no persona and no memory.
    static var routeInstructions: String {
        AgentPromptContext.assemble(.voiceRoute, rules: routeRules).system
    }

    /// Answer-stage native plan. `system` is the instructions the coordinator passed, which
    /// in production is `answerInstructions` — so the prompt the caller names is the prompt
    /// the model hears.
    static func answerPlan(system: String, messages: [LLMChatMessage]) -> LocalVoicePrompt.Plan? {
        LocalVoicePrompt.plan(system: system, messages: messages)
    }

    static let routeRules = """
        You are the routing layer for Next Notes, an on-device voice assistant.
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
        the progress or purpose of an already running task is answerQuestion;
        it must not start the same task again. Choose
        reviseRunningTask for a correction to a referenced active task, and
        cancelRunningTask only for an explicit request to cancel one. Preserve
        the exact active task number for reviseRunningTask or
        cancelRunningTask. Leave taskNumber empty for every other route. Do not
        invent task numbers or perform any action.
        """

    /// The spoken answer: the persona's short card, then these rules, then (from the
    /// caller's system messages) the capability facts. Memory is the profile only.
    static var answerInstructions: String {
        AgentPromptContext.assemble(.voiceAnswer, rules: answerRules).system
    }

    static let answerRules = """
        Answer the latest user question naturally and briefly. Use your general
        knowledge for ordinary questions and advice. Use the supplied application
        facts only when relevant to a question about Next Notes; a tool inventory
        is not an answer to an unrelated question. Use supplied work status for
        progress questions. Qualify application features needing setup or permission.
        Return plain spoken prose only: no XML, labels, markdown, tool calls,
        routing discussion, or promises to perform work.
        """

    static let routeMaximumResponseTokens = 64
}
