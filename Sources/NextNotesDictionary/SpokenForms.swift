import Foundation

/// The two halves of turning a name a person can see into a name a person can say.
///
/// The design tension is that ASR gives us words and the screen gives us identifiers, and
/// neither side can be moved to the other. "loginHandler.tsx" is never what comes out of a
/// microphone, and "the login handler file" is never what is on the tab. So this type
/// generates the spoken shapes a name could take and scores a heard phrase against a
/// candidate (used to decide which of 200 harvested names are worth putting in front of a
/// model at all). Of those two halves only the scoring has a production caller today:
/// `biasPhrase(for:)` builds the engine's phrase from the same machinery without going through
/// `variants(of:)`, and the prompt's grounding list prints the real names verbatim rather than
/// spoken shapes of them. `variants` is pinned by the vectors and is what the Windows port
/// will be written against — said plainly here rather than left to read as a shipped seam. It
/// deliberately never *rewrites* text: resolution is the cleanup pass's job, because only
/// the model can see whether the sentence was actually referring to a file. Note the
/// asymmetry that follows from that — a wrong score costs a name in a list, where a wrong
/// rewrite costs the user a word they said.
///
/// This is a separate concern from `DictionaryCorrector`, and the split is not cosmetic.
/// The dictionary knows a finite set of pairs the user typed, and it *applies* them: a rule
/// either fires or it does not, and firing means the text changes. Here nothing is known in
/// advance — the vocabulary is whatever happened to be on screen half a second ago, most of
/// it irrelevant — and nothing is applied. Putting screen names into the dictionary's
/// machinery would mean either a regex per harvested name (200 regexes rewriting the user's
/// words on a guess) or a dictionary that silently grows every time somebody opens a
/// sidebar. Ranking and rewriting want opposite defaults, so they are two files.
///
/// Like `DictionaryCorrector`, this is a cross-platform contract: every constant, every
/// ordering rule and the scoring arithmetic are API rather than implementation detail, and
/// `shared/spoken-forms-test-vectors.json` is the specification both sides must satisfy.
/// Recorded honestly, per this repo's convention of writing gaps down rather than letting
/// the two implementations drift in silence: **the Windows side has no counterpart yet.**
/// There is no `SpokenForms.cs` under `windows/` and no C# runner for these vectors, so
/// today the file pins one implementation instead of holding two in agreement. It is
/// written as a contract anyway because retrofitting a contract onto a shipped heuristic is
/// how the dictionary nearly diverged, and because the vectors are what the port will be
/// written against when it exists.
///
/// Foundation only, on purpose: this target is the one CI can build, so anything that
/// reaches for AppKit, the accessibility API or `Speech` moves the logic somewhere no test
/// ever runs.
public enum SpokenForms {

    // MARK: - Tuning constants (part of the contract; the C# port copies these values)

    /// At or above this, a caller may treat the name as the thing that was said.
    public static let confidentScore: Double = 0.72

    /// At or above this, the name is worth showing the model but not worth spending ASR
    /// bias budget on. Below it, the name is noise and is dropped.
    public static let plausibleScore: Double = 0.55

    /// Maximum variants returned for one name. A cap rather than "all of them" because the
    /// caller's real budget is the prompt, and variants past the first handful are shapes
    /// nobody says.
    public static let variantLimit = 24

    /// How many harvested names may join the ASR bias list. See `mergedBiasPhrases`.
    public static let harvestedBiasShare = 10

    // MARK: - Tokenizing

    /// One word of a spoken phrase, with where it came from.
    ///
    /// Offsets are UTF-16 so the C# port is a transliteration rather than a translation —
    /// `String.Index` has no counterpart there and byte offsets disagree on anything
    /// non-ASCII.
    public struct SpokenToken: Sendable, Hashable, Codable {
        /// Lowercased, punctuation stripped, never empty.
        public let text: String
        /// UTF-16 offset into the string passed in.
        public let start: Int
        /// UTF-16 length in that string. This is the length of the *original* span, which is
        /// not always `text.utf16.count`: lowercasing "İ" produces two scalars where the
        /// source had one, and a caller highlighting the phrase needs the source's span.
        public let length: Int

        public init(text: String, start: Int, length: Int) {
            self.text = text
            self.start = start
            self.length = length
        }
    }

    /// Splits a heard phrase into comparable words. Lowercases, drops punctuation, keeps
    /// digit runs whole, and drops nothing else — filler removal happens in `score`, where
    /// it can be counted.
    ///
    /// Scalar scanning rather than `NSRegularExpression`: the port has to agree character
    /// for character, and two regex engines agreeing on what `\w` means across scripts is a
    /// bet nobody should take. A letter run and a digit run are separate tokens, so "v2"
    /// heard as one word still lines up with the two tokens `tokens(of:)` finds in "v2".
    public static func tokenize(spoken: String) -> [SpokenToken] {
        var tokens: [SpokenToken] = []
        var current = String.UnicodeScalarView()
        var currentStart = 0
        var currentLength = 0
        var currentIsDigit = false
        var offset = 0

        func flush() {
            guard !current.isEmpty else { return }
            // `lowercased()` here is Unicode default case mapping with no locale attached.
            // The C# port must use `ToLowerInvariant()`, not `ToLower()`, or a machine set to
            // Turkish lowercases "I" to a dotless ı and every key containing an I diverges.
            tokens.append(SpokenToken(
                text: String(current).lowercased(),
                start: currentStart,
                length: currentLength
            ))
            current = String.UnicodeScalarView()
            currentLength = 0
        }

        for scalar in spoken.unicodeScalars {
            let width = scalar.value > 0xFFFF ? 2 : 1
            let isDigit = Self.isASCIIDigit(scalar)
            let isLetter = scalar.properties.isAlphabetic

            if isDigit || isLetter {
                if !current.isEmpty && isDigit != currentIsDigit { flush() }
                if current.isEmpty {
                    currentStart = offset
                    currentIsDigit = isDigit
                }
                current.append(scalar)
                currentLength += width
            } else {
                flush()
            }
            offset += width
        }
        flush()

        return tokens
    }

    /// Splits an identifier into its semantic words: camelCase, snake_case, kebab-case,
    /// dots, slashes and digit boundaries. An acronym run stays one token ("APIClient"
    /// yields ["API", "Client"]), because the run is what carries the two pronunciations.
    ///
    /// Case is preserved — unlike `tokenize`, which lowercases. It has to be: the only
    /// evidence that "API" is spoken letter by letter and "Api" is not is the casing, and
    /// `biasPhrase` needs it back to write "API client" rather than "api client".
    public static func tokens(of name: String) -> [String] {
        var out: [String] = []
        var current: [Character] = []
        let chars = Array(name)

        func flush() {
            if !current.isEmpty {
                out.append(String(current))
                current = []
            }
        }

        for (i, c) in chars.enumerated() {
            guard c.isLetter || Self.isASCIIDigit(c) else {
                flush()
                continue
            }

            if let previous = current.last {
                let wasDigit = Self.isASCIIDigit(previous)
                let isDigit = Self.isASCIIDigit(c)
                // The third clause is the acronym rule: inside a run of capitals, the break
                // goes *before* the capital that starts a lowercase word, so "APIClient" is
                // API + Client and not APIC + lient.
                let boundary = wasDigit != isDigit
                    || (previous.isLowercase && c.isUppercase)
                    || (previous.isUppercase && c.isUppercase
                        && i + 1 < chars.count && chars[i + 1].isLowercase)
                if boundary { flush() }
            }
            current.append(c)
        }
        flush()

        return out
    }

