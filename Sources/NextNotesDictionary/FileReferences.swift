import Foundation

/// Turns a file name the speaker said into the reference the target app resolves —
/// "open the acoustic echo file" into "open the @docs/acoustic-echo.md file" — after cleanup,
/// deterministically, instead of asking the cleanup model to do it.
///
/// ## Why not the model
///
/// The model was asked first, and on 2026-09-16 it did not do it. With the harvested names and
/// the @-path rule both in its prompt, Apple's on-device model left "the paid release that
/// defied" and "the next note v1 roadmap md" exactly as heard, twice, in Cursor. The same
/// prompt carries a dozen rules telling it to change as little as possible, and a small model
/// reads a three-word rewrite into a path as exactly what those rules forbid. This is the
/// argument `DictionaryCorrector` already makes about ASR biasing: a nudge promises nothing,
/// so anything that must come out right is fixed after the fact, in code. It is also why this
/// works under S1-mini, which has no prompt at all.
///
/// ## How a name is found
///
/// Exactly first, loosely second.
///
/// - **Exact:** a run of words whose letters join to the file's name. That one test covers
///   "login handler", "loginHandler", "ts config" for tsconfig, "acoustic dash echo", and
///   "file store" for fileStore.ts — which the loose match cannot find, because `SpokenForms`
///   drops "file" as filler before scoring.
/// - **Loose:** `SpokenForms.bestMatch` at `confidentScore`, for a name the recogniser misheard
///   ("next note v1 roadmap" for Next_Notes_v1_Roadmap.md).
///
/// The extension is then read from the words *after* the name — "dot css", "css", "c s s",
/// "typescript", "shell" — rather than taken from `Match.namedExtension`. The loose match
/// clamps its score at 1.0, so once the name alone scores 1.0 the +0.08 an extension earns has
/// nowhere to go and the window that leaves the extension out wins. Measured on 2026-09-16:
/// "login dot css" matched `[login]` with `namedExtension == false`, which both failed every
/// one-word name and left "dot ts" behind after the reference on every name that did tag.
/// Changing that would change the scores the shared vectors pin, so it is compensated for
/// here instead.
///
/// ## Why it does not tag ordinary words
///
/// A match needs evidence the speaker meant a *file*, the same evidence Wispr Flow documents
/// for its own file tagging:
///
/// - the candidate is a **file**, never a folder;
/// - and the speaker **said its extension**, **or** said a name of **two or more words**, **or**
///   said **"file"** straight after it, **or** said **"tag"** straight before it.
///
/// A name shorter than three letters ("ci", "a") needs its extension or "tag": "save a file"
/// must not become a reference to a.txt. An extensionless file needs "file" or "tag", unless
/// it is one of the conventional build files (`conventionalNames`), which nobody says by
/// accident. Without these rules a first version rewrote "The build is green" as "The @.build
/// is green" at a score of 1.00.
///
/// ## Why it leaves a tie alone
///
/// "The logo file" matches logo.png and logo.svg equally, and "helpers dot ts" matches two
/// helpers.ts in different folders. Picking one would read as a confident, correct-looking
/// reference to the wrong file, which is worse than the words. Stronger evidence is not a tie:
/// "login handler test dot ts" names loginHandler.test.ts over loginHandler.ts, because only
/// one of them had its extension said.
///
/// Swift only. Unlike `SpokenForms` this is not part of the shared vectors, and the Windows
/// app has no counterpart; the Swift tests are its whole specification today.
public enum FileReferences {
    /// How a resolved reference is written.
    public enum Style: Sendable, Equatable {
        /// `@docs/login.ts` — resolved by Cursor's composer, Windsurf, Claude Code.
        case atPath
        /// `` `docs/login.ts` `` — not resolved by anything, but reads as a path.
        case backtickPath
    }

    /// One harvested name.
    public struct Candidate: Sendable, Equatable {
        /// A project-relative path where the harvest had one, the bare name where it did not.
        public let reference: String
        /// From the harvest, not guessed from the string: only the tree knows that `Makefile`
        /// is a file and `src` is a folder.
        public let isFile: Bool

        public init(reference: String, isFile: Bool) {
            self.reference = reference
            self.isFile = isFile
        }
    }

    public struct Tagged: Sendable, Equatable {
        public let text: String
        /// The references written, in the order they appear.
        public let references: [String]
    }

