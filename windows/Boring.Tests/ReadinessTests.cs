using System.IO.Compression;
using System.Text;
using System.Text.Json;
using Boring.Core;
using Boring.Native;
using SkiaSharp;
using Xunit;

namespace Boring.Tests;
public sealed class ReadinessTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "Boring-tests-" + Guid.NewGuid());
    public ReadinessTests() => Directory.CreateDirectory(root);
    public void Dispose() => Directory.Delete(root, true);
    private sealed class Clock : TimeProvider {
        public DateTimeOffset Now = new(2026, 10, 8, 12, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => Now;
    }
    [Fact] public void FocusCountsSleepAndCompletesOnce() {
        var clock = new Clock(); var timer = new FocusTimer(clock); var completed = 0; timer.Completed += () => completed++;
        timer.Start(TimeSpan.FromMinutes(25)); clock.Now += TimeSpan.FromHours(1); timer.Tick(); timer.Tick();
        Assert.Equal(1, completed); Assert.False(timer.Running); Assert.Equal(TimeSpan.Zero, timer.Remaining);
    }
    [Fact] public void PausedFocusDoesNotCountTimeAndResumes() {
        var clock = new Clock(); var timer = new FocusTimer(clock); timer.Start(TimeSpan.FromMinutes(25)); clock.Now += TimeSpan.FromMinutes(5); timer.Pause();
        clock.Now += TimeSpan.FromHours(1); Assert.Equal(TimeSpan.FromMinutes(20), timer.Remaining); timer.Resume(); clock.Now += TimeSpan.FromMinutes(1);
        Assert.Equal(TimeSpan.FromMinutes(19), timer.Remaining); Assert.Throws<ArgumentOutOfRangeException>(() => timer.Start(TimeSpan.Zero));
    }
    [Fact] public void SettingsRoundTripRetainsFeatureChoices() {
        var settings = new Settings { Features = ["files"], Onboarded = true, Placement = "corner", Monitor = 2, Glass = false };
        settings.Save(root); var loaded = Settings.Load(root); Assert.Equal(settings.Features, loaded.Features); Assert.Equal("corner", loaded.Placement); Assert.False(loaded.Glass); Assert.True(loaded.Onboarded);
    }
    [Fact] public void InvalidSettingsArePreservedBeforeRecovery() {
        File.WriteAllText(Path.Combine(root, "settings.json"), "{broken"); var settings = Settings.Load(root);
        Assert.False(settings.Onboarded); Assert.Single(Directory.GetFiles(root, "settings.json.invalid-*"));
    }
    [Fact] public void FocusRestoresAcrossApplicationRestart() {
        var clock = new Clock(); var before = new FocusTimer(clock); before.Start(TimeSpan.FromMinutes(25));
        var settings = new Settings { Focus = before.Snapshot() }; settings.Save(root); clock.Now += TimeSpan.FromMinutes(10);
        var after = new FocusTimer(clock); after.Restore(Settings.Load(root).Focus); Assert.Equal(TimeSpan.FromMinutes(15), after.Remaining);
    }
    [Fact] public void MotionIsMonotonicAndReversesWithoutASnap() {
        var motion = new IslandMotion(); var small = new IslandBounds(500, 16, 400, 60); var large = new IslandBounds(380, 16, 640, 440);
        motion.Begin(small, large, .26, 0); var first = motion.Sample(.05); var second = motion.Sample(.1);
        Assert.True(second.Height > first.Height); Assert.True(second.Width > first.Width);
        var reversed = motion.Begin(second, small, .26, .1); Assert.Equal(second, reversed);
        Assert.True(motion.Sample(.15).Height < reversed.Height); Assert.Equal(small, motion.Sample(1)); Assert.False(motion.Active);
    }
    [Fact] public void AttestedRomanizationPreservesEnglishAndPunctuation() {
        var romanizer = new Romanizer(Path.Combine(AppContext.BaseDirectory, "Romanization"));
        var result = romanizer.Convert("दिल, hello!"); Assert.NotEqual("दिल, hello!", result); Assert.EndsWith(", hello!", result);
    }
    [Fact] public void PublicLyricsParserRetainsMultipleAndEmptyTimestamps() {
        var lines = LyricsProvider.ParseLrc("[00:01.50][00:03.050]Hello\n[00:05.005]\n[ar:Artist]");
        Assert.Equal(3, lines.Count); Assert.Equal(1.5, lines[0].Time); Assert.Equal(3.05, lines[1].Time); Assert.Equal("", lines[2].Text); Assert.All(lines, l => Assert.Empty(l.Words));
    }
    [Fact] public void LiveQuotaParsesWindowsAndIgnoresInvalidPercentages() {
        using var json = JsonDocument.Parse("""{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":42,"limit_window_seconds":18000,"reset_after_seconds":60},"secondary_window":{"used_percent":101}}}""");
        var now = DateTimeOffset.UtcNow; var quota = CodexQuotaClient.Parse(json.RootElement, now); Assert.Equal("plus", quota.Plan);
        Assert.Single(quota.Windows); Assert.Equal("5-hour", quota.Windows[0].Name); Assert.Equal(now.AddSeconds(60), quota.Windows[0].Reset);
    }
    [Fact] public void LyricsUseBrowserSampleClockAndRate() {
        var now = DateTimeOffset.UtcNow; var playback = new Playback();
        using var state = JsonDocument.Parse(JsonSerializer.Serialize(new { type = "state", title = "Song", artist = "Artist", playing = true, position = 10, duration = 100, rate = 2, sampledAt = now.AddSeconds(-1).ToUnixTimeMilliseconds() }));
        playback.Apply(state.RootElement, now); Assert.InRange(playback.CurrentPosition(now), 12, 12.01);
        using var lyrics = JsonDocument.Parse("""{"type":"lyrics","title":"Song","artist":"Artist","lines":[{"time":10,"text":"Hello","words":[{"start":10,"end":12,"text":"Hello"}]},{"time":10,"end":11,"text":"(oh)","isBackground":true,"words":[]}]}""");
        playback.Apply(lyrics.RootElement, now); Assert.Equal("Hello", playback.CurrentLine(13)?.Text); Assert.Null(playback.CurrentLine(13, true));
        Assert.Equal(0, Playback.WordPhase(new(10, 12, "Hello"), 12.1)); Assert.True(Playback.WordPhase(new(10, 12, "Hello"), 11) > .9);
    }
    [Fact] public void StaleTrackLyricsNeverReplaceCurrentTrack() {
        var playback = new Playback { Title = "New", Artist = "Artist" };
        using var old = JsonDocument.Parse("""{"type":"lyrics","title":"Old","artist":"Artist","lines":[{"time":0,"text":"wrong","words":[]}]}""");
        playback.Apply(old.RootElement, DateTimeOffset.UtcNow); Assert.Empty(playback.Lines);
    }
    [Fact] public async Task NativeFramesRoundTripAndRejectOversizedInput() {
        using var stream = new MemoryStream(); var payload = Encoding.UTF8.GetBytes("{\"type\":\"state\"}"); await OctavePipe.WriteFrame(stream, payload); stream.Position = 0;
        Assert.Equal(payload, await OctavePipe.ReadFrame(stream));
        await Assert.ThrowsAsync<IOException>(() => OctavePipe.ReadFrame(new MemoryStream([255, 255, 255, 127])));
        await Assert.ThrowsAsync<EndOfStreamException>(() => OctavePipe.ReadFrame(new MemoryStream([3, 0, 0, 0, 1])));
    }
    [Fact] public async Task ShelfCopiesAndDeletionPreserveOriginals() {
        var original = Path.Combine(root, "source.txt"); await File.WriteAllTextAsync(original, "keep me");
        var settings = new Settings(); var shelf = new Shelf(settings, root); var item = await shelf.Add(original);
        Assert.Equal("keep me", await File.ReadAllTextAsync(item.Path)); shelf.Remove(item); Assert.True(File.Exists(original)); Assert.False(File.Exists(item.Path));
        var foreign = new ShelfItem(original, "source.txt", DateTimeOffset.Now); settings.Shelf.Add(foreign); shelf.Remove(foreign); Assert.True(File.Exists(original));
    }
    [Fact] public async Task ZipKeepsSameNamedFilesDistinct() {
        var original = Path.Combine(root, "same.txt"); File.WriteAllText(original, "one"); var settings = new Settings(); var shelf = new Shelf(settings, root);
        var one = await shelf.Add(original); File.WriteAllText(original, "two"); var two = await shelf.Add(original); var archive = await shelf.Zip([one, two]);
        using var zip = ZipFile.OpenRead(archive.Path); Assert.Equal(2, zip.Entries.Count); Assert.Equal(2, zip.Entries.Select(e => e.Name).Distinct().Count());
    }
    [Fact] public async Task FolderShelfAndArchivePreserveTheSourceTree() {
        var source = Path.Combine(root, "project"); Directory.CreateDirectory(Path.Combine(source, "notes")); File.WriteAllText(Path.Combine(source, "notes", "readme.txt"), "original");
        var shelf = new Shelf(new Settings(), root); var item = await shelf.Add(source);
        var archive = await shelf.Zip([item]); using var zip = ZipFile.OpenRead(archive.Path);
        Assert.Contains(zip.Entries, entry => entry.FullName == "project/notes/readme.txt");
        shelf.Remove(item); Assert.True(File.Exists(Path.Combine(source, "notes", "readme.txt"))); Assert.False(Directory.Exists(item.Path));
    }
    [Fact] public void RecurringCalendarUsesEventTimezoneAndExcludesPastEvents() {
        var path = Path.Combine(root, "calendar.ics"); File.WriteAllText(path, "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Boring//Test//EN\r\nBEGIN:VEVENT\r\nUID:test\r\nDTSTART:20261008T150000Z\r\nDTEND:20261008T160000Z\r\nRRULE:FREQ=DAILY;COUNT=3\r\nSUMMARY:Daily focus\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n");
        var events = CalendarService.Read(path, new DateTimeOffset(2026, 10, 8, 17, 0, 0, TimeSpan.Zero));
        Assert.Equal(2, events.Count); Assert.All(events, e => Assert.Equal("Daily focus", e.Title)); Assert.Equal(9, events[0].Start.UtcDateTime.Day);
    }
    [Fact] public void CodexSnapshotsAndDuplicateSessionsAreNotDoubleCounted() {
        var sessions = Path.Combine(root, "sessions"); Directory.CreateDirectory(sessions);
        var text = """{"type":"session_meta","payload":{"id":"one"}}""" + "\n" +
            """{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}}""" + "\n" +
            """{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":30,"output_tokens":15}},"rate_limits":{"primary":{"used_percent":42}}}}""" + "\n";
        File.WriteAllText(Path.Combine(sessions, "one.jsonl"), text); File.WriteAllText(Path.Combine(sessions, "duplicate.jsonl"), text);
        var scanner = new CodexUsage(); var report = scanner.Scan(root); Assert.Equal(1, report.Sessions); Assert.Equal(150, report.Input); Assert.Equal(42d, report.PrimaryUsed);
        Assert.Equal(report, scanner.Scan(root));
    }
    [Fact] public async Task ImageConversionAndPdfMergeCreateReadableOutputs() {
        var path = Path.Combine(root, "image.png"); using (var bitmap = new SKBitmap(100, 50)) { bitmap.Erase(SKColors.Purple); using var image = SKImage.FromBitmap(bitmap); using var data = image.Encode(SKEncodedImageFormat.Png, 100); using var file = File.Create(path); data.SaveTo(file); }
        var shelf = new Shelf(new Settings(), root); var item = await shelf.Add(path); var small = await FileTools.Image(shelf, item, "jpg", 40);
        using var decoded = SKBitmap.Decode(small.Path); Assert.Equal(40, decoded.Width); Assert.Equal(20, decoded.Height);
        var pdf = await FileTools.Pdf(shelf, [item]); var merged = await FileTools.Pdf(shelf, [pdf, pdf]);
        using var document = PdfSharp.Pdf.IO.PdfReader.Open(merged.Path); Assert.Equal(2, document.PageCount);
    }
}