    /// The last path segment. Everything user-facing works on this: the tab says
    /// "login.ts" and the person says "login dot ts".
    public static func basename(of name: String) -> String {
        let segments = Self.allSegments(of: name)
        return segments.last ?? ""
    }

    /// Path segments before the basename, in order, `/` and `\` both treated as separators.
    public static func pathSegments(of name: String) -> [String] {
        let segments = Self.allSegments(of: name)
        return segments.isEmpty ? [] : Array(segments.dropLast())
    }

    /// The extension without its dot, lowercased; nil when there is none or when the dot
    /// is leading (".gitignore" has no extension, it has a name).
    ///
    /// The suffix must also be alphanumeric and contain at least one letter, which is what
    /// keeps "v1.2.3" from claiming an extension of "3" and then scoring every phrase that
    /// says "three" as having named it. "archive.7z" still works, because the rule is "has a
    /// letter", not "starts with one".
    public static func fileExtension(of name: String) -> String? {
        let base = basename(of: name)
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return nil }

        let suffix = base[base.index(after: dot)...]
        guard !suffix.isEmpty else { return nil }
        guard suffix.allSatisfy({ $0.isLetter || Self.isASCIIDigit($0) }) else { return nil }
        guard suffix.contains(where: { $0.isLetter }) else { return nil }

