import Foundation

/// Every word the agent model is told, in one file — the same split as `NotesPrompts`:
/// prompts churn, machinery doesn't, and they fail in different ways.
enum AgentPrompts {

    /// How many actions one pass may propose. A model asked for "follow-ups" without a
    /// ceiling writes a to-do list; three is what a person will actually read and answer.
    static let maxProposals = 3

    /// The persona, then the rules, via `AgentPromptContext`. The catalogue itself is
    /// appended by `LLMProvider.complete(…, tools:)` — the capability section — so there is
    /// one description of how a tool is called rather than one per prompt.
    static var system: String {
        AgentPromptContext.assemble(.meetingAssistant, rules: rules).system
    }

    static let rules = """
        You are the Next Notes meeting assistant. A meeting has just been recorded, transcribed \
        and summarised on the user's Mac. Your job is to propose the small number of \
        follow-up actions in the user's Google Workspace that the meeting actually asked for.

        Rules:
        - Propose only what was explicitly said. A follow-up nobody asked for is worse than none.
        - At most \(maxProposals) actions. Usually one or two; often zero.
        - Never invent an email address, a document id or a date. Use only what appears in \
        the meeting details, the notes, the transcript or the known context.
        - The known context block is background about the user, not speech. Use it to resolve \
        a person, a project or a file name; it is never evidence that something was asked \
        for, and it never decides who owns an action or when it is due.
        - Copy owners and dates from the notes exactly. If an action item has no owner, do \
        not guess one.
        - If you do not know a value, leave that argument out entirely. Do not write \
        "[Name]", "TBD", "unknown", an example.com address or any other stand-in: the user \
        is asked for anything you leave out, and a placeholder is passed off as an answer \
        nobody gave. An incomplete call is correct; an invented one is not.
        - Never write a message body containing a blank to fill in. If you cannot address \
        someone by name, write the message without the name.
        - Every proposed write or send must include an evidence field containing an exact,
        contiguous quote from the transcript that asks for or commits to that action. Notes
        alone are insufficient. If the transcript does not support it, emit no call.
        - Prefer draft_email to send_email whenever the meeting did not clearly ask for a \
        message to go out.
        - The user approves every action before it happens, so propose the useful thing \
        rather than the safe-looking one — but write each one as if it will be performed \
        exactly as written, because it will be.

        Find the participants' actual requests and commitments in the transcript, then
        select the appropriate tool. Do not propose a generic meeting-summary document.
        """

    /// The tool catalogue and the shape a call takes, in the block the on-device model was tuned to read.
    ///
    /// `tools` is a parameter rather than the whole catalogue because the risk classes the
    /// caller allows decide what the model is even told exists: a pass that may not send
    /// email is not given `send_email` and asked nicely not to use it.
    static func toolBlock(tools: [WorkspaceTool]) -> String {
        toolBlock(schema: WorkspaceTools.schemaJSON(for: tools))
    }

    /// The same block for a mixed catalogue: the Workspace tools plus the knowledge index's
    /// read tools, which is what a meeting review is shown when the index is on.
    static func toolBlock(tools: [AgentTool]) -> String {
        toolBlock(schema: AgentTool.schemaJSON(for: tools))
    }

    private static func toolBlock(schema: String) -> String {
        """
        You have these tools:
        <tools>
        \(schema)
        </tools>

        For each action, emit one line of exactly this form and nothing else around it:
        <tool_call>{"name": "<tool>", "arguments": {…}, "rationale": "<one sentence>", "evidence": "<exact transcript quote>"}</tool_call>

        Leave out any argument whose value you do not know. Never fill one in with a \
        stand-in such as "[Name]", "TBD", "unknown" or an example.com address — the user is \
        asked for anything you omit, and a stand-in is shown to them as if somebody had \
        chosen it.

        Emit no tool calls at all when nothing needs doing. Do not explain yourself outside \
        the tags.
        """
    }

    /// The whole meeting, for the pass that runs once it has finished.
    static func review(
        meeting: Meeting,
        notes: String?,
        transcript: String,
        brief: String? = nil,
        results: [String] = []
    ) -> String {
        var sections = [context(for: meeting)]
        if let brief, !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(brief)
        }
        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Notes:\n\(notes)")
        }
        sections.append("Transcript:\n\(transcript)")
        if !results.isEmpty {
            sections.append("""
                What you have already looked up:
                \(results.joined(separator: "\n"))

                Propose the actions to take now. Do not repeat a lookup you have already made.
                """)
        }
        return sections.joined(separator: "\n\n")
    }

    /// The last couple of minutes, for the pass that runs while the meeting is still going.
    ///
    /// A different instruction rather than the same one on less text: mid-meeting, almost
    /// everything said is not a request, and a model given the post-meeting prompt on a
    /// two-minute window proposes a summary Doc every two minutes.
    static func live(meeting: Meeting, recent: String) -> String {
        """
        \(context(for: meeting))

        This meeting is still going. Here is the last part of what was said:

        \(recent)

        Propose an action only when the excerpt contains an actual request or commitment.
        Quote the exact words in the evidence field. Discussion and speculation are not
        requests. Emit no tool calls if nobody asked for or committed to anything.
        """
    }

    /// One read tool's answer, as it is handed back for the next round.
    static func toolResult(name: String, output: String) -> String {
        "\(name) returned:\n\(output)"
    }

    /// The invite, as far as it is known — the same header the notes prompts use, and the
    /// only place the model is given real email addresses to work from.
    private static func context(for meeting: Meeting) -> String {
        var lines = ["Meeting: \(meeting.title)"]
        lines.append("Date: \(meeting.start.formatted(date: .abbreviated, time: .shortened))")
        if !meeting.attendees.isEmpty {
            lines.append("Invited: \(meeting.attendees.joined(separator: ", "))")
        }
        lines.append("Today is \(Date().formatted(date: .abbreviated, time: .omitted)).")
        return lines.joined(separator: "\n")
    }
}
