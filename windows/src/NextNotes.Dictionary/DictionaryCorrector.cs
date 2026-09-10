using System.Text;
using System.Text.RegularExpressions;

namespace Speechify.Dictionary;

/// <summary>One correction that actually fired.</summary>
public sealed record AppliedCorrection(string From, string To, int Count);

/// <summary>
/// Rewrites transcribed text using the dictionary's correction pairs.
/// </summary>
/// <remarks>
/// <para>
/// This is the guaranteed half of the dictionary. Engine biasing is a nudge — it raises the
/// odds of the right word and promises nothing — so anything that must be correct is fixed
/// here, after the fact, deterministically.
/// </para>
/// <para>
/// A direct counterpart to <c>DictionaryCorrector.swift</c>. The two are independent
/// implementations of one contract, and <c>shared/dictionary-test-vectors.json</c> is what
/// stops them drifting. <b>Change the semantics there first.</b>
/// </para>
/// <para>Three rules, all load-bearing:</para>
/// <list type="number">
/// <item><b>Longest match first.</b> "Claude Code" is applied before "Claude", so the longer
/// rule isn't pre-empted by a shorter one that overlaps it.</item>
/// <item><b>Whole matches only.</b> Every pattern is fenced by word boundaries, so a rule for
/// "cloud code" can never touch "Cloudflare" or the ordinary word "cloud".</item>
/// <item><b>Glued words still match.</b> Engines run words together — "CloudCode",
/// "cloud-code" — so the gap between parts is matched as optional whitespace or hyphens.</item>
/// </list>
/// </remarks>
public sealed class DictionaryCorrector
{
    /// <summary>
    /// Guards against a pathological dictionary hanging a dictation. Matching is linear here,
    /// so this should never trigger; it exists so that a bug can't wedge the app.
    /// </summary>
    private static readonly TimeSpan MatchTimeout = TimeSpan.FromSeconds(1);

    private static readonly char[] PhraseSeparators = [' ', '-', '\t'];

    private readonly List<Rule> _rules;

    private sealed record Rule(Regex Regex, string Replacement, string Trigger);

    /// <summary>Compiles the enabled correction entries into an ordered rule set.</summary>
    /// <param name="entries">The dictionary. Terms and disabled entries are ignored here.</param>
    public DictionaryCorrector(IEnumerable<DictionaryEntry> entries)
    {
        // Longest trigger first. Sorting by the trigger's length is what makes "Claude Code"
        // win over "Claude" — once the longer rule has rewritten the span, the shorter one no
        // longer sees the text it would have matched.
        //
        // OrderByDescending is a *stable* sort in LINQ, so equal-length triggers keep their
        // file order on both platforms. Swift's sort is not stable, but ties can only occur
        // between triggers of identical length, which cannot overlap the same span twice —
        // so the observable result is the same either way.
        _rules = entries
            .Where(e => e.IsEnabled && e.Kind == EntryKind.Correction)
            .Where(e => !string.IsNullOrWhiteSpace(e.Hear))
            .OrderByDescending(e => e.Hear.Length)
            .Select(e => MakeRule(e.Hear, e.Write))
            .OfType<Rule>()
            .ToList();
    }

    /// <summary>True when no enabled correction entry produced a usable rule.</summary>
    public bool IsEmpty => _rules.Count == 0;

    /// <summary>Applies every rule in order.</summary>
    /// <param name="text">Raw transcribed text.</param>
    /// <returns>The rewritten text, plus one entry per rule that fired.</returns>
    public (string Text, IReadOnlyList<AppliedCorrection> Applied) Apply(string text)
    {
        if (_rules.Count == 0 || string.IsNullOrEmpty(text)) return (text, []);

        // Normalize to NFC before matching, exactly as the Swift side does. Decomposed and
        // composed forms of the same accented word are different sequences of code points —
        // "café" is 4 or 5 depending on form — so an accented trigger silently never fires
        // unless both sides agree. This is part of the shared contract, not an optimisation.
        var result = text.Normalize(NormalizationForm.FormC);
        var applied = new List<AppliedCorrection>();

        foreach (var rule in _rules)
        {
            var matches = rule.Regex.Matches(result);
            if (matches.Count == 0) continue;

            // Record what the engine actually produced, not the rule's trigger — seeing the
            // real mishearing is the point, and it can differ in case or spacing
            // ("CloudCode" matched by "cloud code").
            var heard = matches[0].Value;

            // MatchEvaluator rather than a replacement string: it makes the replacement
            // strictly literal. A plain Replace would treat "$1", "$&" and friends in the
            // user's own text as substitutions, which is a real hazard when the replacement
            // is arbitrary user input.
            result = rule.Regex.Replace(result, _ => rule.Replacement);

            applied.Add(new AppliedCorrection(heard, rule.Replacement, matches.Count));
        }

        return (result, applied);
    }

    /// <summary>Builds the pattern for one trigger phrase.</summary>
    /// <remarks>
    /// <para>
    /// Parts are joined with <c>[\s\-]*</c> — zero or more spaces or hyphens — which catches
    /// "CloudCode" and "Cloud-Code" alongside the spaced form.
    /// </para>
    /// <para>
    /// The fences are lookarounds on letters and digits rather than <c>\b</c>. <c>\b</c>
    /// treats a trailing hyphen or apostrophe as a boundary and would let a rule bite into a
    /// longer word; requiring that no letter or digit sits on either side is the stricter
    /// guarantee, and it's what keeps "cloud code" off "Cloudflare".
    /// </para>
    /// </remarks>
    private static Rule? MakeRule(string trigger, string replacement)
    {
        // NFC here too, matching Apply(): a trigger typed into the UI and one read back from
        // the dictionary file can arrive in different normal forms.
        var parts = trigger
            .Normalize(NormalizationForm.FormC)
            .Trim()
            .Split(PhraseSeparators, StringSplitOptions.RemoveEmptyEntries)
            .Select(Regex.Escape)
            .ToArray();

        if (parts.Length == 0) return null;

        var body = string.Join(@"[\s\-]*", parts);
        var pattern = $@"(?<![\p{{L}}\p{{N}}]){body}(?![\p{{L}}\p{{N}}])";

        try
        {
            var regex = new Regex(pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, MatchTimeout);
            return new Rule(regex, replacement, trigger);
        }
        catch (ArgumentException)
        {
            return null;
        }
    }

    // ---- Engine biasing ----

    /// <summary>
    /// How many phrases to hand the speech engine as context.
    /// </summary>
    /// <remarks>
    /// Deliberately small. These models drift when given a long context list — on quiet or
    /// ambiguous audio they start inventing text from the vocabulary they were primed with,
    /// which is a far worse failure than the misspelling it was meant to fix.
    /// </remarks>
    public const int BiasLimit = 40;

    /// <summary>
    /// The correct spellings — Term words and the <i>write</i> side of corrections — capped
    /// at <see cref="BiasLimit"/>, de-duplicated case-insensitively, in file order.
    /// </summary>
    public static IReadOnlyList<string> BiasPhrases(IEnumerable<DictionaryEntry> entries)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var phrases = new List<string>();

        foreach (var entry in entries.Where(e => e.IsEnabled))
        {
            var phrase = entry.Write.Trim();
            if (phrase.Length == 0 || !seen.Add(phrase)) continue;
            phrases.Add(phrase);
            if (phrases.Count == BiasLimit) break;
        }

        return phrases;
    }
}
