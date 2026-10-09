using System.Diagnostics;

#if WINDOWS
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;
using Windows.Graphics.Imaging;
using Windows.Media.MediaProperties;
using Windows.Storage.Streams;
#endif

namespace Boring.Native;
/// <summary>Preview-only Windows camera frames. No microphone, recording, or external codec runtime.</summary>
public sealed class CameraMirror : IAsyncDisposable
{
    public event Action<byte[], int, int>? Frame;
    public event Action<string>? Error;
    private readonly SynchronizationContext? context = SynchronizationContext.Current;
    private void Dispatch(Action action) { if (context != null) context.Post(_ => action(), null); else action(); }
#if WINDOWS
    private MediaCapture? capture;
    private MediaFrameReader? reader;
    private Task? initialize;
    private volatile bool stopped;
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private long lastFrame;
    public void Start() => initialize ??= Initialize();
    private async Task Initialize() {
        try {
            var groups = await MediaFrameSourceGroup.FindAllAsync();
            var group = groups.FirstOrDefault(g => g.SourceInfos.Any(s => s.SourceKind == MediaFrameSourceKind.Color));
            if (group == null) throw new InvalidOperationException("No camera available. Check Windows camera privacy settings.");
            capture = new MediaCapture();
            await capture.InitializeAsync(new MediaCaptureInitializationSettings { SourceGroup = group, StreamingCaptureMode = StreamingCaptureMode.Video,
                MemoryPreference = MediaCaptureMemoryPreference.Cpu, SharingMode = MediaCaptureSharingMode.SharedReadOnly });
            if (stopped) return;
            var source = capture.FrameSources.Values.First(s => s.Info.SourceKind == MediaFrameSourceKind.Color);
            reader = await capture.CreateFrameReaderAsync(source, MediaEncodingSubtypes.Bgra8, new BitmapSize { Width = 640, Height = 360 });
            reader.AcquisitionMode = MediaFrameReaderAcquisitionMode.Realtime;
            reader.FrameArrived += Arrived;
            var status = await reader.StartAsync();
            if (status != MediaFrameReaderStartStatus.Success) throw new InvalidOperationException("Camera could not start: " + status);
        } catch (Exception e) { if (!stopped) Dispatch(() => Error?.Invoke(e.Message)); }
    }
    private void Arrived(MediaFrameReader sender, MediaFrameArrivedEventArgs args) {
        if (stopped || clock.ElapsedMilliseconds - Interlocked.Read(ref lastFrame) < 66) return;
        Interlocked.Exchange(ref lastFrame, clock.ElapsedMilliseconds);
        try {
            using var frame = sender.TryAcquireLatestFrame();
            if (frame?.VideoMediaFrame?.SoftwareBitmap is not { } bitmap) return;
            using var converted = SoftwareBitmap.Convert(bitmap, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
            var buffer = new Windows.Storage.Streams.Buffer((uint)(converted.PixelWidth * converted.PixelHeight * 4)); converted.CopyToBuffer(buffer);
            var pixels = new byte[buffer.Length]; using var data = DataReader.FromBuffer(buffer); data.ReadBytes(pixels);
            var width = converted.PixelWidth; var height = converted.PixelHeight;
            Dispatch(() => { if (!stopped) Frame?.Invoke(pixels, width, height); });
        } catch (Exception e) { if (!stopped) Dispatch(() => Error?.Invoke(e.Message)); }
    }
    public async ValueTask DisposeAsync() {
        stopped = true; if (initialize != null) await initialize;
        if (reader != null) { reader.FrameArrived -= Arrived; await reader.StopAsync(); reader.Dispose(); }
        capture?.Dispose();
    }
#else
    public void Start() { _ = Frame; Error?.Invoke("Camera preview requires Windows."); }
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
#endif
}
