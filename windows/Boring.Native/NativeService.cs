using Boring.Core;
using System.Text.Json;
using SkiaSharp;

namespace Boring.Native;
public sealed class NativeService : IAsyncDisposable
{
    private readonly NativeUi ui;
    private readonly Settings settings = Settings.Load();
    private readonly WindowsServices windows = new();
    private readonly OctavePipe octave = new();
    private readonly FocusTimer focus = new();
    private readonly Shelf shelf;
    private readonly Romanizer romanizer = new(Path.Combine(AppContext.BaseDirectory, "Romanization"));
    private readonly LyricsProvider lyrics = new();
    private readonly CodexQuotaClient quota = new();
    private readonly CodexUsage usage = new();
    private readonly CancellationTokenSource stop = new();
    private readonly object output = new();
    private readonly HttpClient artworkClient = new(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(8) };
    private static readonly JsonSerializerOptions json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true };
    private Playback octavePlayback = new(), systemPlayback = new();
    private Playback Playback => settings.MusicSource == "octave" ? octavePlayback : systemPlayback;
    private bool connected, expanded, visualizing, mediaInitialized, systemInitialized, keepAwake;
    private string page = "music", artIdentity = "", artwork = "";
    private CameraMirror? camera;
    private DateTimeOffset? caffeineUntil;
    private IntPtr owner;
    private Task? ticking;
    public NativeService(NativeUi ui) {
        this.ui = ui; shelf = new(settings); focus.Restore(settings.Focus); keepAwake = settings.FocusAwake;
        caffeineUntil = settings.CaffeineDeadline > DateTimeOffset.UtcNow ? settings.CaffeineDeadline : null;
        windows.MediaChanged += media => ui.Post(() => {
            var changed = media.Title != systemPlayback.Title || media.Artist != systemPlayback.Artist;
            if (!changed) { media.Lines = systemPlayback.Lines; media.PlainLyrics = systemPlayback.PlainLyrics; }
            systemPlayback = media;
            if (settings.MusicSource == "system") { EmitMedia(); if (changed) EmitLyrics(); }
        });
        windows.AudioLevels += levels => Emit("audio", levels);
        windows.VolumeChanged += (volume, muted) => Emit("volume", new { volume, muted });
        octave.ConnectionChanged += value => ui.Post(() => {
            connected = value;
            if (!value) { octavePlayback.Position = octavePlayback.CurrentPosition(DateTimeOffset.UtcNow); octavePlayback.Playing = false; }
            if (settings.MusicSource == "octave") EmitMedia();
        });
        octave.Message += message => ui.Post(() => {
            try {
                var oldTitle = octavePlayback.Title; var oldArtist = octavePlayback.Artist;
                octavePlayback.Apply(message, DateTimeOffset.UtcNow);
                if (settings.MusicSource != "octave") return;
                EmitMedia();
                if (message.GetProperty("type").GetString() is "lyrics" or "gone" || oldTitle != octavePlayback.Title || oldArtist != octavePlayback.Artist) EmitLyrics();
            } catch (Exception e) when (e is JsonException or InvalidOperationException or KeyNotFoundException) { Emit("notice", "Octave supplied an invalid message."); }
        });
        focus.Completed += () => { keepAwake = false; settings.Focus = null; settings.Save(); Emit("focusComplete", true); };
    }
    private void Emit(string name, object? value) { lock (output) Console.WriteLine(JsonSerializer.Serialize(new { @event = name, data = value }, json)); }
    private void Reply(int id, object? result, string? error = null) { lock (output) Console.WriteLine(JsonSerializer.Serialize(new { id, result, error }, json)); }
    public async Task<int> Run() {
        if (settings.Onboarded) await Initialize();
        Emit("ready", new { settings, windows = OperatingSystem.IsWindows() }); EmitMedia(); EmitLyrics(); EmitFocus(); EmitShelf();
        ticking = Tick(); var jobs = new List<Task>();
        // Console.In.ReadLineAsync may synchronously block on Windows. Keep its
        // wait off the STA so WinRT callbacks and our message pump remain live.
        while (await Task.Run(() => Console.In.ReadLine()) is { } line) {
            int id = 0;
            try {
                if (line.Length > 8 * 1024 * 1024) throw new IOException("Request too large.");
                using var request = JsonDocument.Parse(line); var root = request.RootElement; id = root.GetProperty("id").GetInt32();
                var method = root.GetProperty("method").GetString() ?? "";
                var args = root.TryGetProperty("args", out var argument) ? argument : default;
                // Do not let a network lookup or file conversion delay camera stop,
                // hover collapse or playback controls. Windows mutations resume on
                // the same STA context; each request has its own correlated reply.
                jobs.RemoveAll(job => job.IsCompleted); jobs.Add(Handle(id, method, args.ValueKind == JsonValueKind.Undefined ? args : args.Clone()));
            } catch (Exception e) { Reply(id, null, e.Message); }
        }
        await Task.WhenAny(Task.WhenAll(jobs), Task.Delay(2000)); return 0;
    }
    private async Task Handle(int id, string method, JsonElement args) { try { Reply(id, await Call(method, args)); } catch (Exception e) { Reply(id, null, e.Message); } }
    private async Task Initialize() {
        if (settings.Features.Contains("music") && !mediaInitialized) { mediaInitialized = true; octave.Start(); await windows.InitializeMedia(); }
        if (settings.Features.Contains("system") && !systemInitialized) { systemInitialized = true; windows.InitializeSystem(); }
    }
    private async Task<object?> Call(string method, JsonElement a) {
        switch (method) {
            case "development-cursor": return DevelopmentCursor.Read();
            case "owner": owner = new IntPtr(long.Parse(String(a, "handle"))); ApplyMaterial(); return true;
            case "settings":
                var map = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(JsonSerializer.Serialize(settings, json), json)!;
                foreach (var entry in a.EnumerateObject()) if (map.ContainsKey(entry.Name)) map[entry.Name] = entry.Value.Clone();
                var updated = JsonSerializer.Deserialize<Settings>(JsonSerializer.Serialize(map), json)!;
                updated.Features = updated.Features.Where(id => Settings.Groups.Any(g => g.Id == id)).Distinct().ToList();
                if (updated.Placement is not ("floating" or "edge" or "corner")) throw new ArgumentException("Unknown placement.");
                settings.Onboarded = updated.Onboarded; settings.Features = updated.Features; settings.Placement = updated.Placement;
                settings.Monitor = Math.Max(0, updated.Monitor); settings.Glass = updated.Glass; settings.ReducedMotion = updated.ReducedMotion;
                settings.HoverOpen = updated.HoverOpen; settings.AutoCollapse = updated.AutoCollapse; settings.HideInFullscreen = updated.HideInFullscreen;
                settings.StartAtLogin = updated.StartAtLogin; settings.Visualizer = updated.Visualizer; settings.Romanize = updated.Romanize;
                settings.MusicSource = updated.MusicSource == "octave" ? "octave" : "system"; settings.CodexHome = updated.CodexHome;
                settings.Save(); ApplyMaterial(); if (settings.Onboarded) await Initialize(); UpdateAudio(); Emit("settings", settings); EmitMedia(); EmitLyrics(); return settings;
            case "view":
                expanded = Boolean(a, "expanded"); page = String(a, "page"); UpdateAudio();
                if (!expanded || page != "mirror") await StopCamera(); return true;
            case "media":
                var action = String(a, "action");
                if (settings.MusicSource == "octave") { if (!connected) throw new InvalidOperationException("Open Octave in Brave and load the included extension."); await octave.Send(action, Number(a, "position")); }
                else await windows.MediaCommand(action, Number(a, "position")); return true;
            case "lyrics":
                var target = Playback; var title = target.Title; var artist = target.Artist;
                var result = await lyrics.Fetch(title, artist, target.Duration);
                if (Playback == target && target.Title == title && target.Artist == artist) { target.Lines = result.Lines; target.PlainLyrics = result.Plain; EmitLyrics(); }
                return "Lyrics provided by LRCLIB.";
            case "focus":
                switch (String(a, "action")) { case "start": focus.Start(TimeSpan.FromMinutes(Number(a, "minutes"))); break; case "pause": focus.Pause(); break; case "resume": focus.Resume(); break; case "reset": focus.Reset(); keepAwake = false; break; }
                if (a.TryGetProperty("awake", out _)) keepAwake = Boolean(a, "awake");
                settings.Focus = focus.Snapshot(); settings.FocusAwake = keepAwake; settings.Save(); WindowsServices.KeepAwake(keepAwake && focus.Running || caffeineUntil > DateTimeOffset.UtcNow); EmitFocus(); return true;
            case "caffeine":
                caffeineUntil = Boolean(a, "enabled") ? DateTimeOffset.UtcNow.AddMinutes(Math.Clamp(Number(a, "minutes"), 1, 1440)) : null;
                settings.CaffeineDeadline = caffeineUntil; settings.Save(); WindowsServices.KeepAwake(caffeineUntil != null || keepAwake && focus.Running); EmitFocus(); return true;
            case "calendar": return Calendar();
            case "calendar-import":
                foreach (var path in Paths(a)) { _ = CalendarService.Read(path, DateTimeOffset.Now); var directory = Path.Combine(Settings.DataRoot, "Calendars"); Directory.CreateDirectory(directory); var copy = Path.Combine(directory, Guid.NewGuid() + ".ics"); File.Copy(path, copy); settings.CalendarFiles.Add(copy); }
                settings.Save(); return Calendar();
            case "calendar-remove": settings.CalendarFiles.Remove(String(a, "path")); settings.Save(); return Calendar();
            case "reminder-add":
                var text = String(a, "text").Trim(); if (text.Length is 0 or > 2000) throw new ArgumentException("Enter a reminder.");
                settings.Reminders.Add(new(Guid.NewGuid().ToString(), text, DateTimeOffset.Now.AddMinutes(Math.Clamp(Number(a, "minutes"), 1, 10080)))); settings.Save(); Emit("settings", settings); return settings.Reminders;
            case "reminder-done":
                var index = settings.Reminders.FindIndex(r => r.Id == String(a, "id")); if (index >= 0) settings.Reminders[index] = settings.Reminders[index] with { Done = Boolean(a, "done") }; settings.Save(); Emit("settings", settings); return settings.Reminders;
            case "shelf-add": foreach (var path in Paths(a)) await shelf.Add(path); EmitShelf(); return settings.Shelf;
            case "shelf-remove": foreach (var item in Selection(a)) shelf.Remove(item); EmitShelf(); return settings.Shelf;
            case "zip": await shelf.Zip(Selection(a)); EmitShelf(); return settings.Shelf;
            case "pdf": await FileTools.Pdf(shelf, Selection(a)); EmitShelf(); return settings.Shelf;
            case "image": foreach (var item in Selection(a)) await FileTools.Image(shelf, item, String(a, "format"), (int)Number(a, "width")); EmitShelf(); return settings.Shelf;
            case "save-copies":
                var destination = String(a, "folder"); foreach (var item in Selection(a)) { var path = Path.Combine(destination, item.Name); if (File.Exists(path) || Directory.Exists(path)) throw new IOException("An item named " + item.Name + " already exists."); if (Directory.Exists(item.Path)) await Task.Run(() => Shelf.CopyDirectory(item.Path, path)); else File.Copy(item.Path, path); } return true;
            case "screenshot":
                var capture = await ScreenCapture.Capture(); try { await shelf.Add(capture); } finally { File.Delete(capture); } EmitShelf(); return settings.Shelf;
            case "share": await WindowsSharing.Share(ui.Window, Selection(a).Select(i => i.Path).ToArray()); return true;
            case "volume": windows.Volume = (float)Math.Clamp(Number(a, "value"), 0, 1); return true;
            case "mute": windows.Muted = !windows.Muted; return true;
            case "brightness": await WindowsServices.Brightness((int)Number(a, "value")); return true;
            case "system": return new { battery = WindowsServices.Battery(), volume = OperatingSystem.IsWindows() ? windows.Volume : 0, muted = OperatingSystem.IsWindows() && windows.Muted };
            case "usage": return await Task.Run(() => usage.Scan(settings.CodexHome));
            case "quota": return await quota.Refresh(settings.CodexHome);
            case "mirror":
                await StopCamera(); if (!expanded || page != "mirror") return false; camera = new();
                camera.Frame += (pixels, width, height) => {
                    using var bitmap = new SKBitmap(new SKImageInfo(width, height, SKColorType.Bgra8888, SKAlphaType.Premul));
                    System.Runtime.InteropServices.Marshal.Copy(pixels, 0, bitmap.GetPixels(), pixels.Length);
                    using var image = SKImage.FromBitmap(bitmap); using var data = image.Encode(SKEncodedImageFormat.Jpeg, 78);
                    Emit("camera", "data:image/jpeg;base64," + Convert.ToBase64String(data.ToArray()));
                };
                camera.Error += error => Emit("notice", error); camera.Start(); return true;
            default: throw new ArgumentException("Unknown native operation.");
        }
    }
    private object Calendar() {
        var events = new List<AgendaEvent>(); var errors = new List<string>();
        foreach (var path in settings.CalendarFiles) { try { events.AddRange(CalendarService.Read(path, DateTimeOffset.Now)); } catch (Exception e) { errors.Add(Path.GetFileName(path) + ": " + e.Message); } }
        return new { events = events.OrderBy(e => e.Start).Take(30), files = settings.CalendarFiles, errors };
    }
    private void UpdateAudio() {
        var enabled = expanded && page == "music" && settings.Visualizer && settings.Features.Contains("music");
        if (enabled == visualizing) return; visualizing = enabled;
        try { windows.StartAudio(enabled); } catch (Exception e) { visualizing = false; Emit("notice", e.Message); }
    }
    private void EmitShelf() => Emit("shelf", settings.Shelf);
    private void ApplyMaterial() { var active = WindowsComposition.Apply(owner, settings.Glass); if (OperatingSystem.IsWindows()) Emit("material", active); }
    private void EmitFocus() => Emit("focus", new { running = focus.Running, paused = focus.Paused, seconds = focus.Remaining.TotalSeconds, deadline = settings.Focus?.Deadline, awake = keepAwake, caffeineSeconds = Math.Max(0, (caffeineUntil - DateTimeOffset.UtcNow)?.TotalSeconds ?? 0) });
    private void EmitMedia() {
        var p = Playback;
        Emit("media", new { p.Title, p.Artist, p.Source, p.Playing, p.Position, p.Duration, p.Rate, p.Sampled, connected, musicSource = settings.MusicSource, status = settings.MusicSource == "octave" ? connected ? "Octave" : "Waiting for Octave" : windows.MediaStatus });
        _ = Artwork(p);
    }
    private void EmitLyrics() {
        string ConvertText(string text) => settings.Romanize ? romanizer.Convert(text) : text;
        Emit("lyrics", new { plain = ConvertText(Playback.PlainLyrics), lines = Playback.Lines.Select(l => new { l.Time, text = ConvertText(l.Text), l.IsBackground, l.End, words = l.Words.Select(w => new { w.Start, w.End, text = ConvertText(w.Text) }) }) });
    }
    private async Task Artwork(Playback p) {
        var identity = p.Title + "|" + p.Artist + "|" + p.Artwork + (p.ArtworkData is { Length: > 0 } data ? Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(data)) : "");
        if (identity == artIdentity) return; artIdentity = identity; artwork = ""; Emit("artwork", "");
        try {
            var bytes = p.ArtworkData;
            if (bytes == null && p.Artwork.StartsWith("data:image/", StringComparison.Ordinal) && p.Artwork.Length < 4 * 1024 * 1024) {
                var separator = p.Artwork.IndexOf(",", StringComparison.Ordinal);
                if (separator > 0 && p.Artwork[..separator].EndsWith(";base64", StringComparison.Ordinal)) bytes = Convert.FromBase64String(p.Artwork[(separator + 1)..]);
            }
            if (bytes == null && Uri.TryCreate(p.Artwork, UriKind.Absolute, out var url) && url.Scheme == "https" && !url.IsLoopback && !System.Net.IPAddress.TryParse(url.Host, out _)) {
                using var response = await artworkClient.GetAsync(url, HttpCompletionOption.ResponseHeadersRead); response.EnsureSuccessStatusCode();
                await using var stream = await response.Content.ReadAsStreamAsync(); bytes = await LyricsProvider.ReadLimited(stream);
            }
            if (bytes == null || identity != artIdentity || stop.IsCancellationRequested) return;
            using var decoded = SKBitmap.Decode(bytes); if (decoded == null) return;
            using var resized = decoded.Resize(new SKImageInfo(180, 180), new SKSamplingOptions(SKCubicResampler.Mitchell));
            using var image = SKImage.FromBitmap(resized ?? decoded); using var encoded = image.Encode(SKEncodedImageFormat.Jpeg, 88);
            artwork = "data:image/jpeg;base64," + Convert.ToBase64String(encoded.ToArray()); Emit("artwork", artwork);
        } catch (Exception) { /* Artwork is optional; retain functional playback. */ }
    }
    private async Task Tick() {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1)); var count = 0;
        try { while (await timer.WaitForNextTickAsync(stop.Token)) {
            var active = focus.Running || focus.Paused || caffeineUntil != null;
            focus.Tick(); if (caffeineUntil <= DateTimeOffset.UtcNow) { caffeineUntil = null; settings.CaffeineDeadline = null; settings.Save(); }
            WindowsServices.KeepAwake(keepAwake && focus.Running || caffeineUntil != null); if (active) EmitFocus();
            foreach (var reminder in settings.Reminders.Where(r => !r.Done && r.Due <= DateTimeOffset.Now).ToArray()) {
                var index = settings.Reminders.FindIndex(r => r.Id == reminder.Id); settings.Reminders[index] = reminder with { Done = true }; settings.Save(); Emit("reminder", reminder.Text); Emit("settings", settings);
            }
            if (++count % 2 == 0 && settings.Features.Contains("system")) Emit("battery", WindowsServices.Battery());
            if (count % 2 == 0 && settings.HideInFullscreen && OperatingSystem.IsWindows()) Emit("fullscreen", WindowsServices.Fullscreen(owner));
        } } catch (OperationCanceledException) { }
    }
    private static string String(JsonElement a, string name) => a.ValueKind == JsonValueKind.Object && a.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
    private static double Number(JsonElement a, string name) => a.ValueKind == JsonValueKind.Object && a.TryGetProperty(name, out var v) && v.TryGetDouble(out var value) && double.IsFinite(value) ? value : 0;
    private static bool Boolean(JsonElement a, string name) => a.ValueKind == JsonValueKind.Object && a.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;
    private static string[] Paths(JsonElement a) => a.TryGetProperty("paths", out var paths) ? paths.EnumerateArray().Select(p => p.GetString()!).Where(p => !string.IsNullOrWhiteSpace(p)).ToArray() : [];
    private ShelfItem[] Selection(JsonElement a) { var paths = Paths(a); var items = settings.Shelf.Where(i => paths.Contains(i.Path)).ToArray(); return items.Length > 0 ? items : throw new ArgumentException("Select files first."); }
    private async Task StopCamera() { if (camera is { } current) { camera = null; await current.DisposeAsync(); } }
    public async ValueTask DisposeAsync() {
        stop.Cancel(); DevelopmentCursor.Close(); await StopCamera(); if (ticking != null) await ticking;
        settings.Focus = focus.Snapshot(); settings.Save(); windows.Dispose(); await octave.DisposeAsync(); artworkClient.Dispose(); lyrics.Dispose(); stop.Dispose();
    }
}