        return suffix.lowercased()
    }

    // MARK: - Alias tables (public so the vectors can pin them and the port can copy them)

    /// How an extension is said out loud. Both the letters and the language.
    ///
    /// "jason" is in there on purpose: it is what ASR produces for "json" more often than
    /// "json" is.
    public static let extensionAliases: [String: [String]] = [
        "py": ["py", "python"],
        "ts": ["ts", "typescript"],
        "tsx": ["tsx", "typescript"],
        "jsx": ["jsx", "javascript"],
        "js": ["js", "javascript"],
        "md": ["md", "markdown"],
        "swift": ["swift"],
        "json": ["json", "jason"],
        "yml": ["yml", "yaml"],
        "yaml": ["yaml", "yml"],
    ]

    /// How a path segment is said out loud. Scoped to path segments rather than applied to
    /// every token, because "config" inside a name is usually the word and not an
    /// abbreviation anybody expands.
    public static let segmentAliases: [String: [String]] = [
        "src": ["source"],
        "lib": ["library"],
        "docs": ["documentation"],
        "pkg": ["package"],
        "img": ["image", "images"],
        "utils": ["utilities"],
        "config": ["configuration"],
        "tmp": ["temp", "temporary"],
    ]

    /// Words that carry no identifying information in a spoken file reference and are
    /// discarded before scoring.
    ///
    /// "dot" and "slash" are here rather than in the tokenizer because they are separators
    /// when spoken between words and filler when spoken anywhere else, and only the
    /// alignment can tell which.
    ///
    /// The cost is real and worth stating: a name whose own token *is* a filler word loses
    /// that token's slot. "fileStore.ts" heard as "the file store" scores 0.5 for coverage
    /// rather than 1.0, because "file" was thrown away before the walk. Making the drop
    /// conditional on the candidate would fix it and would also make the dropped count
    /// depend on which candidate is being scored, which is exactly the kind of asymmetry
    /// that a second implementation gets subtly wrong.
    ///
    /// One entry is in the set but exempt from the drop, and `score` says so where it does
    /// it: "a" survives, because a spelled-out acronym arrives as "a p i" and dropping the
    /// article would take the A of API with it.
    public static let spokenFiller: Set<String> = [
        "the", "a", "an", "my", "our", "that", "this", "file", "folder", "directory",
        "open", "in", "into", "from", "of", "called", "named", "dot", "slash",
    ]

    /// Names too common to spend bias budget on.
    ///
    /// Priming an ASR model with "index" cannot help — it already knows the word — and every
    /// slot spent here is a slot the user's own dictionary does not get.
    public static let commonNames: Set<String> = [
        "index", "main", "app", "test", "tests", "readme", "utils", "util", "config",
        "package", "types", "styles", "setup", "init", "api", "data", "view", "model",
    ]

    // MARK: - Variant generation

    /// Every plausible spoken shape of `name`, most likely first, deduplicated
    /// case-insensitively, capped at `limit`.
    ///
    /// Ordering is part of the contract, because callers truncate: the no-extension form
    /// comes first, then the forms that name the extension, then the path-carrying ones —
    /// the common case is "login handler dot tsx", not "source auth login handler", and a
    /// bare "login handler" is commoner still. Within the extension group the spelled-out
    /// aliases come before the letter-by-letter rendering, so "login handler typescript"
    /// outranks "login handler t s x". For an acronym run both pronunciations are emitted —
    /// "APIClient.swift" gives "a p i client" and "api client" — because ASR picks one and
    /// we cannot know which. Digit runs are emitted twice: digit-by-digit ("v two",
    /// "four oh four") and as a whole number ("four hundred four").
    public static func variants(of name: String, limit: Int = variantLimit) -> [String] {
        guard limit > 0 else { return [] }

        let base = basename(of: name)
        let ext = fileExtension(of: base)
        let stemTokens = tokens(of: Self.stem(of: base, extension: ext))
        guard !stemTokens.isEmpty else { return [] }

        let stems = Self.phrases(for: stemTokens)
        guard let primaryStem = stems.first else { return [] }

        var out: [String] = []
        var seen = Set<String>()

        func add(_ phrase: String) {
            let trimmed = phrase.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, out.count < limit else { return }
            guard seen.insert(trimmed.lowercased()).inserted else { return }
            out.append(trimmed)
        }

        // Group one: the basename with the extension left unsaid.
        for stem in stems { add(stem) }

        // Group two: the basename with the extension said.
        if let ext {
            for stem in stems {
                for spokenExt in Self.extensionPhrases(for: ext) {
                    add("\(stem) \(spokenExt)")
                }
            }
        }

        // Group three: path context, nearest first. Only the primary stem rendering takes
        // part — a path form of the second-choice pronunciation of an acronym is a shape
        // nobody has ever said, and it would push a real variant off the end of the cap.
        let segments = pathSegments(of: name)
        if let parent = segments.last {
            for spokenParent in Self.segmentPhrases(for: parent) {
                add("\(spokenParent) \(primaryStem)")
            }
            if let ext, let spokenExt = Self.extensionPhrases(for: ext).first {
                add("\(Self.segmentPhrases(for: parent)[0]) \(primaryStem) \(spokenExt)")
            }
        }
        if segments.count >= 2 {
            let literal = segments.map { Self.segmentPhrases(for: $0)[0] }
            add("\(literal.joined(separator: " ")) \(primaryStem)")
            let aliased = segments.map { Self.segmentPhrases(for: $0).last ?? $0 }
            add("\(aliased.joined(separator: " ")) \(primaryStem)")
        }

        return out
    }

    /// The single form to hand a speech engine as a contextual string, or nil when the name
    /// should not spend bias budget: fewer than 4 characters after joining, or a single
    /// token that is in `commonNames`.
    ///
    /// One form rather than all of them because `DictionaryCorrector.biasLimit` is 40 and
    /// the comment above it records what a long list does to these models on quiet audio.
    /// Casing is preserved for acronym runs ("API client") and lowercased elsewhere.
    ///
    /// The extension is left off. "login handler" is what primes the acoustic model; adding
    /// "tsx" spends the slot on a token the engine will write as letters anyway.
    public static func biasPhrase(for name: String) -> String? {
        let base = basename(of: name)
        let ext = fileExtension(of: base)
        let stemTokens = tokens(of: Self.stem(of: base, extension: ext))
        guard !stemTokens.isEmpty else { return nil }

        let phrase = stemTokens
            .map { Self.isAllUppercase($0) ? $0 : $0.lowercased() }
            .joined(separator: " ")

        guard phrase.count >= 4 else { return nil }
        if stemTokens.count == 1, commonNames.contains(stemTokens[0].lowercased()) { return nil }

        return phrase
    }

    // MARK: - Phonetics

    /// A Double Metaphone key pair. Two keys, not one, because English spellings of the
    /// same sound branch — and the branch is exactly where mishearing happens.
    public struct PhoneticKey: Sendable, Hashable, Codable {
        public let primary: String
        public let alternate: String?

        public init(primary: String, alternate: String?) {
            self.primary = primary
            self.alternate = alternate
        }

        /// True when either key of one matches either key of the other.
        public func matches(_ other: PhoneticKey) -> Bool {
            let mine = [primary, alternate ?? primary]
            let theirs = [other.primary, other.alternate ?? other.primary]
            guard !primary.isEmpty, !other.primary.isEmpty else { return false }
            for a in mine where theirs.contains(a) { return true }
            return false
        }
    }

    /// Double Metaphone (Philips' 2000 revision), keys truncated to 4 characters.
    ///
    /// Double Metaphone rather than Soundex or an edit distance: Soundex keys the first
    /// letter, so "cache"/"kash" never meet, and edit distance on short identifiers rates
    /// "login"/"logout" as close as "login"/"log in". The alternate key is what carries the
    /// cases that actually bite here — initial X, CH as K or X, GN, and Slavic-vs-Germanic
    /// J. It is spelled out in the vectors token by token, because a port that disagrees on
    /// one letter disagrees on every score downstream of it.
    ///
    /// A token with no letters at all — a digit run — keys to itself uppercased with no
    /// alternate, so "404" and "404" match and "404" and "405" do not. Sounding out digits
    /// is the variant generator's job, not this one's.
    public static func phoneticKey(for token: String) -> PhoneticKey {
        let letters = token.uppercased().filter { $0.isLetter && $0.isASCII }
        guard !letters.isEmpty else {
            return PhoneticKey(primary: token.uppercased(), alternate: nil)
        }
        return DoubleMetaphone.encode(Array(letters))
    }

    // MARK: - Scoring

    /// What a spoken phrase and a candidate name amount to.
    public struct Match: Sendable, Hashable {
        /// 0…1, clamped. The arithmetic is fixed by the contract — see `score(spoken:against:)`.
        public let score: Double
        /// Token indices into `tokenize(spoken:)` that the name was aligned to. Empty when
        /// nothing aligned. Callers that want character offsets read `start`/`length` off
        /// those tokens.
        public let spokenTokens: Range<Int>
        public let matchedTokenCount: Int
        public let nameTokenCount: Int
        /// The phrase named this candidate's extension by one of its aliases.
        public let namedExtension: Bool
        /// The phrase named a *different* extension. A caller may reject on this alone.
        public let namedOtherExtension: Bool

        public init(
            score: Double,
            spokenTokens: Range<Int>,
            matchedTokenCount: Int,
            nameTokenCount: Int,
            namedExtension: Bool,
            namedOtherExtension: Bool
        ) {
            self.score = score
            self.spokenTokens = spokenTokens
            self.matchedTokenCount = matchedTokenCount
            self.nameTokenCount = nameTokenCount
            self.namedExtension = namedExtension
            self.namedOtherExtension = namedOtherExtension
        }

        /// Treat the name as the thing that was said.
        public var isConfident: Bool { score >= SpokenForms.confidentScore }
        /// Worth putting in front of a model, not worth priming an ASR engine with.
        public var isPlausible: Bool { score >= SpokenForms.plausibleScore }

        public static let none = Match(
            score: 0,
            spokenTokens: 0..<0,
            matchedTokenCount: 0,
            nameTokenCount: 0,
            namedExtension: false,
            namedOtherExtension: false
        )
    }

    /// Scores one spoken phrase against one candidate name.
    ///
    /// The arithmetic, fixed so two implementations can agree:
    /// 1. Tokenize both sides; drop `spokenFiller` from the spoken side, counting how many.
    /// 2. Walk the name's tokens in order. A name token first tries its own spoken
    ///    renderings — the same ones `variants` emits — against the earliest run of
    ///    unconsumed spoken tokens that reproduces one of them, which is what lets the
    ///    single token "API" consume the three tokens "a p i" and "2" consume "two"; that
    ///    match weighs 1.0. Failing that, it takes the earliest single unconsumed token
    ///    that matches phonetically (0.9) or by a shared prefix (0.8).
    /// 3. coverage = sum of those weights / nameTokenCount.
    /// 4. −0.05 unless every match landed in increasing spoken order (a subsequence, not a
    ///    bag of words); +0.08 when `namedExtension`; −0.15 when `namedOtherExtension`.
    /// 5. −0.03 for each non-filler spoken token left over beyond a slack of 2.
    /// 6. Clamp to 0…1.
    ///
    /// In-order alignment rather than best-of-all-pairings because "handler login" is not
    /// how anyone refers to loginHandler, and a bag of words scores it identically.
    ///
    /// Step 4 spells the order rule as a penalty on the wrong shape rather than a bonus on
    /// the right one, and it has to: a phrase that matches every token of the name has a
    /// coverage of exactly 1.0, so a bonus added to it is thrown away by the clamp in step 6
    /// and "handler login" comes out equal to "login handler". The 0.05 is the same 0.05
    /// either way; putting it on the losing side is what makes it survive to the caller.
    ///
    /// The extension is *not* one of `nameTokenCount`'s tokens, and that is a deliberate
    /// departure from counting every token the name has. Counting it puts the headline
    /// utterance — "the login handler file" against loginHandler.tsx — at two matches out of
    /// three, which lands on 0.72 minus a rounding error: the exact case the feature exists
    /// for, sitting on the wrong side of the confidence line because the user did not
    /// pronounce a suffix nobody pronounces. Naming the extension is rewarded by the +0.08
    /// bonus instead, and naming the wrong one is punished, so the signal is still carried.
    public static func score(spoken: String, against name: String) -> Match {
        let heard = Heard(spoken)
        guard !heard.kept.isEmpty, let prepared = PreparedName(name) else { return .none }

        var consumed = [Bool](repeating: false, count: heard.kept.count)
        return heard.remapped(
            Self.aligned(prepared, in: heard, range: heard.kept.indices, consumed: &consumed)
        )
    }

    /// One tokenized utterance, with the filler already dropped.
    ///
    /// Split out of `score` so `bestMatch` can tokenize a paragraph once instead of once per
    /// window per candidate; the phonetic keys travel with it for the same reason. See the note
    /// on `bestMatch` for the measurement that made that worth doing.
    ///
    /// Public because the caller that matters is in another module: `ScreenContext.narrowed`
    /// scores 200 names against one transcript, and without a shape to hold the tokenizing in,
    /// it paid for 200 identical passes over the same paragraph. It is *not* new contract
    /// surface — every field is derived from `tokenize`, `isFiller` and `phoneticKey`, all three
    /// already pinned by the vectors — so the C# port may build the same cache or skip it
    /// without any score moving.
    public struct Heard {
        /// Every token of the original string, so a caller's offsets survive.
        public let all: [SpokenToken]
        /// The non-filler tokens, which are the only ones the alignment sees.
        public let kept: [String]
        /// `kept[i]` is `all[keptIndices[i]]`. Without the mapping a caller highlighting the
        /// phrase would land two words to the left of it as soon as anyone said "the".
        let keptIndices: [Int]
        /// `phoneticKey(for:)` per kept token, nil below the three characters
        /// `firstApproximate` refuses to guess at. Computed once because a Double Metaphone key
        /// is the single most expensive thing in a score and it does not depend on the name.
        let keys: [PhoneticKey?]

        public init(_ spoken: String) {
            var all: [SpokenToken] = []
            var kept: [String] = []
            var keptIndices: [Int] = []
            var keys: [PhoneticKey?] = []
            all = SpokenForms.tokenize(spoken: spoken)
            for (index, token) in all.enumerated() where !SpokenForms.isFiller(token.text) {
                keptIndices.append(index)
                kept.append(token.text)
                keys.append(token.text.count >= 3 ? SpokenForms.phoneticKey(for: token.text) : nil)
            }
            self.all = all
            self.kept = kept
            self.keptIndices = keptIndices
            self.keys = keys
        }

        /// Turns kept-token indices back into the caller's own token space.
        func remapped(_ match: Match) -> Match {
            guard !match.spokenTokens.isEmpty else { return match }
            let lower = keptIndices[match.spokenTokens.lowerBound]
            let upper = keptIndices[match.spokenTokens.upperBound - 1] + 1
            return Match(
                score: match.score,
                spokenTokens: lower..<upper,
                matchedTokenCount: match.matchedTokenCount,
                nameTokenCount: match.nameTokenCount,
                namedExtension: match.namedExtension,
                namedOtherExtension: match.namedOtherExtension
            )
        }
    }

    /// The half of a score that depends only on the name.
    ///
    /// Every field here was recomputed inside `score` on every call, which meant `bestMatch`
    /// rebuilt one candidate's renderings and extension sequences once per window — six times
    /// the transcript's length, for each of up to 200 candidates. Pure memoization: nothing
    /// here decides anything, so no score moves, which matters because that arithmetic is the
    /// contract `shared/spoken-forms-test-vectors.json` pins and the C# port has to reproduce.
    struct PreparedName {
        let nameTokens: [String]
        /// `renderings(ofNameToken:)` per name token, already split into word sequences.
        let renderings: [[[String]]]
        /// Lowercased name token, and its phonetic key where it is long enough to have one.
        let lowered: [String]
        let keys: [PhoneticKey?]
        let ext: String?
        let extensionSequences: [[String]]

        /// Nil when the name has no tokens to align — `score` returns `.none` for that.
        init?(_ name: String) {
            let base = SpokenForms.basename(of: name)
            let ext = SpokenForms.fileExtension(of: base)
            let nameTokens = SpokenForms.tokens(of: SpokenForms.stem(of: base, extension: ext))
            guard !nameTokens.isEmpty else { return nil }
            self.nameTokens = nameTokens
            self.renderings = nameTokens.map { token in
                SpokenForms.renderings(ofNameToken: token)
                    .map { $0.split(separator: " ").map(String.init) }
            }
            let lowered = nameTokens.map { $0.lowercased() }
            self.lowered = lowered
            // Three characters is `firstApproximate`'s own floor: below it every token is
            // phonetically near every other one, so no key is ever asked for.
            self.keys = lowered.map { $0.count >= 3 ? SpokenForms.phoneticKey(for: $0) : nil }
            self.ext = ext
            self.extensionSequences = ext.map { SpokenForms.extensionSequences(for: $0) } ?? []
        }
    }

    /// The scoring arithmetic itself, over one window of kept tokens.
    ///
    /// The only implementation of the steps documented on `score(spoken:against:)`; both public
    /// entry points go through here so there is one copy of the numbers rather than a fast path
    /// that can drift from the specified one. `spokenTokens` comes back in kept-token indices —
    /// `Heard.remapped` is what puts it into the caller's space.
    static func aligned(
        _ name: PreparedName,
        in heard: Heard,
        range: Range<Int>,
        consumed: inout [Bool]
    ) -> Match {
        guard !range.isEmpty else { return .none }
        for i in range { consumed[i] = false }

        let kept = heard.kept
        var weightSum = 0.0
        var matched = 0
        var starts: [Int] = []

        for (index, sequences) in name.renderings.enumerated() {
            if let run = Self.firstRun(of: sequences, in: kept, range: range, consumed: consumed) {
                for i in run { consumed[i] = true }
                weightSum += 1.0
                matched += 1
                starts.append(run.lowerBound)
                continue
            }
            if let (found, weight) = Self.firstApproximate(
                of: name.lowered[index],
                key: name.keys[index],
                in: heard,
                range: range,
                consumed: consumed
            ) {
                consumed[found] = true
                weightSum += weight
                matched += 1
                starts.append(found)
            }
        }

        // The extension is looked for only among what the name did not already claim, so a
        // name like "swift" in Package.swift cannot be counted twice.
        var namedExtension = false
        var namedOtherExtension = false
        if name.ext != nil,
           let run = Self.firstRun(
               of: name.extensionSequences,
               in: kept,
               range: range,
               consumed: consumed
           ) {
            namedExtension = true
            for i in run { consumed[i] = true }
        } else {
            for i in range where !consumed[i] {
                if Self.namesSomeOtherExtension(kept[i], than: name.ext) {
                    namedOtherExtension = true
                    break
                }
            }
        }

        guard matched > 0 || namedExtension else { return .none }

        var score = weightSum / Double(name.nameTokens.count)
        if matched > 0, starts != starts.sorted() { score -= 0.05 }
        if namedExtension { score += 0.08 }
        if namedOtherExtension { score -= 0.15 }

        let leftover = range.filter { !consumed[$0] }.count
        if leftover > 2 { score -= 0.03 * Double(leftover - 2) }
        score = min(1.0, max(0.0, score))

        // The span is closed over every consumed index rather than over the run starts,
        // because a run consumed more than its first token: "a p i" is one match and three
        // words, and a caller highlighting `spokenTokens` has to cover all three.
        let touched = range.filter { consumed[$0] }
        let lower = touched.first ?? range.lowerBound
        let upper = (touched.last ?? range.lowerBound) + 1

        return Match(
            score: score,
            spokenTokens: lower..<upper,
            matchedTokenCount: matched,
            nameTokenCount: name.nameTokens.count,
            namedExtension: namedExtension,
            namedOtherExtension: namedOtherExtension
        )
    }

    /// The best window of `transcript` that reads as a reference to `name`.
    ///
    /// Scores every contiguous run of 1…6 non-filler tokens and keeps the highest. Bounded
    /// at 6 because a spoken reference longer than that is a sentence, not a name. Ties go to
    /// the earliest window, and then to the shortest — a caller that highlights the span should
    /// not have it grow by two words that changed nothing.
    ///
    /// The window bound is *not* what makes narrowing 200 candidates affordable, which is what
    /// this comment used to claim. Six windows per token means ~6N `aligned` calls per
    /// candidate, so the cost is linear in the utterance and the constant factor is everything.
    /// With the name's renderings rebuilt and a Double Metaphone key recomputed for every word
    /// inside every window, 200 names against a 136-word transcript measured at 3.2 s of pure
    /// arithmetic optimised, which `DictationController` was paying on the main actor between
    /// transcription and injection. Hoisting that work into `Heard` and `PreparedName` — pure
    /// memoization, no score moved — took the same case to 0.13 s.
    public static func bestMatch(of name: String, in transcript: String) -> Match {
        let heard = Heard(transcript)
        return bestMatch(of: name, in: heard)
    }

    /// The same search against an already-tokenized transcript.
    ///
    /// This is the shape a caller with 200 candidates wants: `Heard` costs one pass over the
    /// utterance and is identical for every candidate, so tokenizing it per candidate was 199
    /// wasted passes. `ScreenContext.narrowed(toMentionsIn:)` is that caller.
    public static func bestMatch(of name: String, in heard: Heard) -> Match {
        guard !heard.kept.isEmpty, let prepared = PreparedName(name) else { return .none }

        // One scratch buffer for every window: `aligned` clears the range it is given, so the
        // allocation happens once per candidate rather than once per window.
        var consumed = [Bool](repeating: false, count: heard.kept.count)
        var best = Match.none
        for start in heard.kept.indices {
            for length in 1...6 where start + length <= heard.kept.count {
                let match = Self.aligned(
                    prepared,
                    in: heard,
                    range: start..<(start + length),
                    consumed: &consumed
                )
                guard match.score > best.score else { continue }
                best = heard.remapped(match)
            }
        }

        return best
    }

    // MARK: - The bias budget

    /// Merges the user's dictionary phrases with harvested screen names inside one ASR
    /// context budget.
    ///
    /// Lives here rather than in `DictionaryStore` for one reason that matters: CI cannot
    /// build the app target at all, so a merge written there is a merge nobody ever tests.
    /// The rules are absolute rather than proportional — dictionary entries win ties and
    /// keep their order, because the user typed those deliberately and a harvested name is a
    /// guess made from an accessibility tree.
    ///
    /// Contract: dictionary order is never disturbed; case-insensitive duplicates are
    /// dropped from the harvested side, never from the dictionary side; harvested names are
    /// appended in the order given (which is rank order) until either `harvestedShare` or
    /// the remaining room runs out; the result is never longer than `limit`.
    public static func mergedBiasPhrases(
        dictionary: [String],
        harvested: [String],
        limit: Int = DictionaryCorrector.biasLimit,
        harvestedShare: Int = harvestedBiasShare
    ) -> [String] {
        guard limit > 0 else { return [] }

        var out: [String] = []
        var seen = Set<String>()

        for phrase in dictionary {
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, out.count < limit else { continue }
            // Deliberately not de-duplicated: two dictionary rows that differ only in case
            // are the user's business, and re-ordering or dropping one of them here would
            // make the bias list disagree with the list the settings window shows.
            out.append(trimmed)
            seen.insert(trimmed.lowercased())
        }

        var taken = 0
        for phrase in harvested {
            guard taken < harvestedShare, out.count < limit else { break }
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            out.append(trimmed)
            taken += 1
        }

        return out
    }
}

