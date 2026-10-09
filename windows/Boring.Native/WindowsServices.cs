using Boring.Core;
using System.Diagnostics;
using System.Runtime.InteropServices;
#if WINDOWS
using Microsoft.Win32;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.CoreAudioApi.Interfaces;
using Windows.Media.Control;
using Windows.Storage.Streams;
#endif

namespace Boring.Native;
public sealed class WindowsServices : IDisposable
{
    public event Action<Playback>? MediaChanged;
    private readonly SynchronizationContext? context = SynchronizationContext.Current;
    private void Dispatch(Action action) { if (context != null) context.Post(_ => action(), null); else action(); }
    public event Action? ToggleRequested;
    public event Action<float[]>? AudioLevels;
    public event Action<float, bool>? VolumeChanged;
    public string MediaStatus { get; private set; } = "Windows media sessions require Windows";
#if WINDOWS
    private GlobalSystemMediaTransportControlsSessionManager? media;
    private GlobalSystemMediaTransportControlsSession? session;
    private WasapiLoopbackCapture? capture;
    private MMDeviceEnumerator? devices;
    private MMDevice? output;
    private AudioNotifications? audioNotifications;
    private Thread? shortcut;
    private uint shortcutThread;
    private bool disposed;
    private readonly SemaphoreSlim mediaLock = new(1);
    public async Task InitializeMedia()
    {
        if (media != null) return;
        try {
            media = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
            media.CurrentSessionChanged += SessionChanged;
            SelectSession(); MediaStatus = "Windows media connected";
        } catch (Exception e) { MediaStatus = "Media unavailable: " + e.Message; }
    }
    private void SessionChanged(GlobalSystemMediaTransportControlsSessionManager sender, CurrentSessionChangedEventArgs args) => SelectSession();
    private void SelectSession()
    {
        if (session != null) { session.MediaPropertiesChanged -= PropertiesChanged; session.PlaybackInfoChanged -= PlaybackChanged; session.TimelinePropertiesChanged -= TimelineChanged; }
        session = media?.GetCurrentSession();
        if (session != null) { session.MediaPropertiesChanged += PropertiesChanged; session.PlaybackInfoChanged += PlaybackChanged; session.TimelinePropertiesChanged += TimelineChanged; }
        _ = RefreshMedia();
    }
    private void PropertiesChanged(GlobalSystemMediaTransportControlsSession sender, MediaPropertiesChangedEventArgs args) => _ = RefreshMedia();
    private void PlaybackChanged(GlobalSystemMediaTransportControlsSession sender, PlaybackInfoChangedEventArgs args) => _ = RefreshMedia();
    private void TimelineChanged(GlobalSystemMediaTransportControlsSession sender, TimelinePropertiesChangedEventArgs args) => _ = RefreshMedia();
    private async Task RefreshMedia()
    {
        await mediaLock.WaitAsync();
        try {
            var current = session;
            if (current == null) { MediaChanged?.Invoke(new()); return; }
            var properties = await current.TryGetMediaPropertiesAsync();
            if (current != session || disposed) return;
            var info = current.GetPlaybackInfo(); var timeline = current.GetTimelineProperties();
            byte[]? artwork = null;
            try { if (properties.Thumbnail != null) {
                using var stream = await properties.Thumbnail.OpenReadAsync();
                if (stream.Size is > 0 and < 4 * 1024 * 1024) {
                    using var reader = new DataReader(stream); await reader.LoadAsync((uint)stream.Size);
                    artwork = new byte[reader.UnconsumedBufferLength]; reader.ReadBytes(artwork);
                }
            } } catch (Exception) { /* Missing artwork must not prevent media controls or metadata. */ }
            if (current != session || disposed) return;
            MediaChanged?.Invoke(new Playback { Title = properties.Title, Artist = properties.Artist, Source = current.SourceAppUserModelId, ArtworkData = artwork,
                Playing = info.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing,
                Position = timeline.Position.TotalSeconds, Duration = timeline.EndTime.TotalSeconds, Rate = info.PlaybackRate ?? 1,
                Sampled = DateTimeOffset.UtcNow });
        } catch (Exception e) { MediaStatus = "Media unavailable: " + e.Message; }
        finally { mediaLock.Release(); }
    }
    public async Task MediaCommand(string action, double position = 0)
    {
        if (session == null) return;
        var accepted = action switch {
            "play" => await session.TryPlayAsync(), "pause" => await session.TryPauseAsync(),
            "next" => await session.TrySkipNextAsync(), "previous" => await session.TrySkipPreviousAsync(),
            "seek" => await session.TryChangePlaybackPositionAsync(TimeSpan.FromSeconds(position).Ticks), _ => false
        };
        if (!accepted) throw new InvalidOperationException("This player does not support that control.");
    }
    private MMDevice Output() {
        devices ??= new MMDeviceEnumerator();
        output ??= devices.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia); return output;
    }
    public void InitializeSystem() {
        if (audioNotifications != null) return;
        devices ??= new MMDeviceEnumerator();
        audioNotifications = new AudioNotifications(() => Dispatch(RebindAudio));
        devices.RegisterEndpointNotificationCallback(audioNotifications); RebindAudio();
    }
    private void RebindAudio() {
        if (disposed) return;
        if (output != null) { output.AudioEndpointVolume.OnVolumeNotification -= VolumeNotification; output.Dispose(); output = null; }
        try { Output().AudioEndpointVolume.OnVolumeNotification += VolumeNotification; }
        catch (COMException) { /* No output device; a future device event will retry. */ }
    }
    private void VolumeNotification(AudioVolumeNotificationData data) => VolumeChanged?.Invoke(data.MasterVolume, data.Muted);
    private sealed class AudioNotifications(Action changed) : IMMNotificationClient {
        public void OnDefaultDeviceChanged(DataFlow flow, Role role, string id) { if (flow == DataFlow.Render && role == Role.Multimedia) changed(); }
        public void OnDeviceAdded(string id) => changed();
        public void OnDeviceRemoved(string id) => changed();
        public void OnDeviceStateChanged(string id, DeviceState state) => changed();
        public void OnPropertyValueChanged(string id, PropertyKey key) { }
    }
    public float Volume { get => Output().AudioEndpointVolume.MasterVolumeLevelScalar; set => Output().AudioEndpointVolume.MasterVolumeLevelScalar = Math.Clamp(value, 0, 1); }
    public bool Muted { get => Output().AudioEndpointVolume.Mute; set => Output().AudioEndpointVolume.Mute = value; }
    public void StartAudio(bool enabled)
    {
        capture?.StopRecording(); capture?.Dispose(); capture = null;
        if (!enabled) return;
        capture = new WasapiLoopbackCapture();
        var last = Stopwatch.StartNew();
        var transform = new NAudio.Dsp.Complex[2048];
        var cursor = 0;
        capture.DataAvailable += (_, e) => {
            if (capture == null || capture.WaveFormat.BitsPerSample != 32) return;
            var channels = capture.WaveFormat.Channels;
            for (var offset = 0; offset + channels * 4 <= e.BytesRecorded; offset += channels * 4) {
                var sample = 0f;
                for (var channel = 0; channel < channels; channel++) sample += BitConverter.ToSingle(e.Buffer, offset + channel * 4) / channels;
                transform[cursor].X = sample * (float)NAudio.Dsp.FastFourierTransform.HammingWindow(cursor, transform.Length); transform[cursor].Y = 0;
                if (++cursor != transform.Length) continue; cursor = 0;
                if (last.ElapsedMilliseconds < 40) continue; last.Restart();
                NAudio.Dsp.FastFourierTransform.FFT(true, 11, transform);
                var levels = new float[20];
                for (var bar = 0; bar < levels.Length; bar++) {
                    var lower = Math.Clamp((int)(40 * Math.Pow(350, bar / 20d) * transform.Length / capture.WaveFormat.SampleRate), 1, 1023);
                    var upper = Math.Clamp((int)(40 * Math.Pow(350, (bar + 1) / 20d) * transform.Length / capture.WaveFormat.SampleRate), lower + 1, 1024);
                    var amplitude = 0d;
                    for (var bin = lower; bin < upper; bin++) amplitude = Math.Max(amplitude, Math.Sqrt(transform[bin].X * transform[bin].X + transform[bin].Y * transform[bin].Y));
                    levels[bar] = (float)Math.Clamp((20 * Math.Log10(Math.Max(amplitude, .000001)) + 72) / 72, 0, 1) / 3;
                }
                AudioLevels?.Invoke(levels);
            }
        };
        capture.StartRecording();
    }
    public static string Battery() {
        if (!GetSystemPowerStatus(out var power) || power.BatteryFlag == 128 || power.BatteryLifePercent == 255) return "Desktop power · plugged in";
        return $"{power.BatteryLifePercent}% battery · {(power.ACLineStatus == 1 ? "charging" : "on battery")}";
    }
    public static void KeepAwake(bool enabled) => SetThreadExecutionState(0x80000000u | (enabled ? 0x00000001u : 0u));
    public static void Login(bool enabled) {
        using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if (enabled) key.SetValue("BoringNotch", $"\"{Environment.ProcessPath}\" --background"); else key.DeleteValue("BoringNotch", false);
    }
    public void StartShortcut() {
        if (shortcut != null) return;
        shortcut = new Thread(() => {
            shortcutThread = GetCurrentThreadId();
            if (!RegisterHotKey(IntPtr.Zero, 1, 0x4000 | 0x0002 | 0x0008, 0x42)) return; // Ctrl+Win+B, no autorepeat
            try { while (GetMessage(out var message, IntPtr.Zero, 0, 0) > 0) if (message.Message == 0x0312) ToggleRequested?.Invoke(); }
            finally { UnregisterHotKey(IntPtr.Zero, 1); }
        }) { IsBackground = true, Name = "Boring shortcut" }; shortcut.Start();
    }
    public static bool Fullscreen(IntPtr own) {
        var window = GetForegroundWindow();
        if (window == IntPtr.Zero || window == own || !GetWindowRect(window, out var bounds)) return false;
        var monitor = MonitorFromWindow(window, 2); var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        if (!GetMonitorInfo(monitor, ref info)) return false;
        // Ignore the desktop shell, whose rectangle also fills the monitor.
        GetWindowThreadProcessId(window, out var pid);
        try { if (Process.GetProcessById((int)pid).ProcessName is "explorer" or "ShellExperienceHost") return false; } catch (ArgumentException) { return false; }
        return bounds.Left <= info.Monitor.Left && bounds.Top <= info.Monitor.Top && bounds.Right >= info.Monitor.Right && bounds.Bottom >= info.Monitor.Bottom;
    }
    public static async Task Brightness(int percent) {
        // CIM supports built-in laptop displays; unsupported monitors report an error.
        using var process = Process.Start(new ProcessStartInfo("powershell.exe") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true,
            ArgumentList = { "-NoProfile", "-NonInteractive", "-Command", $"$ErrorActionPreference='Stop'; $m=Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightnessMethods; if (!$m) {{ throw 'This display does not expose brightness controls' }}; $m | Invoke-CimMethod -MethodName WmiSetBrightness -Arguments @{{Timeout=0;Brightness=[byte]{Math.Clamp(percent,0,100)}}} | Out-Null" } })!;
        var error = await process.StandardError.ReadToEndAsync(); await process.WaitForExitAsync();
        if (process.ExitCode != 0) throw new InvalidOperationException(error.Trim());
    }
    public void Dispose() {
        disposed = true; StartAudio(false);
        if (media != null) media.CurrentSessionChanged -= SessionChanged;
        if (session != null) { session.MediaPropertiesChanged -= PropertiesChanged; session.PlaybackInfoChanged -= PlaybackChanged; session.TimelinePropertiesChanged -= TimelineChanged; }
        if (audioNotifications != null) devices?.UnregisterEndpointNotificationCallback(audioNotifications);
        if (output != null) output.AudioEndpointVolume.OnVolumeNotification -= VolumeNotification;
        output?.Dispose(); devices?.Dispose(); KeepAwake(false);
        if (shortcutThread != 0) PostThreadMessage(shortcutThread, 0x0012, IntPtr.Zero, IntPtr.Zero);
    }
    [StructLayout(LayoutKind.Sequential)] private struct PowerStatus { public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag; public uint BatteryLifeTime, BatteryFullLifeTime; }
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct MonitorInfo { public int Size; public Rect Monitor, Work; public uint Flags; }
    [StructLayout(LayoutKind.Sequential)] private struct NativeMessage { public IntPtr Window; public uint Message; public nuint WParam; public nint LParam; public uint Time; public int X, Y; public uint Private; }
    [DllImport("kernel32.dll")] private static extern bool GetSystemPowerStatus(out PowerStatus status);
    [DllImport("kernel32.dll")] private static extern uint SetThreadExecutionState(uint flags);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr window, int id);
    [DllImport("user32.dll")] private static extern int GetMessage(out NativeMessage message, IntPtr window, uint min, uint max);
    [DllImport("user32.dll")] private static extern bool PostThreadMessage(uint thread, uint message, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out Rect bounds);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
#else
    public Task InitializeMedia() { MediaChanged?.Invoke(new()); return Task.CompletedTask; }
    public Task MediaCommand(string action, double position = 0) => Task.FromException(new PlatformNotSupportedException("Windows playback requires Windows"));
    public float Volume { get => 0; set => throw new PlatformNotSupportedException("Volume requires Windows"); }
    public bool Muted { get => false; set => throw new PlatformNotSupportedException("Mute requires Windows"); }
    public void StartAudio(bool enabled) { if (enabled) throw new PlatformNotSupportedException("Audio capture requires Windows"); AudioLevels?.Invoke(new float[20]); }
    public static string Battery() => "Windows system tools are available on Windows";
    public static void KeepAwake(bool enabled) { }
    public static void Login(bool enabled) { if (enabled) throw new PlatformNotSupportedException("Login startup requires Windows"); }
    public void StartShortcut() { _ = ToggleRequested; }
    public void InitializeSystem() { _ = VolumeChanged; }
    public static bool Fullscreen(IntPtr own) => false;
    public static Task Brightness(int percent) => Task.FromException(new PlatformNotSupportedException("Brightness requires Windows"));
    public void Dispose() { }
#endif
}
