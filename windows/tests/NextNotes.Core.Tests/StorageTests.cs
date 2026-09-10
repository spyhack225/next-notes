using NextNotes.Core;
using NextNotes.Dictionary;
using Shouldly;
using Xunit;

namespace NextNotes.CoreTests;

/// <summary>
/// The dictionary's plain-text file format.
/// </summary>
/// <remarks>
/// This format is shared with the macOS build — the same <c>dictionary.txt</c> is meant to
/// work on both — so round-tripping is a compatibility guarantee, not just tidiness.
/// </remarks>
public sealed class DictionaryFileTests : IDisposable
{
    private readonly string _path = Path.Combine(Path.GetTempPath(), $"NextNotes-dict-{Guid.NewGuid():N}.txt");

    public void Dispose()
    {
        if (File.Exists(_path)) File.Delete(_path);
    }

    [Fact]
    public void Parses_terms_corrections_comments_and_disabled_entries()
    {
        var entries = DictionaryFile.Parse("""
            # Next Notes dictionary
            # a plain comment is ignored

            Anthropic
            cloud code -> Claude Code
            # off: whisper flow -> Wispr Flow
            """);

        entries.Count.ShouldBe(3);

        entries[0].Kind.ShouldBe(EntryKind.Term);
        entries[0].Write.ShouldBe("Anthropic");
        entries[0].IsEnabled.ShouldBeTrue();

        entries[1].Kind.ShouldBe(EntryKind.Correction);
        entries[1].Hear.ShouldBe("cloud code");
        entries[1].Write.ShouldBe("Claude Code");

        // A disabled entry survives as a "# off:" comment rather than vanishing — otherwise
        // switching a rule off would quietly delete it on the next save.
        entries[2].Kind.ShouldBe(EntryKind.Correction);
        entries[2].Hear.ShouldBe("whisper flow");
        entries[2].IsEnabled.ShouldBeFalse();
    }

    [Fact]
    public void Round_trips_through_the_file()
    {
        var file = new DictionaryFile(_path);
        file.Add(DictionaryEntry.Term("Anthropic"));
        file.Add(DictionaryEntry.Correction("cloud code", "Claude Code"));
        file.Add(DictionaryEntry.Correction("whisper flow", "Wispr Flow") with { IsEnabled = false });

        var reopened = new DictionaryFile(_path);

        reopened.Entries.Count.ShouldBe(3);
        reopened.Entries[1].Hear.ShouldBe("cloud code");
        reopened.Entries[2].IsEnabled.ShouldBeFalse();
    }

    [Fact]
    public void Malformed_lines_are_skipped_rather_than_throwing()
    {
        // A hand-edited file will contain mistakes. One bad line must not lose the rest.
        var entries = DictionaryFile.Parse("Anthropic\n -> missing left side\nleft side -> \nVercel");

        entries.Count.ShouldBe(2);
        entries.Select(e => e.Write).ShouldBe(["Anthropic", "Vercel"]);
    }

    [Fact]
    public void Search_matches_both_sides_case_insensitively()
    {
        var file = new DictionaryFile(_path);
        file.Add(DictionaryEntry.Correction("cloud code", "Claude Code"));
        file.Add(DictionaryEntry.Term("Vercel"));

        file.Search("CLAUDE").Count.ShouldBe(1);
        file.Search("cloud").Count.ShouldBe(1);
        file.Search("verc").Count.ShouldBe(1);
        file.Search("").Count.ShouldBe(2);
    }

    [Fact]
    public void Update_and_remove_persist()
    {
        var file = new DictionaryFile(_path);
        var entry = DictionaryEntry.Term("Anthropc");
        file.Add(entry);

        file.Update(entry with { Write = "Anthropic" });
        new DictionaryFile(_path).Entries[0].Write.ShouldBe("Anthropic");

        file.Remove(entry.Id);
        new DictionaryFile(_path).Entries.ShouldBeEmpty();
    }
}

/// <summary>Transcript history persistence.</summary>
public sealed class TranscriptStoreTests : IDisposable
{
    private readonly string _path = Path.Combine(Path.GetTempPath(), $"NextNotes-hist-{Guid.NewGuid():N}.jsonl");