// MARK: - Rendering helpers

private extension SpokenForms {
    static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x30 && scalar.value <= 0x39
    }

    static func isASCIIDigit(_ character: Character) -> Bool {
        character == "0" || character == "1" || character == "2" || character == "3"
            || character == "4" || character == "5" || character == "6" || character == "7"
            || character == "8" || character == "9"
    }

    /// Splits on both separators in one pass, dropping empties, so "src//auth/" and
    /// "src\auth" reduce to the same two segments. Windows hands back backslashes and
    /// Electron sidebars hand back forward slashes for the same file.
    static func allSegments(of name: String) -> [String] {
        name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
    }

    static func stem(of basename: String, extension ext: String?) -> String {
        guard let ext else { return basename }
        return String(basename.dropLast(ext.count + 1))
    }

    /// All uppercase, two to five letters: the shape that carries two pronunciations.
    ///
    /// A single capital is not an acronym — "AView" is "a view", not "ay view". The upper
    /// bound is what keeps "README.md" from generating "r e a d m e" as its *first* variant
    /// and pushing "readme" down the list: past five letters an all-caps token is a word
    /// somebody shouted, not initials somebody will spell.
    static func isAcronymRun(_ token: String) -> Bool {
        token.count >= 2 && token.count <= 5 && token.allSatisfy { $0.isLetter && $0.isUppercase }
    }

    /// Casing worth preserving in a bias phrase: any all-caps run, spelled out or not, since
    /// "HTTP server" is how the engine should write it back even though nobody spells
    /// "CHANGELOG".
    static func isAllUppercase(_ token: String) -> Bool {
        token.count >= 2 && token.allSatisfy { $0.isLetter && $0.isUppercase }
    }

    /// Filler is dropped before the walk, with one exception, and the exception is the whole
    /// reason this is a function: "a" is both the article and the first letter of API, and a
    /// spelled-out acronym reaches us as three separate tokens. Dropping it cost
    /// "a p i client swift" its match against APIClient.swift entirely — coverage halved and
    /// the score fell to 0.63, below the confidence line, for the one phrasing the acronym
    /// handling exists to serve. A single character left in the list costs one leftover slot,
    /// and the slack in step 5 absorbs it.
    static func isFiller(_ token: String) -> Bool {
        spokenFiller.contains(token) && token.count > 1
    }

    /// How one identifier token can be said, most likely first.
    ///
    /// The same list is used by `variants` to generate and by `score` to align, which is the
    /// only reason the two agree about "a p i" being one token's worth of speech.
    static func renderings(ofNameToken token: String) -> [String] {
        if isAcronymRun(token) {
            let spaced = token.lowercased().map(String.init).joined(separator: " ")
            let word = token.lowercased()
            return [spaced, word]
        }
        if token.allSatisfy(isASCIIDigit) {
            var out: [String] = []
            out.append(token.map { Self.digitWords[$0] ?? String($0) }.joined(separator: " "))
            if token.contains("0") {
                out.append(token.map { $0 == "0" ? "zero" : (Self.digitWords[$0] ?? String($0)) }
                    .joined(separator: " "))
            }
            // A leading zero means the run is an identifier, not a quantity: "007" is
            // "oh oh seven" and never "seven", so the whole-number form is suppressed.
            if !(token.count > 1 && token.first == "0"),
               let value = Int(token), let words = numberWords(value) {
                out.append(words)
            }
            out.append(token)
            return Self.deduplicated(out)
        }
        return [token.lowercased()]
    }

    /// "0" is "oh" rather than "zero" by default because that is what people say inside a
    /// name — "four oh four", "v zero point two" is the odd one out.
    static let digitWords: [Character: String] = [
        "0": "oh", "1": "one", "2": "two", "3": "three", "4": "four",
        "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "nine",
    ]

    static let smallNumberWords = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
        "seventeen", "eighteen", "nineteen",
    ]

    static let tensWords = [
        "", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
    ]

    /// English for 0…9999, or nil past that. Version and status numbers live inside that
    /// range; a hash or a timestamp is not something anyone reads out as a quantity, and
    /// generating "one billion two hundred..." for one would only add noise to the cap.
    static func numberWords(_ value: Int) -> String? {
        guard value >= 0, value <= 9999 else { return nil }
        if value < 20 { return smallNumberWords[value] }
        if value < 100 {
            let tens = tensWords[value / 10]
            let ones = value % 10
            return ones == 0 ? tens : "\(tens) \(smallNumberWords[ones])"
        }
        if value < 1000 {
            let hundreds = "\(smallNumberWords[value / 100]) hundred"
            let rest = value % 100
            return rest == 0 ? hundreds : "\(hundreds) \(numberWords(rest) ?? "")"
        }
        let thousands = "\(smallNumberWords[value / 1000]) thousand"
        let rest = value % 1000
        return rest == 0 ? thousands : "\(thousands) \(numberWords(rest) ?? "")"
    }

    /// The cartesian product of each token's renderings, all-first combination first.
    ///
    /// Capped at eight phrases. Two acronym runs and a digit run in one name is enough to
    /// generate twelve, and the ninth phrase is always a pronunciation nobody used spliced
    /// onto another one nobody used.
    static func phrases(for tokens: [String]) -> [String] {
        var out: [String] = [""]
        for token in tokens {
            let options = renderings(ofNameToken: token)
            var next: [String] = []
            for prefix in out {
                for option in options {
                    next.append(prefix.isEmpty ? option : "\(prefix) \(option)")
                    if next.count >= 8 { break }
                }
                if next.count >= 8 { break }
            }
            out = next
        }
        return deduplicated(out.filter { !$0.isEmpty })
    }

    /// How an extension can be said: the aliases first, then letter by letter.
    ///
    /// The letter-by-letter form is only generated up to four letters, because "s w i f t"
    /// is not a thing anybody says and every generated shape competes for the same cap.
    static func extensionPhrases(for ext: String) -> [String] {
        var out = extensionAliases[ext] ?? [ext]
        if ext.count >= 2, ext.count <= 4, ext.allSatisfy({ $0.isLetter }) {
            out.append(ext.map(String.init).joined(separator: " "))
        }
        return deduplicated(out)
    }

    /// The same list as word sequences, for the aligner.
    static func extensionSequences(for ext: String) -> [[String]] {
        extensionPhrases(for: ext).map { $0.split(separator: " ").map(String.init) }
    }

    /// A path segment as it is said: itself, then whatever the alias table expands it to.
    static func segmentPhrases(for segment: String) -> [String] {
        let key = segment.lowercased()
        var out = [key]
        out.append(contentsOf: segmentAliases[key] ?? [])
        return deduplicated(out)
    }

    static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

