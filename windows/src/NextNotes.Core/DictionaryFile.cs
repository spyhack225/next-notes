using Speechify.Dictionary;

namespace Speechify.Core;

/// <summary>
/// The dictionary, persisted as a plain text file you can edit by hand.
/// </summary>
/// <remarks>
/// <para>
/// A text file rather than JSON, because the point is that it's editable outside the UI and
/// JSON is only nominally that — quoting, escaping, and a trailing-comma trap for anyone
/// adding a line in a hurry. One entry per line:
/// </para>
/// <code>
/// Anthropic
/// Vercel
/// cloud code -> Claude Code
/// # off: whisper flow -> Wispr Flow
/// </code>
/// <para>
/// A bare line is a term, <c>X -> Y</c> is a correction, <c>#</c> starts a comment, and a
/// disabled entry is written as <c># off:</c> so it survives a round trip rather than
/// silently disappearing.
/// </para>
/// <para>
/// Byte-compatible with the macOS build's <c>dictionary.txt</c>: the same file works on both.
/// </para>
/// </remarks>
public sealed class DictionaryFile
{
    private const string DisabledPrefix = "off:";
    private const string Arrow = "->";

    private static readonly char[] LineSeparators = ['\n', '\r'];

    private readonly string _path;
    private List<DictionaryEntry> _entries = [];

    /// <summary>Opens (and creates if needed) the dictionary at <paramref name="path"/>.</summary>
    public DictionaryFile(string path)
    {
        _path = path;
        Reload();
    }

    /// <summary>The default location, alongside the transcript history.</summary>
    public static string DefaultPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Speechify", "dictionary.txt");

    /// <summary>
    /// Where this dictionary lives on disk.
    /// </summary>
    /// <remarks>
    /// Not named <c>Path</c>: that would shadow <see cref="System.IO.Path"/> inside this
    /// class, breaking every static call to it.
    /// </remarks>
    public string FilePath => _path;

    /// <summary>Every entry, in file order.</summary>
    public IReadOnlyList<DictionaryEntry> Entries => _entries;

    /// <summary>Raised whenever the entries change.</summary>
    public event EventHandler? Changed;

    /// <summary>Re-reads the file, discarding in-memory state.</summary>
    public void Reload()
    {
        _entries = File.Exists(_path) ? Parse(File.ReadAllText(_path)) : [];
        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Parses the file format.</summary>
    public static List<DictionaryEntry> Parse(string text)
    {
        var entries = new List<DictionaryEntry>();

        foreach (var raw in text.Split(LineSeparators, StringSplitOptions.RemoveEmptyEntries))
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;

            var enabled = true;
            if (line.StartsWith('#'))
            {
                var stripped = line[1..].Trim();
                if (!stripped.StartsWith(DisabledPrefix, StringComparison.OrdinalIgnoreCase)) continue;

                line = stripped[DisabledPrefix.Length..].Trim();
                enabled = false;
                if (line.Length == 0) continue;
            }

            var arrow = line.IndexOf(Arrow, StringComparison.Ordinal);
            if (arrow >= 0)
            {
                var hear = line[..arrow].Trim();
                var write = line[(arrow + Arrow.Length)..].Trim();
                if (hear.Length == 0 || write.Length == 0) continue;

                entries.Add(new DictionaryEntry
                {
                    Kind = EntryKind.Correction, Hear = hear, Write = write, IsEnabled = enabled,
                });
            }
            else
            {
                entries.Add(new DictionaryEntry
                {
                    Kind = EntryKind.Term, Write = line, IsEnabled = enabled,
                });
            }
        }

        return entries;
    }

    /// <summary>Adds an entry and saves.</summary>
    public void Add(DictionaryEntry entry)
    {
        _entries.Add(entry);
        Save();
    }

    /// <summary>Replaces an entry by id and saves.</summary>
    public void Update(DictionaryEntry entry)
    {
        var index = _entries.FindIndex(e => e.Id == entry.Id);
        if (index < 0) return;

        _entries[index] = entry;
        Save();
    }

    /// <summary>Removes an entry and saves.</summary>
    public void Remove(Guid id)
    {
        _entries.RemoveAll(e => e.Id == id);
        Save();
    }

    /// <summary>Case-insensitive search across both sides of an entry.</summary>
    public IReadOnlyList<DictionaryEntry> Search(string query)
    {
        var trimmed = query.Trim();
        if (trimmed.Length == 0) return _entries;

        return _entries.Where(e =>
            e.Write.Contains(trimmed, StringComparison.OrdinalIgnoreCase) ||
            e.Hear.Contains(trimmed, StringComparison.OrdinalIgnoreCase)).ToList();
    }

    private void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);

        var body = string.Join(
            Environment.NewLine,
            _entries.Select(e => e.ToFileLine()));

        File.WriteAllText(_path, Header + body + Environment.NewLine, System.Text.Encoding.UTF8);

        Changed?.Invoke(this, EventArgs.Empty);
    }

    private static readonly string Header = string.Join(Environment.NewLine,
    [
        "# Speechify dictionary",
        "#",
        "#   Anthropic                 a term — the engine is told this word exists",
        "#   cloud code -> Claude Code a correction — when you hear X, write Y",
        "#   # off: some rule -> Rule  a disabled entry",
        "#",
        "# Edit this file directly if you like.",
        "",
        "",
    ]);
}