    /// Two files whose evidence is equally strong and whose scores are closer than this on the
    /// same words are too close to call.
    public static let ambiguityMargin = 0.05

    /// Extensionless files that are always files and never ordinary words.
    public static let conventionalNames: Set<String> = [
        "dockerfile", "containerfile", "makefile", "gnumakefile", "justfile", "gemfile",
        "rakefile", "procfile", "brewfile", "podfile", "vagrantfile", "jenkinsfile",
        "caddyfile", "guardfile", "berksfile", "fastfile", "appfile", "snapfile",
    ]

    /// How extensions are said, beyond their own letters. A superset of
    /// `SpokenForms.extensionAliases`, kept here rather than there on purpose: that table is
    /// shared contract, and it also feeds `namedOtherExtension`, where "go", "text" or "shell"
    /// would start rejecting names across ordinary sentences. Here an alias only counts
    /// immediately after a name that matched, so an ordinary word costs nothing.
    public static let spokenExtensions: [String: [String]] = [
        "ts": ["typescript"], "tsx": ["typescript", "typescript react"],
        "mts": ["typescript"], "cts": ["typescript"],
        "js": ["javascript"], "jsx": ["javascript", "javascript react"],
        "mjs": ["javascript"], "cjs": ["javascript"],
        "py": ["python"], "ipynb": ["notebook", "jupyter notebook"],
        "rb": ["ruby"], "rs": ["rust"], "go": ["golang"], "kt": ["kotlin"], "kts": ["kotlin"],
        "m": ["objective c"], "mm": ["objective c plus plus"],
        "h": ["header"], "hpp": ["header", "c plus plus header"],
        "cpp": ["c plus plus"], "cc": ["c plus plus"], "cs": ["c sharp"],
        "sh": ["shell", "bash"], "zsh": ["z shell"], "ps1": ["powershell"],
        "md": ["markdown"], "mdx": ["markdown"], "txt": ["text"], "rtf": ["rich text"],
        "doc": ["word"], "docx": ["word"], "xls": ["excel"], "xlsx": ["excel"],
        "json": ["jason"], "yml": ["yaml"], "yaml": ["yml"], "toml": ["tommel"],
        "html": ["htm"], "htm": ["html"], "scss": ["sass"], "sass": ["scss"], "sql": ["sequel"],
        "plist": ["property list"], "png": ["ping"], "jpg": ["jpeg", "j peg"],
        "jpeg": ["jpg", "j peg"], "gif": ["jif"], "wav": ["wave"],
    ]

    /// Rewrites every clearly spoken file name in `text` as a reference. Whether a string is a
    /// file is inferred: it has an extension, or it is a conventional build file.
    public static func tag(_ text: String, references: [String], style: Style, looseMatchLimit: Int = .max) -> Tagged {
        tag(
            text,
            candidates: references.map { Candidate(reference: $0, isFile: isFile($0)) },
            style: style,
            looseMatchLimit: looseMatchLimit
        )
    }

