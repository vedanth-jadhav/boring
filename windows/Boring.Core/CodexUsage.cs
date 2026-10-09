using System.Text.Json;

namespace Boring.Core;
public sealed record UsageReport(long Input, long Cached, long Output, int Sessions, int Unreadable, double? PrimaryUsed, double? SecondaryUsed);
public sealed class CodexUsage
{
    private sealed record CachedFile(long Length, DateTime Modified, string? Session, long Input, long Cached, long Output, double? Primary, double? Secondary);
    private readonly Dictionary<string, CachedFile> cache = [];
    public UsageReport Scan(string home)
    {
        var files = new List<string>(); var unreadable = 0;
        foreach (var folder in new[] { "sessions", "archived_sessions" }) {
            var directory = Path.Combine(home, folder);
            if (!Directory.Exists(directory)) continue;
            try { files.AddRange(Directory.EnumerateFiles(directory, "*.jsonl", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true })); }
            catch (IOException) { unreadable++; }
        }
        var reports = new List<CachedFile>();
        foreach (var path in files) {
            try {
                var info = new FileInfo(path);
                if (!cache.TryGetValue(path, out var saved) || saved.Length != info.Length || saved.Modified != info.LastWriteTimeUtc) {
                    string? session = null; long input = 0, cached = 0, output = 0; double? primary = null, secondary = null;
                    using var reader = File.OpenText(path);
                    while (reader.ReadLine() is { } line) {
                        if (line.Length > 8 * 1024 * 1024 || (!line.Contains("token_count") && !line.Contains("session_meta"))) continue;
                        try {
                            using var json = JsonDocument.Parse(line); var root = json.RootElement;
                            if (!root.TryGetProperty("payload", out var payload)) continue;
                            if (root.TryGetProperty("type", out var type) && type.GetString() == "session_meta" && payload.TryGetProperty("id", out var id)) session = id.GetString();
                            if (payload.TryGetProperty("info", out var usage) && usage.TryGetProperty("total_token_usage", out var total)) {
                                // Cumulative totals are snapshots, not per-event deltas.
                                input = Math.Max(input, Count(total, "input_tokens")); cached = Math.Max(cached, Count(total, "cached_input_tokens")); output = Math.Max(output, Count(total, "output_tokens"));
                            }
                            if (payload.TryGetProperty("rate_limits", out var limits)) {
                                if (limits.TryGetProperty("primary", out var p) && p.TryGetProperty("used_percent", out var v)) primary = v.GetDouble();
                                if (limits.TryGetProperty("secondary", out var s) && s.TryGetProperty("used_percent", out v)) secondary = v.GetDouble();
                            }
                        } catch (JsonException) { /* A writer may still be appending the final row. */ }
                    }
                    saved = new(info.Length, info.LastWriteTimeUtc, session, input, cached, output, primary, secondary); cache[path] = saved;
                }
                reports.Add(saved);
            } catch (IOException) { unreadable++; } catch (UnauthorizedAccessException) { unreadable++; }
        }
        foreach (var stale in cache.Keys.Except(files).ToArray()) cache.Remove(stale);
        var unique = reports.OrderByDescending(r => r.Modified).GroupBy(r => r.Session ?? Guid.NewGuid().ToString()).Select(g => g.First()).ToList();
        var quota = unique.FirstOrDefault(r => r.Primary.HasValue || r.Secondary.HasValue);
        return new(unique.Sum(r => r.Input), unique.Sum(r => r.Cached), unique.Sum(r => r.Output), unique.Count, unreadable, quota?.Primary, quota?.Secondary);
    }
    private static long Count(JsonElement e, string name) => e.TryGetProperty(name, out var v) && v.TryGetInt64(out var count) ? Math.Max(0, count) : 0;
}