// MARK: - Alignment helpers

private extension SpokenForms {
    /// The earliest run of unconsumed spoken tokens that reproduces one of `sequences`.
    ///
    /// Positions are the outer loop so "earliest" means earliest in the sentence rather than
    /// earliest in the priority list; the priority list only decides which of two renderings
    /// wins at the *same* position.
    static func firstRun(
        of sequences: [[String]],
        in kept: [String],
        range: Range<Int>,
        consumed: [Bool]
    ) -> Range<Int>? {
        for start in range where !consumed[start] {
            for sequence in sequences where !sequence.isEmpty {
                guard start + sequence.count <= range.upperBound else { continue }
                var ok = true
                for offset in sequence.indices {
                    let i = start + offset
                    if consumed[i] || kept[i] != sequence[offset] {
                        ok = false
                        break
                    }
                }
                if ok { return start..<(start + sequence.count) }
            }
        }
        return nil
    }

    /// The earliest unconsumed token that sounds like the name token, and what it is worth.
    ///
    /// Takes the name token's key rather than computing it, and reads the heard tokens' keys
    /// off `Heard`. Both were recomputed per call — the name's once per window, the
    /// transcript's once per window per name token — and a Double Metaphone key is the most
    /// expensive step in the whole score.
    ///
    /// - Parameter key: nil below three characters, which is the same refusal the old code
    ///   spelled as an early return: every two-letter token is phonetically near every other
    ///   one, and a prefix rule on them matches on a single character. Short tokens match
    ///   exactly, through `firstRun`, or not at all.
    static func firstApproximate(
        of lowered: String,
        key: PhoneticKey?,
        in heard: Heard,
        range: Range<Int>,
        consumed: [Bool]
    ) -> (Int, Double)? {
        guard let key else { return nil }
        let kept = heard.kept

        for i in range where !consumed[i] {
            let candidate = kept[i]
            guard let candidateKey = heard.keys[i] else { continue }
            if key.matches(candidateKey) { return (i, 0.9) }

            // A bare "three shared characters" rule scores login/logout at 0.8 and then
            // hands the user a confident tag on the opposite function — the exact failure
            // the phonetic choice above is meant to avoid. Requiring the shared prefix to
            // cover 70% of the longer token keeps handler/handle and test/tests while
            // rejecting login/logout, and the arithmetic is integer so the port cannot
            // disagree about a rounding step.
            let shared = sharedPrefixLength(candidate, lowered)
            let longest = max(candidate.count, lowered.count)
            if shared >= 3, shared * 10 >= longest * 7 { return (i, 0.8) }
        }
        return nil
    }

