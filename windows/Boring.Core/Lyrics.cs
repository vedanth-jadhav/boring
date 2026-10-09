using System.Text.Json;

namespace Boring.Core;
public sealed record LyricWord(double Start, double End, string Text);
public sealed record LyricLine(double Time, string Text, List<LyricWord> Words, bool IsBackground = false, double? End = null);
public sealed class Playback
{
    public string Title { get; set; } = "Nothing playing yet";
    public string Artist { get; set; } = "Play music in your favorite app";
    public string Source { get; set; } = "Windows media";
    public string Artwork { get; set; } = "";
    public byte[]? ArtworkData { get; set; }
    public bool Playing { get; set; }
    public double Duration { get; set; }
    public double Position { get; set; }
    public double Rate { get; set; } = 1;
    public DateTimeOffset Sampled { get; set; } = DateTimeOffset.UtcNow;
    public List<LyricLine> Lines { get; set; } = [];
    public string PlainLyrics { get; set; } = "";
    public double CurrentPosition(DateTimeOffset now) => Math.Clamp(Position + (Playing ? Math.Max(0, (now - Sampled).TotalSeconds) * Rate : 0), 0, Duration > 0 ? Duration : double.MaxValue);
    public void Apply(JsonElement message, DateTimeOffset now)
    {
        var type = message.GetProperty("type").GetString();
        if (type == "gone") { Title = "Nothing playing yet"; Artist = "Open Octave in Brave"; Playing = false; Artwork = ""; ArtworkData = null; Position = Duration = 0; Rate = 1; Sampled = now; Lines = []; PlainLyrics = ""; return; }
        var title = GetString(message, "title"); var artist = GetString(message, "artist");
        if (type == "lyrics") {
            if (title != Title || artist != Artist) return;
            Lines = message.TryGetProperty("lines", out var lines) ? JsonSerializer.Deserialize<List<LyricLine>>(lines, Settings.Json) ?? [] : [];
            Lines = Lines.Where(l => double.IsFinite(l.Time) && l.Time >= 0).OrderBy(l => l.Time).ToList();
            PlainLyrics = GetString(message, "plainLyrics"); return;
        }
        if (type != "state") return;
        if (title != Title || artist != Artist) { Lines = []; PlainLyrics = ""; }
        Title = string.IsNullOrEmpty(title) ? "Nothing playing yet" : title; Artist = artist; Source = "Octave · Brave"; Artwork = GetString(message, "artwork");
        Playing = message.TryGetProperty("playing", out var p) && p.ValueKind == JsonValueKind.True;
        Position = Number(message, "position"); Duration = Number(message, "duration");
        Rate = message.TryGetProperty("rate", out _) ? Number(message, "rate") : 1;
        Sampled = now;
        if (message.TryGetProperty("sampledAt", out var stamp) && stamp.TryGetDouble(out var milliseconds) && double.IsFinite(milliseconds) && milliseconds > 0 && milliseconds < 253402300799000) {
            var sampled = DateTimeOffset.FromUnixTimeMilliseconds((long)milliseconds);
            if (sampled <= now && now - sampled < TimeSpan.FromMinutes(1)) Sampled = sampled;
        }
    }
    public LyricLine? CurrentLine(double position, bool backing = false)
    {
        LyricLine? first = null, current = null;
        foreach (var line in Lines) {
            if (line.IsBackground != backing) continue;
            first ??= line;
            if (line.Time <= position) current = line; else break;
        }
        current ??= first;
        if (current == null) return null;
        if (backing && (position < current.Time || position > (current.End ?? current.Words.LastOrDefault()?.End ?? current.Time))) return null;
        return current;
    }
    public static double WordPhase(LyricWord word, double position) => word.End <= word.Start || position < word.Start || position > word.End ? 0 : Math.Min(1, Math.Min((position - word.Start) / Math.Min(.12, (word.End - word.Start) / 3), (word.End - position) / Math.Min(.18, (word.End - word.Start) / 3)));
    private static string GetString(JsonElement e, string key) => e.TryGetProperty(key, out var p) && p.ValueKind == JsonValueKind.String ? p.GetString() ?? "" : "";
    private static double Number(JsonElement e, string key) => e.TryGetProperty(key, out var p) && p.TryGetDouble(out var n) && double.IsFinite(n) ? Math.Max(0, n) : 0;
}
