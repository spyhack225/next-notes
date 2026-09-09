using System.Text.Json;
using System.Text.Json.Serialization;

namespace Speechify.Core;

/// <summary>User preferences.</summary>
public sealed record SettingsData
{
    /// <summary>
    /// Virtual-key code of the push-to-talk key. Defaults to Right Ctrl (0xA3).
    /// </summary>
    /// <remarks>
    /// <b>Not Right Alt.</b> On German, Polish, UK, Nordic and most Latin-American layouts
    /// Right Alt is AltGr — it is how those users type <c>@</c>, <c>€</c>, <c>\</c> and
    /// <c>|</c>. Right Ctrl produces no character on any layout.
    /// </remarks>
    public int PushToTalkKey { get; init; } = 0xA3;

    /// <summary>Where the speech model lives, or null to search the default locations.</summary>
    public string? ModelDirectory { get; init; }

    /// <summary>Whether to type the transcript into the focused app.</summary>
    public bool InjectText { get; init; } = true;

    /// <summary>Whether to keep a transcript history.</summary>
    public bool KeepHistory { get; init; } = true;
}

/// <summary>Settings, persisted as JSON.</summary>
public sealed class AppSettings
{
    private readonly string _path;

    /// <summary>Loads settings from <paramref name="path"/>, or defaults if absent.</summary>
    public AppSettings(string path)
    {
        _path = path;
        Data = Load(path);
    }

    /// <summary>The default location.</summary>
    public static string DefaultPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Speechify", "settings.json");

    /// <summary>Current values.</summary>
    public SettingsData Data { get; private set; }

    /// <summary>Raised after a successful save.</summary>
    public event EventHandler? Changed;

    /// <summary>Replaces and persists the settings.</summary>
    public void Update(SettingsData data)
    {
        Data = data;

        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        File.WriteAllText(_path, JsonSerializer.Serialize(data, SettingsJsonContext.Default.SettingsData));

        Changed?.Invoke(this, EventArgs.Empty);
    }

    private static SettingsData Load(string path)
    {
        // Corrupt or unreadable settings must never stop the app launching — defaults are
        // always a working configuration.
        try
        {
            if (!File.Exists(path)) return new SettingsData();

            return JsonSerializer.Deserialize(File.ReadAllText(path), SettingsJsonContext.Default.SettingsData)
                   ?? new SettingsData();
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException)
        {
            return new SettingsData();
        }
    }
}

/// <summary>Source-generated JSON for settings.</summary>
[JsonSourceGenerationOptions(WriteIndented = true)]
[JsonSerializable(typeof(SettingsData))]
public sealed partial class SettingsJsonContext : JsonSerializerContext;