    static func sharedPrefixLength(_ a: String, _ b: String) -> Int {
        var count = 0
        var i = a.startIndex
        var j = b.startIndex
        while i < a.endIndex, j < b.endIndex, a[i] == b[j] {
            count += 1
            i = a.index(after: i)
            j = b.index(after: j)
        }
        return count
    }

    /// True when `word` is how some *other* extension is said. The candidate's own
    /// extension is checked first by the caller, so "typescript" against a .ts file never
    /// reaches here even though it also aliases .tsx.
    static func namesSomeOtherExtension(_ word: String, than ext: String?) -> Bool {
        for (key, aliases) in extensionAliases {
            if key == ext { continue }
            if key == word || aliases.contains(word) {
                // Only report it when the candidate's own extension does not claim the same
                // word, or "typescript" beside a .tsx file would read as naming .ts.
                if let ext, extensionAliases[ext]?.contains(word) == true { continue }
                return true
            }
        }
        return false
    }
}

// MARK: - Double Metaphone

/// Philips' 2000 revision, transliterated rather than adapted.
///
/// Written out by hand instead of taken from a package because this target has no
/// dependencies by design — it is the half of the app CI can build — and because the C#
/// port has to produce the same keys character for character. A library on one side and a
/// different library on the other is two algorithms wearing one name.
///
/// The word is uppercased ASCII letters only before it arrives here, so the branches that
/// test for a trailing space in the original ("VAN ", "SAN ") are unreachable in this
/// codebase. They are kept anyway: deleting them would make a future port that feeds whole
/// names through this function disagree with this one, and a rule that never fires costs
/// nothing.
private enum DoubleMetaphone {
    static func encode(_ chars: [Character]) -> SpokenForms.PhoneticKey {
        var primary = ""
        var secondary = ""
        var hasAlternate = false
        let length = chars.count
        let last = length - 1

        func charAt(_ index: Int) -> Character {
            guard index >= 0, index < length else { return "\0" }
            return chars[index]
        }

        func stringAt(_ start: Int, _ count: Int, _ values: [String]) -> Bool {
            guard start >= 0, start + count <= length else { return false }
            let slice = String(chars[start..<(start + count)])
            return values.contains(slice)
        }

        func isVowel(_ c: Character) -> Bool {
            c == "A" || c == "E" || c == "I" || c == "O" || c == "U" || c == "Y"
        }

        func add(_ p: String, _ s: String) {
            primary += p
            secondary += s
            if p != s { hasAlternate = true }
        }

        // A W, a K, a CZ or a WITZ is the signal that Slavic and Germanic pronunciation
        // rules apply, and several branches below read differently because of it.
        let word = String(chars)
        let slavoGermanic = word.contains("W") || word.contains("K")
            || word.contains("CZ") || word.contains("WITZ")

        var current = 0
        // Silent first letters, plus the initial X that is said as an S ("Xavier").
        if stringAt(0, 2, ["GN", "KN", "PN", "WR", "PS"]) { current = 1 }
        if charAt(0) == "X" {
            add("S", "S")
            current = 1
        }

        while current < length {
            switch charAt(current) {
            case "A", "E", "I", "O", "U", "Y":
                if current == 0 { add("A", "A") }
                current += 1

            case "B":
                add("P", "P")
                current += charAt(current + 1) == "B" ? 2 : 1

            case "C":
                current = encodeC(
                    chars, current, length, last, slavoGermanic,
                    charAt, stringAt, isVowel, add
                )

            case "D":
                if stringAt(current, 2, ["DG"]) {
                    if stringAt(current + 2, 1, ["I", "E", "Y"]) {
                        add("J", "J")
                        current += 3
                    } else {
                        add("TK", "TK")
                        current += 2
                    }
                } else if stringAt(current, 2, ["DT", "DD"]) {
                    add("T", "T")
                    current += 2
                } else {
                    add("T", "T")
                    current += 1
                }

            case "F":
                add("F", "F")
                current += charAt(current + 1) == "F" ? 2 : 1

            case "G":
                current = encodeG(
                    chars, current, length, last, slavoGermanic,
                    charAt, stringAt, isVowel, add
                )

            case "H":
                // Only pronounced between two vowels, or at the start before one.
                if (current == 0 || isVowel(charAt(current - 1))), isVowel(charAt(current + 1)) {
                    add("H", "H")
                    current += 2
                } else {
                    current += 1
                }

            case "J":
                current = encodeJ(
                    chars, current, length, last, slavoGermanic,
                    charAt, stringAt, isVowel, add
                )

            case "K":
                add("K", "K")
                current += charAt(current + 1) == "K" ? 2 : 1

            case "L":
                add("L", "L")
                current += charAt(current + 1) == "L" ? 2 : 1

            case "M":
                // The silent B of "thumb"/"dumber": UMB at the end, or before ER.
                let dumb = stringAt(current - 1, 3, ["UMB"])
                    && (current + 1 == last || stringAt(current + 2, 2, ["ER"]))
                add("M", "M")
                current += (dumb || charAt(current + 1) == "M") ? 2 : 1

            case "N":
                add("N", "N")
                current += charAt(current + 1) == "N" ? 2 : 1

            case "P":
                if charAt(current + 1) == "H" {
                    add("F", "F")
                    current += 2
                } else {
                    add("P", "P")
                    current += stringAt(current + 1, 1, ["P", "B"]) ? 2 : 1
                }

            case "Q":
                add("K", "K")
                current += charAt(current + 1) == "Q" ? 2 : 1

            case "R":
                // French "Rogier": the final R goes quiet on the alternate key only.
                if current == last, !slavoGermanic, stringAt(current - 2, 2, ["IE"]),
                   !stringAt(current - 4, 2, ["ME", "MA"]) {
                    add("", "R")
                } else {
                    add("R", "R")
                }
                current += charAt(current + 1) == "R" ? 2 : 1

            case "S":
                current = encodeS(
                    chars, current, length, last, slavoGermanic,
                    charAt, stringAt, isVowel, add
                )

            case "T":
                if stringAt(current, 4, ["TION"]) {
                    add("X", "X")
                    current += 3
                } else if stringAt(current, 3, ["TIA", "TCH"]) {
                    add("X", "X")
                    current += 3
                } else if stringAt(current, 2, ["TH"]) || stringAt(current, 3, ["TTH"]) {
                    if stringAt(current + 2, 2, ["OM", "AM"])
                        || stringAt(0, 4, ["VAN ", "VON "]) || stringAt(0, 3, ["SCH"]) {
                        add("T", "T")
                    } else {
                        // "0" is the algorithm's spelling of theta, not a digit.
                        add("0", "T")
                    }
                    current += 2
                } else {
                    add("T", "T")
                    current += stringAt(current + 1, 1, ["T", "D"]) ? 2 : 1
                }

            case "V":
                add("F", "F")
                current += charAt(current + 1) == "V" ? 2 : 1

            case "W":
                current = encodeW(
                    chars, current, length, last, slavoGermanic,
                    charAt, stringAt, isVowel, add
                )

            case "X":
                // Silent in the French endings, "breaux" and "faux".
                if !(current == last
                    && (stringAt(current - 3, 3, ["IAU", "EAU"])
                        || stringAt(current - 2, 2, ["AU", "OU"]))) {
                    add("KS", "KS")
                }
                current += stringAt(current + 1, 1, ["C", "X"]) ? 2 : 1

            case "Z":
                if charAt(current + 1) == "H" {
                    add("J", "J")
                    current += 2
                } else {
                    if stringAt(current + 1, 2, ["ZO", "ZI", "ZA"])
                        || (slavoGermanic && current > 0 && charAt(current - 1) != "T") {
                        add("S", "TS")
                    } else {
                        add("S", "S")
                    }
                    current += charAt(current + 1) == "Z" ? 2 : 1
                }

            default:
                current += 1
            }
        }

        return SpokenForms.PhoneticKey(
            primary: String(primary.prefix(4)),
            alternate: hasAlternate ? String(secondary.prefix(4)) : nil
        )
    }

