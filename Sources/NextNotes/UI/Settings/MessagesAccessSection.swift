import SwiftUI

/// Settings → Agent → Messages: one grant, one live answer.
///
/// Full Disk Access is the only thing standing between Next Notes and a conversation on the
/// user's own phone, and it is the one grant in the app that has **no way to be asked for**:
/// there is no prompt, no preflight and no `authorizationStatus`. So the only honest answer
/// is a real read of the real database — `MessagesDatabaseHealth` — and this section is the
/// place that answer is shown rather than assumed.
///
/// The `○` / `✓` come from `MessagesAccessVerdict` and from nowhere else. That is deliberate
/// and it is the whole task: a `@State private var isGranted` inside this view would render
/// the right glyph and be impossible to check from a terminal, so
/// `--selftest-imessage-db` could not assert the claim that matters — that a failure
/// **cannot** show a ✓. A checkmark that can only come out of a value is a checkmark that
/// can be held in a test.
struct MessagesAccessSection: View {
    @State private var verdict = MessagesAccessVerdict.notGranted
    @State private var isProbing = false
    /// Whether the pane has been opened from here. Nothing is detectable — the app cannot tell
    /// "not added" from "added an older copy" — so the advice line is chosen by what the person
    /// has done, not by what the machine knows.
    @State private var hasOpenedPane = false

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: DS.Space.xs) {
                    // The glyph and the words are both the verdict's, and the colour is
                    // chosen by its `isGranted`, so a second place that could decide
                    // "granted" does not exist.
                    Text(verdict.mark)
                        .foregroundStyle(verdict.isGranted ? DS.Color.success : DS.Color.textSecondary)
                    Text(verdict.text)
                        .foregroundStyle(verdict.isGranted ? DS.Color.success : DS.Color.textSecondary)
                }
                .font(DS.Font.callout)
            } label: {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text("Full Disk Access")
                    // IM-03's sentence, verbatim. It is the sentence that makes the ask
                    // reasonable — the second half is the promise that decides it — so it is
                    // not shortened, reworded or split across a footer.
                    Text(MessagesAccessVerdict.purpose)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Shown only while it is still off, because the one thing a person needs
                    // here is the step the pane does not tell them: this list has no Next Notes
                    // in it yet, and a switch that is not there cannot be flipped. After the
                    // pane has been opened once the line becomes the repair advice, which is
                    // the remaining explanation. Same strings as the Permissions checklist —
                    // one sentence, two places, no drift.
                    if !verdict.isGranted {
                        Text(MessagesAccessVerdict.advice(hasPressed: hasOpenedPane))
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: DS.Space.s) {
                // `searching` and not a spinner: the press causes a *read* of something
                // Next Notes did not write, to find out whether it can. It runs for
                // milliseconds, which is the honest lifetime for an orb — it is not
                // standing in for a model.
                if isProbing {
                    ThinkingOrb(state: .searching, size: DS.Size.orbBadge)
                        .accessibilityHidden(true)
                }
                Button("Check again") { probe(force: true) }
                    .disabled(isProbing)
                Button("Open Full Disk Access settings…") {
                    hasOpenedPane = true
                    Permissions.openFullDiskAccessSettings()
                }
                .buttonStyle(.link)
                .font(DS.Font.caption)
                Spacer()
            }
        } header: {
            Text("Messages")
        } footer: {
            SettingsNote(text: footer)
        }
        .task { probe(force: false) }
    }

    private var footer: String {
        if verdict.isGranted {
            return "Next Notes can read your Messages on this Mac. It reads the one conversation "
                + "you choose, and only while Messages access is switched on here."
        }
        return "macOS does not let an app ask for this one, so the button can only open the pane. "
            + "Press it, turn on the switch next to Next Notes, and come back — this line turns "
            + "green on its own."
    }

    private func probe(force: Bool) {
        isProbing = true
        Task { @MainActor in
            // A forced check has to actually re-read. `messagesAccessState()` is cached for
            // 30 s so the checklist's 2 s poll is not opening a 96 MB database fifteen times a
            // minute, and without dropping the cache first a person who has just come back
            // from System Settings would press the button and be told nothing had changed.
            // Invalidating is the one thing that belongs to the caller, because only the
            // caller knows the answer might have moved.
            if force { await MessagesDatabaseHealth.invalidate() }
            let state = await Permissions.messagesAccessState()
            verdict = MessagesAccessVerdict.verdict(for: state)
            isProbing = false
        }
    }
}

/// What the Messages row says, and the one glyph that decides it.
///
/// Pure, and separate from the view for the reason its own comment gives: the claim this
/// task exists to make is that the row **cannot** show a ✓ unless a row really came back out
/// of a database, and a value a self-test can hold is the only kind of thing that can be
/// held. `verdict(for:)` is the *whole* decision — there is no second `isGranted` anywhere —
/// and `--selftest-imessage-db` asserts the negative half, that a `.unreadable` state
/// produces no ✓ at all.
enum MessagesAccessVerdict: Equatable, Sendable {
    /// A row came back out of the Messages database.
    case granted
    /// It did not. No reason is carried: a reason here is SQLite's wording, which is not
    /// something to put in front of a person, and the row's action is the same either way —
    /// open the pane.
    case notGranted

    /// IM-03's copy, verbatim and in one piece.
    static let purpose =
        "Next Notes needs Full Disk Access to read the iMessage conversation you choose for "
        + "remote access. Messages are processed on this Mac."

      /// The glyph the row draws. "✓" for `.granted` and nothing else, ever.
      var mark: String {
          switch self {
          case .granted: "✓"
          case .notGranted: "○"
          }
      }

      /// What the glyph is claiming, in words somebody would say out loud.
      var text: String {
          switch self {
          case .granted: "On"
          case .notGranted: "Not on yet"
          }
      }

      var isGranted: Bool { self == .granted }

      /// The line under the row, and the one that has to change.
      ///
      /// Full Disk Access is the only pane in this list where the app is not already in it, so
      /// the first press needs the instruction everybody misses — that the `+` button is the
      /// whole task. After a press, the two remaining explanations are "you never added it" and
      /// "you added an older copy", and they are indistinguishable from inside the app, so the
      /// line moves to the repair advice that fixes both: remove it, add it again.
      ///
      /// It is here, on the pure type, rather than in either view, because the Settings section
      /// and the Permissions checklist both say it and `AGENTS.md`'s rule is that a sentence a
      /// person reads in two places must be one string, not two spellings.
      static func advice(hasPressed: Bool) -> String {
          hasPressed ? Permissions.fdaRepairAdvice : Permissions.fdaAddAdvice
      }


    /// The one mapping, from a probe state to what is on screen.
    static func verdict(for state: MessagesDatabaseHealth.State) -> MessagesAccessVerdict {
        switch state {
        case .readable: .granted
        case .unreadable: .notGranted
        }
    }
}
