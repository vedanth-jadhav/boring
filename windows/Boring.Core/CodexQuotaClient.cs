using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;

namespace Boring.Core;
public sealed record QuotaWindow(string Name, double Used, DateTimeOffset? Reset);
public sealed record LiveQuota(string Plan, List<QuotaWindow> Windows, string Credits, DateTimeOffset Updated);
/// <summary>Credentials are read only on an explicit refresh and sent solely to the fixed HTTPS endpoint.</summary>
public sealed class CodexQuotaClient : IDisposable
{
    private readonly HttpClient client;
    public CodexQuotaClient(HttpMessageHandler? handler = null) => client = new(handler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false }) { Timeout = TimeSpan.FromSeconds(12) };
    public async Task<LiveQuota> Refresh(string home) {
        var path = Path.Combine(home, "auth.json");
        if (!File.Exists(path)) throw new InvalidOperationException("Sign in with Codex CLI, then refresh. Select your Codex folder in Settings if needed.");
        using var auth = JsonDocument.Parse(await File.ReadAllTextAsync(path));
        if (!auth.RootElement.TryGetProperty("tokens", out var tokens) || !tokens.TryGetProperty("access_token", out var key) || string.IsNullOrWhiteSpace(key.GetString())) throw new InvalidOperationException("Plan allowance requires ChatGPT sign-in through Codex CLI. API-key accounts use the OpenAI billing dashboard.");
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://chatgpt.com/backend-api/wham/usage");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key.GetString());
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (tokens.TryGetProperty("account_id", out var account) && !string.IsNullOrEmpty(account.GetString())) request.Headers.Add("ChatGPT-Account-Id", account.GetString());
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);
        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden) throw new InvalidOperationException("Codex sign-in expired or is unavailable. Renew your session in Codex CLI.");
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException("Could not load plan allowance. Try again later.");
        await using var stream = await response.Content.ReadAsStreamAsync();
        using var json = JsonDocument.Parse(await LyricsProvider.ReadLimited(stream)); return Parse(json.RootElement, DateTimeOffset.UtcNow);
    }
    public static LiveQuota Parse(JsonElement data, DateTimeOffset now) {
        var windows = new List<QuotaWindow>();
        void Append(JsonElement limits, string prefix) {
            foreach (var (key, fallback) in new[] { ("primary_window", "Session"), ("secondary_window", "Weekly") }) {
                if (!limits.TryGetProperty(key, out var window) || window.ValueKind != JsonValueKind.Object || !window.TryGetProperty("used_percent", out var used) || !used.TryGetDouble(out var percent) || percent is < 0 or > 100 || !double.IsFinite(percent)) continue;
                DateTimeOffset? reset = null;
                if (window.TryGetProperty("reset_at", out var at) && at.TryGetInt64(out var seconds) && seconds is > 0 and < 253402300799) reset = DateTimeOffset.FromUnixTimeSeconds(seconds);
                else if (window.TryGetProperty("reset_after_seconds", out var after) && after.TryGetDouble(out var delay) && delay is >= 0 and <= 31536000) reset = now.AddSeconds(delay);
                var title = fallback;
                if (window.TryGetProperty("limit_window_seconds", out var length) && length.TryGetInt32(out var duration) && duration >= 3600) title = duration >= 604800 ? "Weekly" : $"{duration / 3600}-hour";
                windows.Add(new(prefix + title, percent, reset));
            }
        }
        if (data.TryGetProperty("rate_limit", out var limits) && limits.ValueKind == JsonValueKind.Object) Append(limits, "");
        if (data.TryGetProperty("additional_rate_limits", out var extras) && extras.ValueKind == JsonValueKind.Array) foreach (var extra in extras.EnumerateArray()) if (extra.TryGetProperty("rate_limit", out limits)) Append(limits, (extra.TryGetProperty("limit_name", out var name) ? name.GetString() : "Model") + " · ");
        var plan = data.TryGetProperty("plan_type", out var p) ? p.GetString() ?? "" : "";
        var credits = data.TryGetProperty("credits", out var c) && c.ValueKind == JsonValueKind.Object && c.TryGetProperty("balance", out var balance) ? balance.ToString() : "";
        if (windows.Count == 0 && plan.Length == 0 && credits.Length == 0) throw new InvalidOperationException("Codex returned an unfamiliar allowance response.");
        return new(plan, windows, credits, now);
    }
    public void Dispose() => client.Dispose();
}
