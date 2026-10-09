using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Boring.Core;
public sealed partial class LyricsProvider : IDisposable
{
    private readonly HttpClient client;
    public LyricsProvider(HttpMessageHandler? handler = null) {
        client = new HttpClient(handler ?? new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(12) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("BoringNotchOctave-Windows/1.0 (+https://github.com/vedanth-jadhav/boring)");
    }
    public async Task<(List<LyricLine> Lines, string Plain)> Fetch(string title, string artist, double duration, string? root = null)
    {
        if (string.IsNullOrWhiteSpace(title) || string.IsNullOrWhiteSpace(artist)) throw new InvalidOperationException("Start a track first.");
        root ??= Settings.DataRoot;
        var identity = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes($"{title}|{artist}|{Math.Round(duration)}")));
        var cache = Path.Combine(root, "Lyrics", identity + ".json");
        string body;
        if (File.Exists(cache)) body = await File.ReadAllTextAsync(cache);
        else {
            var url = "https://lrclib.net/api/get?track_name=" + Uri.EscapeDataString(title) + "&artist_name=" + Uri.EscapeDataString(artist) + "&duration=" + Math.Round(duration).ToString(CultureInfo.InvariantCulture);
            using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
            if (response.StatusCode == System.Net.HttpStatusCode.NotFound) throw new InvalidOperationException("No lyrics found for this track.");
            response.EnsureSuccessStatusCode();
            await using var stream = await response.Content.ReadAsStreamAsync();
            body = Encoding.UTF8.GetString(await ReadLimited(stream));
            using var verify = JsonDocument.Parse(body);
            Directory.CreateDirectory(Path.GetDirectoryName(cache)!); await File.WriteAllTextAsync(cache, body);
        }
        using var json = JsonDocument.Parse(body); var source = json.RootElement;
        var synced = source.TryGetProperty("syncedLyrics", out var lyrics) && lyrics.ValueKind == JsonValueKind.String ? lyrics.GetString() ?? "" : "";
        var plain = source.TryGetProperty("plainLyrics", out var text) && text.ValueKind == JsonValueKind.String ? text.GetString() ?? "" : "";
        return (ParseLrc(synced), plain);
    }
    [GeneratedRegex(@"\[(\d+):(\d+(?:\.\d+)?)\]")]
    private static partial Regex Timestamps();
    public static List<LyricLine> ParseLrc(string source) {
        var lines = new List<LyricLine>();
        foreach (var row in source.Split('\n')) {
            var timestamps = Timestamps().Matches(row);
            if (timestamps.Count == 0) continue;
            var text = Timestamps().Replace(row, "").Trim();
            foreach (Match stamp in timestamps) {
                var time = double.Parse(stamp.Groups[1].Value, CultureInfo.InvariantCulture) * 60 + double.Parse(stamp.Groups[2].Value, CultureInfo.InvariantCulture);
                lines.Add(new(time, text, []));
            }
        }
        return lines.OrderBy(l => l.Time).ToList();
    }
    public static async Task<byte[]> ReadLimited(Stream stream, int limit = 4 * 1024 * 1024) {
        using var output = new MemoryStream(); var buffer = new byte[16384]; int read;
        while ((read = await stream.ReadAsync(buffer)) > 0) { if (output.Length + read > limit) throw new IOException("Response is too large."); output.Write(buffer, 0, read); }
        return output.ToArray();
    }
    public void Dispose() => client.Dispose();
}
