using System.Text.Json;
using System.Text.Json.Serialization;
using Speechify.Dictionary;
using Shouldly;
using Xunit;

namespace Speechify.DictionaryTests;

/// <summary>
/// Runs the shared behavioural contract in <c>shared/dictionary-test-vectors.json</c>.
/// </summary>
/// <remarks>
/// The macOS app runs the identical file through its Swift implementation. Since the Windows
/// build cannot be exercised by hand, this is the primary evidence that the correction pass
/// behaves the way the product actually specifies.
/// </remarks>
public sealed class VectorTests
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
    };

    private static readonly Suite TheSuite = Load();

    public sealed record Suite(int Version, Case[] Cases);

    public sealed record Case(
        string Name,
        Entry[] Entries,
        string Input,
        string Expected,
        ExpectedCorrection[] ExpectedCorrections);

    public sealed record Entry(string Kind, string? Hear, string Write, bool? IsEnabled)
    {
        public DictionaryEntry ToEntry() => new()
        {
            Kind = Kind.Equals("correction", StringComparison.OrdinalIgnoreCase)
                ? EntryKind.Correction
                : EntryKind.Term,
            Write = Write,
            Hear = Hear ?? string.Empty,
            IsEnabled = IsEnabled ?? true,
        };
    }

    public sealed record ExpectedCorrection(string To, int Count);

    private static Suite Load()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "dictionary-test-vectors.json");
        var json = File.ReadAllText(path);
        return JsonSerializer.Deserialize<Suite>(json, JsonOptions)
               ?? throw new InvalidOperationException("Test vectors failed to deserialize.");
    }

    /// <summary>
    /// Case <i>names</i>, not case objects.
    /// </summary>
    /// <remarks>
    /// Passing a complex object through <c>MemberData</c> gives every row the same xUnit test
    /// ID, and xUnit then <b>silently skips</b> the duplicates — a suite that reports green
    /// while running one case out of nineteen. Passing a string keeps the IDs distinct.
    /// <see cref="Every_case_is_uniquely_named_and_the_suite_is_not_empty"/> is the guard that
    /// makes that failure mode impossible to reintroduce unnoticed.
    /// </remarks>
    public static TheoryData<string> CaseNames()
    {
        var data = new TheoryData<string>();
        foreach (var c in TheSuite.Cases) data.Add(c.Name);
        return data;
    }

    [Theory]
    [MemberData(nameof(CaseNames))]
    public void Shared_vector_produces_the_contracted_output(string caseName)
    {
        var testCase = TheSuite.Cases.Single(c => c.Name == caseName);
        var corrector = new DictionaryCorrector(testCase.Entries.Select(e => e.ToEntry()));

        var (text, applied) = corrector.Apply(testCase.Input);

        text.ShouldBe(testCase.Expected, $"case '{testCase.Name}'");
        applied.Count.ShouldBe(
            testCase.ExpectedCorrections.Length,
            $"case '{testCase.Name}': got [{string.Join(", ", applied.Select(a => a.To))}]");

        // Order-insensitive: which rule fires first is an implementation detail of the
        // longest-first sort. What fired, and how often, is contractual.
        foreach (var expected in testCase.ExpectedCorrections)
        {
            var match = applied.SingleOrDefault(a => a.To == expected.To);
            match.ShouldNotBeNull($"case '{testCase.Name}': expected a correction to “{expected.To}”");
            match.Count.ShouldBe(expected.Count, $"case '{testCase.Name}': count for “{expected.To}”");
        }
    }

    [Fact]
    public void Every_case_is_uniquely_named_and_the_suite_is_not_empty()
    {
        TheSuite.Cases.ShouldNotBeEmpty();
        TheSuite.Cases.Select(c => c.Name).Distinct(StringComparer.Ordinal).Count()
            .ShouldBe(TheSuite.Cases.Length, "duplicate case names would be silently skipped");
    }

    [Fact]
    public void Bias_list_is_capped_and_deduplicated()
    {
        var entries = Enumerable.Range(0, 100)
            .Select(i => DictionaryEntry.Term($"Word{i}"))
            .Append(DictionaryEntry.Term("Word0"))
            .ToList();

        var phrases = DictionaryCorrector.BiasPhrases(entries);

        phrases.Count.ShouldBe(DictionaryCorrector.BiasLimit);
        phrases.Distinct(StringComparer.OrdinalIgnoreCase).Count().ShouldBe(phrases.Count);
    }

    [Fact]
    public void Disabled_entries_are_excluded_from_biasing()
    {
        DictionaryEntry[] entries =
        [
            DictionaryEntry.Term("Kept"),
            DictionaryEntry.Term("Skipped") with { IsEnabled = false },
        ];

        DictionaryCorrector.BiasPhrases(entries).ShouldBe(["Kept"]);
    }

    [Fact]
    public void An_ordinary_word_used_as_a_trigger_is_flagged() =>
        DictionaryWarning.Check(DictionaryEntry.Correction("cloud", "Claude")).ShouldNotBeEmpty();

    [Fact]
    public void A_distinctive_phrase_is_not_flagged() =>
        DictionaryWarning.Check(DictionaryEntry.Correction("clawed code", "Claude Code")).ShouldBeEmpty();
}