    // The four letters whose rules do not fit on one screen get a function each, so the
    // main switch stays readable as a map of the alphabet.

    private static func encodeC(
        _ chars: [Character], _ current: Int, _ length: Int, _ last: Int, _ slavoGermanic: Bool,
        _ charAt: (Int) -> Character, _ stringAt: (Int, Int, [String]) -> Bool,
        _ isVowel: (Character) -> Bool, _ add: (String, String) -> Void
    ) -> Int {
        if current > 1, !isVowel(charAt(current - 2)), stringAt(current - 1, 3, ["ACH"]),
           charAt(current + 2) != "I",
           charAt(current + 2) != "E" || stringAt(current - 2, 6, ["BACHER", "MACHER"]) {
            add("K", "K")
            return current + 2
        }
        if current == 0, stringAt(current, 6, ["CAESAR"]) {
            add("S", "S")
            return current + 2
        }
        if stringAt(current, 4, ["CHIA"]) {
            add("K", "K")
            return current + 2
        }
        if stringAt(current, 2, ["CH"]) {
            if current > 0, stringAt(current, 4, ["CHAE"]) {
                add("K", "X")
                return current + 2
            }
            if current == 0,
               stringAt(current + 1, 5, ["HARAC", "HARIS"])
                   || stringAt(current + 1, 3, ["HOR", "HYM", "HIA", "HEM"]),
               !stringAt(0, 5, ["CHORE"]) {
                add("K", "K")
                return current + 2
            }
            if stringAt(0, 4, ["VAN ", "VON "]) || stringAt(0, 3, ["SCH"])
                || stringAt(current - 2, 6, ["ORCHES", "ARCHIT", "ORCHID"])
                || stringAt(current + 2, 1, ["T", "S"])
                || ((stringAt(current - 1, 1, ["A", "O", "U", "E"]) || current == 0)
                    && stringAt(current + 2, 1, ["L", "R", "N", "M", "B", "H", "F", "V", "W", " "])) {
                add("K", "K")
                return current + 2
            }
            if current > 0 {
                if stringAt(0, 2, ["MC"]) { add("K", "K") } else { add("X", "K") }
            } else {
                add("X", "X")
            }
            return current + 2
        }
        if stringAt(current, 2, ["CZ"]), !stringAt(current - 2, 4, ["WICZ"]) {
            add("S", "X")
            return current + 2
        }
        if stringAt(current + 1, 3, ["CIA"]) {
            add("X", "X")
            return current + 3
        }
        if stringAt(current, 2, ["CC"]), !(current == 1 && charAt(0) == "M") {
            if stringAt(current + 2, 1, ["I", "E", "H"]), !stringAt(current + 2, 2, ["HU"]) {
                if (current == 1 && charAt(current - 1) == "A")
                    || stringAt(current - 1, 5, ["UCCEE", "UCCES"]) {
                    add("KS", "KS")
                } else {
                    add("X", "X")
                }
                return current + 3
            }
            add("K", "K")
            return current + 2
        }
        if stringAt(current, 2, ["CK", "CG", "CQ"]) {
            add("K", "K")
            return current + 2
        }
        if stringAt(current, 2, ["CI", "CE", "CY"]) {
            if stringAt(current, 3, ["CIO", "CIE", "CIA"]) { add("S", "X") } else { add("S", "S") }
            return current + 2
        }

        add("K", "K")
        if stringAt(current + 1, 2, [" C", " Q", " G"]) { return current + 3 }
        if stringAt(current + 1, 1, ["C", "K", "Q"]), !stringAt(current + 1, 2, ["CE", "CI"]) {
            return current + 2
        }
        return current + 1
    }