    public void Dispose()
    {
        if (File.Exists(_path)) File.Delete(_path);
    }

    private static TranscriptRecord Record(string text) => new()
    {
        At = DateTimeOffset.UtcNow,
        AudioSeconds = 2,
        ProcessingSeconds = 0.2,
        Text = text,
    };

    [Fact]
    public void Records_round_trip_newest_first()
    {
        var store = new TranscriptStore(_path);
        store.Add(Record("first"));
        store.Add(Record("second"));

        var reopened = new TranscriptStore(_path);

        reopened.Records.Count.ShouldBe(2);
        reopened.Records[0].Text.ShouldBe("second", "newest first is how the list reads");
    }

    [Fact]
    public void Corrections_survive_the_round_trip()
    {
        var store = new TranscriptStore(_path);
        store.Add(Record("Claude Code") with
        {
            Corrections = [new AppliedCorrection("cloud code", "Claude Code", 2)],
        });

        var reopened = new TranscriptStore(_path);
        var corrections = reopened.Records[0].Corrections;

        corrections.ShouldNotBeNull();
        corrections[0].To.ShouldBe("Claude Code");
        corrections[0].Count.ShouldBe(2);
    }

    [Fact]
    public void A_corrupt_line_does_not_destroy_the_rest_of_the_history()
    {
        var store = new TranscriptStore(_path);
        store.Add(Record("good one"));

        File.AppendAllText(_path, "{ this is not json" + Environment.NewLine);
        store.Add(Record("good two"));

        var reopened = new TranscriptStore(_path);
        reopened.Records.Count.ShouldBe(2, "one bad line must cost one record, not the file");
    }

    [Fact]
    public void Delete_removes_only_the_named_record_and_persists()
    {
        var store = new TranscriptStore(_path);
        store.Add(Record("keep me"));
        store.Add(Record("delete me"));

        var doomed = store.Records.Single(r => r.Text == "delete me");
        store.Remove(doomed.Id);

        new TranscriptStore(_path).Records.Select(r => r.Text).ShouldBe(["keep me"]);
    }

    [Fact]
    public void Appending_after_a_delete_still_reads_back_in_order()
    {
        // Deleting rewrites the file; a later append must not scramble the ordering.
        var store = new TranscriptStore(_path);
        store.Add(Record("one"));
        store.Add(Record("two"));
        store.Remove(store.Records.Single(r => r.Text == "one").Id);
        store.Add(Record("three"));

        new TranscriptStore(_path).Records.Select(r => r.Text).ShouldBe(["three", "two"]);
    }

    [Fact]
    public void Clear_empties_the_file()
    {
        var store = new TranscriptStore(_path);
        store.Add(Record("gone"));
        store.Clear();

        new TranscriptStore(_path).Records.ShouldBeEmpty();
    }
}

/// <summary>Settings persistence.</summary>
public sealed class AppSettingsTests : IDisposable
{
    private readonly string _path = Path.Combine(Path.GetTempPath(), $"NextNotes-set-{Guid.NewGuid():N}.json");

    public void Dispose()
    {
        if (File.Exists(_path)) File.Delete(_path);
    }

    [Fact]
    public void Defaults_to_right_ctrl_not_right_alt()
    {
        // Right Alt is AltGr on most European layouts; binding push-to-talk there breaks
        // typing @, €, \ and |. This default is a correctness decision, not a preference.
        new AppSettings(_path).Data.PushToTalkKey.ShouldBe(0xA3);
    }

    [Fact]
    public void Settings_round_trip()
    {
        var settings = new AppSettings(_path);
        settings.Update(settings.Data with { PushToTalkKey = 0x7C, InjectText = false });

        var reopened = new AppSettings(_path);
        reopened.Data.PushToTalkKey.ShouldBe(0x7C);
        reopened.Data.InjectText.ShouldBeFalse();
    }

    [Fact]
    public void Corrupt_settings_fall_back_to_defaults_rather_than_failing_to_launch()
    {
        File.WriteAllText(_path, "{ not json at all");

        new AppSettings(_path).Data.PushToTalkKey.ShouldBe(0xA3);
    }
}
