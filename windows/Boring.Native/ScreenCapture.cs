using System.Runtime.InteropServices;
using SkiaSharp;

namespace Boring.Native;
public static class ScreenCapture
{
    public static Task<string> Capture() => Task.Run(() => {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Screen capture requires Windows.");
        var x = GetSystemMetrics(76); var y = GetSystemMetrics(77); var width = GetSystemMetrics(78); var height = GetSystemMetrics(79);
        if (width <= 0 || height <= 0) throw new InvalidOperationException("No display available.");
        var screen = GetDC(IntPtr.Zero); var memory = CreateCompatibleDC(screen); var bitmap = CreateCompatibleBitmap(screen, width, height);
        var previous = SelectObject(memory, bitmap);
        try {
            if (!BitBlt(memory, 0, 0, width, height, screen, x, y, 0x00CC0020 | 0x40000000)) throw new InvalidOperationException("Windows could not capture this screen.");
            SelectObject(memory, previous); previous = IntPtr.Zero;
            var header = new BitmapInfo { Size = 40, Width = width, Height = -height, Planes = 1, BitCount = 32 };
            using var pixels = new SKBitmap(width, height, SKColorType.Bgra8888, SKAlphaType.Opaque);
            if (GetDIBits(memory, bitmap, 0, (uint)height, pixels.GetPixels(), ref header, 0) == 0) throw new InvalidOperationException("Screen pixels unavailable.");
            using var image = SKImage.FromBitmap(pixels); using var data = image.Encode(SKEncodedImageFormat.Png, 100);
            var path = Path.Combine(Path.GetTempPath(), $"Screenshot-{DateTime.Now:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}.png");
            using var file = File.Create(path); data.SaveTo(file); return path;
        } finally { if (previous != IntPtr.Zero) SelectObject(memory, previous); DeleteObject(bitmap); DeleteDC(memory); ReleaseDC(IntPtr.Zero, screen); }
    });
    [StructLayout(LayoutKind.Sequential)] private struct BitmapInfo { public uint Size; public int Width, Height; public ushort Planes, BitCount; public uint Compression, SizeImage; public int XPelsPerMeter, YPelsPerMeter; public uint ColorsUsed, ColorsImportant; public uint Color; }
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr window);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr window, IntPtr dc);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int width, int height);
    [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] private static extern bool BitBlt(IntPtr target, int x, int y, int width, int height, IntPtr source, int sx, int sy, uint operation);
    [DllImport("gdi32.dll")] private static extern int GetDIBits(IntPtr dc, IntPtr bitmap, uint start, uint lines, IntPtr bits, ref BitmapInfo info, uint usage);
}
