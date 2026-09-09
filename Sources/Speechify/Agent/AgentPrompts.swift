import Foundation

/// Every word the agent model is told, in one file — the same split as `NotesPrompts`:
/// prompts churn, machinery doesn't, and they fail in different ways.
enum AgentPrompts {

    /// How many actions one pass may propose. A model asked for "follow-ups" without a
    /// ceiling writes a to-do list; three is what a person will actually read and answer.
    static let maxProposals = 3

    /// The rules. The catalogue itself is appended by `LLMProvider.complete(…, tools:)`, so
    /// there is one description of how a tool is called rather than one per prompt.
    static let system = """
        You are Speechify's meeting assistant. A meeting has just been recorded, transcribed \
        and summarised on the user's Mac. Your job is to propose the small number of \
        follow-up actions in the user's Google Workspace that the meeting actually asked for.

        Rules:
        - Propose only what was explicitly said. A follow-up nobody asked for is worse than none.
        - At most \(maxProposals) actions. Usually one or two; often zero.
        - Never invent an email address, a document id or a date. Use only what appears in \
        the meeting details, the notes or the transcript.
        - Copy owners and dates from the notes exactly. If an action item has no owner, do \
        not guess one.
        - Prefer draft_email to send_email whenever the meeting did not clearly ask for a \
        message to go out.
        - The user approves every action before it happens, so propose the useful thing \
        rather than the safe-looking one — but write each one as if it will be performed \
        exactly as written, because it will be.

        Actions that usually fit, when the meeting supports them: put the notes in a Doc so \
        the room can read them, email the action items to the people who were on the invite, \
        and create an event for a follow-up that was given a date.
        """

    /// The tool catalogue and the shape a call takes, in the block Qwen3.5 was tuned to read.
    ///
    /// `tools` is a parameter rather than the whole catalogue because the risk classes the
    /// caller allows decide what the model is even told exists: a pass that may not send
    /// email is not given `send_email` and asked nicely not to use it.
    static func toolBlock(tools: [WorkspaceTool]) -> String {
        """
        You have these tools:
        <tools>
        \(WorkspaceTools.schemaJSON(for: tools))
        </tools>

        For each action, emit one line of exactly this form and nothing else around it:
        <tool_call>{"name": "<tool>", "arguments": {…}, "rationale": "<one sentence>"}</tool_call>

        Emit no tool calls at all when nothing needs doing. Do not explain yourself outside \
        the tags.
        """
    }

    /// The whole meeting, for the pass that runs once it has finished.
    static func review(
        meeting: Meeting,
        notes: String?,
        transcript: String,
        results: [String] = []
    ) -> String {
        var sections = [context(for: meeting)]
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

        Propose an action only for an explicit request made in this excerpt — "send me the \
        deck", "put that in a doc", "let's meet Thursday". Anything discussed rather than \
        asked for is not a request. Emit no tool calls at all if nobody asked for anything.
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