    private static func encodeG(
        _ chars: [Character], _ current: Int, _ length: Int, _ last: Int, _ slavoGermanic: Bool,
        _ charAt: (Int) -> Character, _ stringAt: (Int, Int, [String]) -> Bool,
        _ isVowel: (Character) -> Bool, _ add: (String, String) -> Void
    ) -> Int {
        if charAt(current + 1) == "H" {
            if current > 0, !isVowel(charAt(current - 1)) {
                add("K", "K")
                return current + 2
            }
            if current == 0 {
                if charAt(current + 2) == "I" { add("J", "J") } else { add("K", "K") }
                return current + 2
            }
            // Parker's rule: the GH of "hugh" and "bright" is silent.
            if (current > 1 && stringAt(current - 2, 1, ["B", "H", "D"]))
                || (current > 2 && stringAt(current - 3, 1, ["B", "H", "D"]))
                || (current > 3 && stringAt(current - 4, 1, ["B", "H"])) {
                return current + 2
            }
            if current > 2, charAt(current - 1) == "U",
               stringAt(current - 3, 1, ["C", "G", "L", "R", "T"]) {
                add("F", "F")
            } else if current > 0, charAt(current - 1) != "I" {
                add("K", "K")
            }
            return current + 2
        }

        if charAt(current + 1) == "N" {
            if current == 1, isVowel(charAt(0)), !slavoGermanic {
                add("KN", "N")
            } else if !stringAt(current + 2, 2, ["EY"]), charAt(current + 1) != "Y", !slavoGermanic {
                add("N", "KN")
            } else {
                add("KN", "KN")
            }
            return current + 2
        }

        if stringAt(current + 1, 2, ["LI"]), !slavoGermanic {
            add("KL", "L")
            return current + 2
        }

        if current == 0,
           charAt(current + 1) == "Y"
               || stringAt(current + 1, 2, ["ES", "EP", "EB", "EL", "EY", "IB", "IL", "IN", "IE", "EI", "ER"]) {
            add("K", "J")
            return current + 2
        }

        if stringAt(current + 1, 2, ["ER"]) || charAt(current + 1) == "Y",
           !stringAt(0, 6, ["DANGER", "RANGER", "MANGER"]),
           !stringAt(current - 1, 1, ["E", "I"]),
           !stringAt(current - 1, 3, ["RGY", "OGY"]) {
            add("K", "J")
            return current + 2
        }

        if stringAt(current + 1, 1, ["E", "I", "Y"]) || stringAt(current - 1, 4, ["AGGI", "OGGI"]) {
            if stringAt(0, 4, ["VAN ", "VON "]) || stringAt(0, 3, ["SCH"])
                || stringAt(current + 1, 2, ["ET"]) {
                add("K", "K")
            } else if stringAt(current + 1, 4, ["IER "]) {
                add("J", "J")
            } else {
                add("J", "K")
            }
            return current + 2
        }

        add("K", "K")
        return current + (charAt(current + 1) == "G" ? 2 : 1)
    }

    private static func encodeJ(
        _ chars: [Character], _ current: Int, _ length: Int, _ last: Int, _ slavoGermanic: Bool,
        _ charAt: (Int) -> Character, _ stringAt: (Int, Int, [String]) -> Bool,
        _ isVowel: (Character) -> Bool, _ add: (String, String) -> Void
    ) -> Int {
        // Spanish: "jose" and anything after "san " take an H sound.
        if stringAt(current, 4, ["JOSE"]) || stringAt(0, 4, ["SAN "]) {
            if (current == 0 && charAt(current + 4) == " ") || stringAt(0, 4, ["SAN "]) {
                add("H", "H")
            } else {
                add("J", "H")
            }
            return current + 1
        }

        if current == 0 {
            add("J", "A")
        } else if isVowel(charAt(current - 1)), !slavoGermanic,
                  charAt(current + 1) == "A" || charAt(current + 1) == "O" {
            add("J", "H")
        } else if current == last {
            add("J", "")
        } else if !stringAt(current + 1, 1, ["L", "T", "K", "S", "N", "M", "B", "Z"]),
                  !stringAt(current - 1, 1, ["S", "K", "L"]) {
            add("J", "J")
        }
        return current + (charAt(current + 1) == "J" ? 2 : 1)
    }

    private static func encodeS(
        _ chars: [Character], _ current: Int, _ length: Int, _ last: Int, _ slavoGermanic: Bool,
        _ charAt: (Int) -> Character, _ stringAt: (Int, Int, [String]) -> Bool,
        _ isVowel: (Character) -> Bool, _ add: (String, String) -> Void
    ) -> Int {
        // The silent S of "island" and "carlisle".
        if stringAt(current - 1, 3, ["ISL", "YSL"]) { return current + 1 }

        if current == 0, stringAt(current, 5, ["SUGAR"]) {
            add("X", "S")
            return current + 1
        }

        if stringAt(current, 2, ["SH"]) {
            if stringAt(current + 1, 4, ["HEIM", "HOEK", "HOLM", "HOLZ"]) {
                add("S", "S")
            } else {
                add("X", "X")
            }
            return current + 2
        }

        if stringAt(current, 3, ["SIO", "SIA"]) || stringAt(current, 4, ["SIAN"]) {
            if slavoGermanic { add("S", "S") } else { add("S", "X") }
            return current + 3
        }

        if (current == 0 && stringAt(current + 1, 1, ["M", "N", "L", "W"]))
            || stringAt(current + 1, 1, ["Z"]) {
            add("S", "X")
            return current + (stringAt(current + 1, 1, ["Z"]) ? 2 : 1)
        }

        if stringAt(current, 2, ["SC"]) {
            if charAt(current + 2) == "H" {
                if stringAt(current + 3, 2, ["OO", "ER", "EN", "UY", "ED", "EM"]) {
                    if stringAt(current + 3, 2, ["ER", "EN"]) { add("X", "SK") } else { add("SK", "SK") }
                } else if current == 0, !isVowel(charAt(3)), charAt(3) != "W" {
                    add("X", "S")
                } else {
                    add("X", "X")
                }
            } else if stringAt(current + 2, 1, ["I", "E", "Y"]) {
                add("S", "S")
            } else {
                add("SK", "SK")
            }
            return current + 3
        }

        // French "resnais": a final S after AI or OI is silent on the primary key.
        if current == last, stringAt(current - 2, 2, ["AI", "OI"]) {
            add("", "S")
        } else {
            add("S", "S")
        }
        return current + (stringAt(current + 1, 1, ["S", "Z"]) ? 2 : 1)
    }

    private static func encodeW(
        _ chars: [Character], _ current: Int, _ length: Int, _ last: Int, _ slavoGermanic: Bool,
        _ charAt: (Int) -> Character, _ stringAt: (Int, Int, [String]) -> Bool,
        _ isVowel: (Character) -> Bool, _ add: (String, String) -> Void
    ) -> Int {
        if stringAt(current, 2, ["WR"]) {
            add("R", "R")
            return current + 2
        }

        if current == 0, isVowel(charAt(current + 1)) || stringAt(current, 2, ["WH"]) {
            if isVowel(charAt(current + 1)) { add("A", "F") } else { add("A", "A") }
            return current + 1
        }

        // "Arnow" has to be able to meet "Arnoff", which is what the F alternate is for.
        if (current == last && isVowel(charAt(current - 1)))
            || stringAt(current - 1, 5, ["EWSKI", "EWSKY", "OWSKI", "OWSKY"])
            || stringAt(0, 3, ["SCH"]) {
            add("", "F")
            return current + 1
        }

        if stringAt(current, 4, ["WICZ", "WITZ"]) {
            add("TS", "FX")
            return current + 4
        }

        return current + 1
    }
}
