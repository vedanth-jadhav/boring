using System.Text.Json;

namespace Boring.Core;

public sealed record FeatureGroup(string Id, string Title, string Description, string Icon);
public sealed class Settings
{
    public static readonly FeatureGroup[] Groups = [
        new("music", "Music & lyrics", "Playback controls, Octave lyrics and live audio visualization", "♫"),
        new("productivity", "Focus & your day", "Focus sessions, stay awake, calendar and reminders", "◷"),
        new("files", "Files & sharing", "Drag-and-drop shelf, screenshots, image/PDF tools and ZIP", "▧"),
        new("system", "Your PC & tools", "Battery, volume, brightness, camera mirror and Codex usage", "⌘")
    ];
    public int Version { get; set; } = 1;
    public bool Onboarded { get; set; }
    public List<string> Features { get; set; } = ["music", "productivity", "files", "system"];
    public string Placement { get; set; } = "floating";
    public int Monitor { get; set; }
    public bool Glass { get; set; } = true;
    public bool ReducedMotion { get; set; }
    public bool HoverOpen { get; set; } = true;
    public bool AutoCollapse { get; set; } = true;
    public FocusSnapshot? Focus { get; set; }
    public bool FocusAwake { get; set; }
    public DateTimeOffset? CaffeineDeadline { get; set; }
    public bool StartAtLogin { get; set; }
    public bool HideInFullscreen { get; set; } = true;
    public bool Visualizer { get; set; }
    public bool Romanize { get; set; } = true;
    public string MusicSource { get; set; } = "system";
    public string CodexHome { get; set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
    public List<string> CalendarFiles { get; set; } = [];
    public List<ShelfItem> Shelf { get; set; } = [];
    public List<Reminder> Reminders { get; set; } = [];
    public static string DataRoot => Environment.GetEnvironmentVariable("BORING_DATA_HOME") is { Length: > 0 } directory ? Path.GetFullPath(directory) : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BoringNotch");
    public static JsonSerializerOptions Json { get; } = new() { PropertyNameCaseInsensitive = true, WriteIndented = true };

    public static Settings Load(string? root = null)
    {
        var path = Path.Combine(root ?? DataRoot, "settings.json");
        try {
            var settings = JsonSerializer.Deserialize<Settings>(File.ReadAllText(path), Json) ?? new();
            settings.Features = settings.Features.Where(id => Groups.Any(g => g.Id == id)).Distinct().ToList();
            if (settings.Placement is not ("floating" or "edge" or "corner")) settings.Placement = "floating";
            settings.Monitor = Math.Max(0, settings.Monitor);
            return settings;
        } catch (FileNotFoundException) { return new(); }
        catch (DirectoryNotFoundException) { return new(); }
        catch (JsonException) { File.Copy(path, path + ".invalid-" + DateTime.UtcNow.Ticks); return new(); }
    }
    public void Save(string? root = null)
    {
        root ??= DataRoot;
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, "settings.json");
        var temp = path + "." + Guid.NewGuid() + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(this, Json));
        File.Move(temp, path, true);
    }
}
public sealed record ShelfItem(string Path, string Name, DateTimeOffset Added);
public sealed record Reminder(string Id, string Text, DateTimeOffset Due, bool Done = false);