    /// Rewrites every clearly spoken file name in `text` as a reference.
    ///
    /// - Parameter looseMatchLimit: how many of `candidates`, from the front, may fall back to
    ///   the loose match. The exact pass is cheap and runs for every candidate; the loose match
    ///   is a `SpokenForms.bestMatch` per name and is nearly all the cost — 70 ms for a
    ///   344-word dictation against 67 names in an optimized build, several times that in the
    ///   debug build `make install` ships. `ScreenContext.narrowed` has already scored every
    ///   name and put the plausible ones first, so the caller passes that count and the loose
    ///   match only runs where it could succeed.
    public static func tag(
        _ text: String,
        candidates: [Candidate],
        style: Style,
        looseMatchLimit: Int = .max
    ) -> Tagged {
        let untouched = Tagged(text: text, references: [])
        let tokens = SpokenForms.tokenize(spoken: text)
        guard !tokens.isEmpty else { return untouched }
        let words = tokens.map { $0.text.precomposedStringWithCanonicalMapping }
        let utf16 = Array(text.utf16)
        let heard = SpokenForms.Heard(text)

        func word(_ index: Int) -> String? { words.indices.contains(index) ? words[index] : nil }

        var hits: [Hit] = []
        for (position, candidate) in candidates.enumerated() where candidate.isFile {
            guard let name = Name(candidate.reference) else { continue }

            // Exact spans first; the loose match only for a name that appears nowhere exactly.
            var spans = exactSpans(of: name.joined, in: words, tokens: tokens, utf16: utf16).map { (span: $0, exact: true, score: 1.0, looseExt: false, looseFull: false) }
            if spans.isEmpty, position < looseMatchLimit {
                let match = SpokenForms.bestMatch(of: candidate.reference, in: heard)
                if match.isConfident, !match.namedOtherExtension, !match.spokenTokens.isEmpty,
                   match.spokenTokens.upperBound <= tokens.count,
                   isOnePhrase(match.spokenTokens, tokens: tokens, utf16: utf16) {
                    let full = match.nameTokenCount >= 2 && match.matchedTokenCount >= match.nameTokenCount
                    spans = [(match.spokenTokens, false, match.score, match.namedExtension, full)]
                }
            }

            for found in spans {
                let extensionEnd = name.ext.flatMap {
                    extensionRun(of: $0, from: found.span.upperBound, in: words, tokens: tokens, utf16: utf16)
                }
                let saidExtension = extensionEnd != nil || found.looseExt
                let end = extensionEnd ?? found.span.upperBound
                let fileAfter = ["file", "files"].contains(word(end) ?? "")
                    && isOnePhrase(end - 1..<end + 1, tokens: tokens, utf16: utf16)
                let tagBefore = word(found.span.lowerBound - 1) == "tag"
                    && isOnePhrase(found.span.lowerBound - 1..<found.span.lowerBound + 1, tokens: tokens, utf16: utf16)
                let severalWords = found.exact ? found.span.count >= 2 : found.looseFull

                let evidence: Bool
                if name.ext == nil {
                    evidence = tagBefore || fileAfter || (found.exact && conventionalNames.contains(name.joined))
                } else if name.joined.count < 3 {
                    evidence = saidExtension || tagBefore
                } else {
                    evidence = saidExtension || severalWords || fileAfter || tagBefore
                }
                guard evidence else { continue }

                let start = pathStart(of: name, before: found.span.lowerBound, in: words, tokens: tokens, utf16: utf16)
                var range = utf16Range(tokens[start].start, tokens[end - 1].start + tokens[end - 1].length, in: utf16)
                // A dot-file's leading dot is not a token; take it with the name, or ".eslintrc"
                // becomes ".@.eslintrc.json".
                if name.basename.hasPrefix("."), range.lowerBound > 0, utf16[range.lowerBound - 1] == 0x2E {
                    range = (range.lowerBound - 1)..<range.upperBound
                }
                guard !isAlreadyAReference(range, in: utf16) else { continue }

                hits.append(Hit(
                    reference: candidate.reference,
                    tokens: start..<end,
                    range: range,
                    exact: found.exact,
                    saidExtension: saidExtension,
                    score: found.score
                ))
            }
        }

        // Strongest evidence first, then score. Among hits on the same words the first is the
        // only one taken, and only if nothing else on those words is as strong.
        hits.sort {
            if $0.strength != $1.strength { return $0.strength > $1.strength }
            if $0.tokens.count != $1.tokens.count { return $0.tokens.count > $1.tokens.count }
            return $0.score > $1.score
        }
        var chosen: [Hit] = []
        var undecidable: [Range<Int>] = []
        for hit in hits {
            if chosen.contains(where: { $0.tokens.overlaps(hit.tokens) }) { continue }
            if undecidable.contains(where: { $0.overlaps(hit.tokens) }) { continue }
            // A rival whose words sit inside this hit's is not a tie: "paid release.md" names
            // PAID-RELEASE.md, not the release.md whose one word it happens to contain.
            let tied = hits.contains {
                $0.reference != hit.reference
                    && $0.tokens.overlaps(hit.tokens)
                    && !(hit.tokens.contains($0.tokens.lowerBound) && $0.tokens.upperBound <= hit.tokens.upperBound
                         && $0.tokens.count < hit.tokens.count)
                    && $0.strength == hit.strength
                    && hit.score - $0.score < ambiguityMargin
            }
            if tied {
                undecidable.append(hit.tokens)
                continue
            }
            chosen.append(hit)
        }
        guard !chosen.isEmpty else { return untouched }

        var result = utf16
        for hit in chosen.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            let written: String = switch style {
            case .atPath: "@\(hit.reference)"
            case .backtickPath: "`\(hit.reference)`"
            }
            result.replaceSubrange(hit.range, with: Array(written.utf16))
        }
        return Tagged(
            text: String(decoding: result, as: UTF16.self),
            references: chosen.sorted { $0.range.lowerBound < $1.range.lowerBound }.map(\.reference)
        )
    }

    /// Whether a reference names a file: its last component has an extension with a letter in
    /// it, or it is one of `conventionalNames`. `.gitignore` has no extension to say and is not
    /// tagged; neither is `v1.2`, whose "extension" is a number. A caller that knows better —
    /// the harvest does — passes `Candidate.isFile` instead.
    public static func isFile(_ reference: String) -> Bool {
        let name = SpokenForms.basename(of: reference)
        if conventionalNames.contains(name.lowercased()) { return true }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        return !ext.isEmpty && ext.contains(where: \.isLetter)
    }

    // MARK: - Pieces

    private struct Hit {
        let reference: String
        let tokens: Range<Int>
        let range: Range<Int>
        let exact: Bool
        let saidExtension: Bool
        let score: Double

        /// Exact beats loose; a said extension beats none.
        var strength: Int { (exact ? 2 : 0) + (saidExtension ? 1 : 0) }
    }

    /// A reference, cut into what a speaker could say of it.
    private struct Name {
        let basename: String
        let ext: String?
        /// The name without its extension, lowercased, letters and digits only:
        /// "loginHandler.test.ts" → "loginhandlertest".
        let joined: String
        /// The folders above it, each joined the same way: "src/auth/login.css" → ["src", "auth"].
        let folders: [String]

        init?(_ reference: String) {
            let base = SpokenForms.basename(of: reference)
            let fileExtension = SpokenForms.fileExtension(of: reference)
            let stem = fileExtension.map { String(base.dropLast($0.count + 1)) } ?? base
            let letters = FileReferences.joinedLetters(SpokenForms.tokens(of: stem))
            guard !letters.isEmpty else { return nil }
            basename = base
            ext = fileExtension
            joined = letters
            folders = SpokenForms.pathSegments(of: reference).map { FileReferences.joinedLetters(SpokenForms.tokens(of: $0)) }
        }
    }

    /// Words that join the parts of a name when it is said, and are not part of it.
    private static let joiners: Set<String> = ["dot", "dash", "hyphen", "underscore"]

    private static func joinedLetters(_ parts: [String]) -> String {
        parts.joined().lowercased().precomposedStringWithCanonicalMapping
    }

    /// Whether consecutive tokens are one phrase: nothing between each pair but spaces, or a
    /// single `.`, `-` or `_` inside a word. Without it "Update the user. Card games are fun."
    /// joins "user" and "card" across the full stop into user-card.jsx, and "Open the login.
    /// CSS is broken." reads as login.css.
    private static func isOnePhrase(_ span: Range<Int>, tokens: [SpokenForms.SpokenToken], utf16: [UInt16]) -> Bool {
        guard span.lowerBound >= 0, span.upperBound <= tokens.count, span.count > 1 else { return true }
        for index in span.lowerBound..<(span.upperBound - 1) {
            let gapStart = tokens[index].start + tokens[index].length
            let gapEnd = tokens[index + 1].start
            guard gapStart <= gapEnd else { return false }
            let gap = utf16[gapStart..<gapEnd]
            if gap.isEmpty { continue }
            if gap.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { continue }
            if gap.count == 1, let unit = gap.first, unit == 0x2E || unit == 0x2D || unit == 0x5F { continue }
            return false
        }
        return true
    }

    /// Every run of words whose letters join to `target`, skipping spoken joiners inside it.
    private static func exactSpans(
        of target: String,
        in words: [String],
        tokens: [SpokenForms.SpokenToken],
        utf16: [UInt16]
    ) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var start = 0
        while start < words.count {
            guard !joiners.contains(words[start]), target.hasPrefix(words[start]) else {
                start += 1
                continue
            }
            var built = ""
            var end = start
            while end < words.count, built.count < target.count {
                if end > start, joiners.contains(words[end]) {
                    end += 1
                    continue
                }
                built += words[end]
                end += 1
                guard target.hasPrefix(built) else { break }
            }
            if built == target, isOnePhrase(start..<end, tokens: tokens, utf16: utf16) {
                spans.append(start..<end)
                start = end
            } else {
                start += 1
            }
        }
        return spans
    }

    /// The index just past a spoken extension that starts at `position`, or nil when none does.
    /// "dot" may lead it; the extension may be its own letters run together or spelled
    /// ("css", "c s s", "mp 4") or one of its spoken names ("typescript", "c plus plus").
    private static func extensionRun(
        of ext: String,
        from position: Int,
        in words: [String],
        tokens: [SpokenForms.SpokenToken],
        utf16: [UInt16]
    ) -> Int? {
        var index = position
        if index < words.count, words[index] == "dot" { index += 1 }
        guard index < words.count else { return nil }

        let lowered = ext.lowercased()
        var forms: Set<String> = [lowered]
        for alias in (spokenExtensions[lowered] ?? []) + (SpokenForms.extensionAliases[lowered] ?? []) {
            forms.insert(alias.replacingOccurrences(of: " ", with: ""))
        }
        let longest = forms.map(\.count).max() ?? 0

        var built = ""
        for end in index..<min(words.count, index + 5) {
            built += words[end]
            if forms.contains(built) {
                // From the last word of the name through the extension, all one phrase.
                return isOnePhrase(position - 1..<end + 1, tokens: tokens, utf16: utf16) ? end + 1 : nil
            }
            if built.count >= longest { break }
        }
        return nil
    }

    /// Where the reference starts once a spoken path in front of the name is taken with it:
    /// "src slash auth slash login dot css". Folders must be said in order, right to left from
    /// the name; "slash" between them is taken too.
    private static func pathStart(
        of name: Name,
        before position: Int,
        in words: [String],
        tokens: [SpokenForms.SpokenToken],
        utf16: [UInt16]
    ) -> Int {
        var start = position
        var index = position - 1
        var folder = name.folders.count - 1
        while index >= 0, folder >= 0 {
            if words[index] == "slash" {
                index -= 1
                continue
            }
            let aliases = SpokenForms.segmentAliases[name.folders[folder]] ?? []
            guard words[index] == name.folders[folder] || aliases.contains(words[index]),
                  isOnePhrase(index..<start + 1, tokens: tokens, utf16: utf16)
            else { break }
            start = index
            index -= 1
            folder -= 1
        }
        return start
    }

    /// The token span widened over whatever is glued to it, so the reference replaces the whole
    /// written name: "paid release.md" must not leave ".md" behind as "PAID-RELEASE.md.md". A
    /// joiner (`.`, `-`, `_`) counts only with a letter or digit after it, which keeps the full
    /// stop after "login.md." and a possessive's apostrophe where they are.
    private static func utf16Range(_ lower: Int, _ upper: Int, in utf16: [UInt16]) -> Range<Int> {
        func isAlnum(_ unit: UInt16) -> Bool {
            (0x30...0x39).contains(unit) || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
                || unit >= 0x80
        }
        func isJoiner(_ unit: UInt16) -> Bool { unit == 0x2E || unit == 0x2D || unit == 0x5F }

        var end = upper
        while end < utf16.count {
            if isAlnum(utf16[end]) {
                end += 1
            } else if isJoiner(utf16[end]), end + 1 < utf16.count, isAlnum(utf16[end + 1]) {
                end += 2
            } else {
                break
            }
        }
        var start = lower
        while start > 0 {
            if isAlnum(utf16[start - 1]) {
                start -= 1
            } else if isJoiner(utf16[start - 1]), start >= 2, isAlnum(utf16[start - 2]) {
                start -= 2
            } else {
                break
            }
        }
        return start..<end
    }

    /// Whether the words around a span are already a reference or a path — the model wrote one,
    /// or the speaker dictated "src/auth/login.css". Checked on the whole space-separated words,
    /// not the span: the tokenizer splits "@docs/login.ts" at the @ and the slashes, so the span
    /// alone contains neither, and tagging it again would produce "@docs/@docs/login.ts".
    private static func isAlreadyAReference(_ range: Range<Int>, in utf16: [UInt16]) -> Bool {
        func isSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D }
        var start = range.lowerBound
        var end = range.upperBound
        while start > 0, !isSpace(utf16[start - 1]) { start -= 1 }
        while end < utf16.count, !isSpace(utf16[end]) { end += 1 }
        return utf16[start..<end].contains { $0 == 0x2F || $0 == 0x40 || $0 == 0x60 }
    }
}
