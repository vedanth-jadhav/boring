using System.Runtime.InteropServices;

namespace Boring.Native;
/// <summary>Real X11 pointer coordinates for Linux development/recording only.
/// Chromium's cached cursor stops updating while a click-through X11 window is ignored.
/// The distributed Windows app uses Electron's native Windows cursor API.</summary>
internal static class DevelopmentCursor
{
    private static readonly object gate = new();
    private static IntPtr display;
    public static object? Read() {
        if (!OperatingSystem.IsLinux()) return null;
        lock (gate) {
            try {
                if (display == IntPtr.Zero) display = XOpenDisplay(IntPtr.Zero);
                if (display == IntPtr.Zero) return null;
                return XQueryPointer(display, XDefaultRootWindow(display), out _, out _, out var x, out var y, out _, out _, out _) != 0 ? new { x, y } : null;
            } catch (DllNotFoundException) { return null; } catch (EntryPointNotFoundException) { return null; }
        }
    }
    public static void Close() { lock (gate) { if (display != IntPtr.Zero) { XCloseDisplay(display); display = IntPtr.Zero; } } }
    [DllImport("libX11.so.6")] private static extern IntPtr XOpenDisplay(IntPtr name);
    [DllImport("libX11.so.6")] private static extern nuint XDefaultRootWindow(IntPtr display);
    [DllImport("libX11.so.6")] private static extern int XQueryPointer(IntPtr display, nuint window, out nuint root, out nuint child, out int x, out int y, out int localX, out int localY, out uint mask);
    [DllImport("libX11.so.6")] private static extern int XCloseDisplay(IntPtr display);
}
