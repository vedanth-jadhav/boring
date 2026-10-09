using System.Collections.Concurrent;
using System.Runtime.InteropServices;

namespace Boring.Native;
/// <summary>A real STA message pump for WinRT camera and the Windows sharing UI.</summary>
public sealed class NativeUi
{
    private readonly ConcurrentQueue<Action> queue = new();
    private uint thread;
    public IntPtr Window { get; private set; }
    private const uint Wake = 0x8001;
    private sealed class Context(NativeUi ui) : SynchronizationContext {
        public override void Post(SendOrPostCallback callback, object? state) => ui.Post(() => callback(state));
        public override SynchronizationContext CreateCopy() => this;
    }
    public void Post(Action action) {
        if (!OperatingSystem.IsWindows()) { action(); return; }
        queue.Enqueue(action); PostThreadMessage(thread, Wake, 0, 0);
    }
    public static int Run(Func<NativeUi, Task<int>> action) {
        var ui = new NativeUi();
        if (!OperatingSystem.IsWindows()) return action(ui).GetAwaiter().GetResult();
        ui.thread = GetCurrentThreadId();
        ui.Window = CreateWindowEx(0x08000080, "STATIC", "Boring Notch Windows sharing", 0x80000000, 0, 0, 1, 1, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (ui.Window == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        SynchronizationContext.SetSynchronizationContext(new Context(ui));
        var task = action(ui);
        _ = task.ContinueWith(_ => PostThreadMessage(ui.thread, 0x0012, 0, 0), TaskScheduler.Default);
        while (GetMessage(out var message, IntPtr.Zero, 0, 0) > 0) {
            if (message.Message == Wake) { while (ui.queue.TryDequeue(out var callback)) callback(); }
            else { TranslateMessage(ref message); DispatchMessage(ref message); }
        }
        DestroyWindow(ui.Window); return task.GetAwaiter().GetResult();
    }
    [StructLayout(LayoutKind.Sequential)] private struct MessageData { public IntPtr Window; public uint Message; public nuint WParam; public nint LParam; public uint Time; public int X, Y; public uint Private; }
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern bool PostThreadMessage(uint id, uint message, nuint w, nint l);
    [DllImport("user32.dll")] private static extern int GetMessage(out MessageData message, IntPtr window, uint min, uint max);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref MessageData message);
    [DllImport("user32.dll")] private static extern nint DispatchMessage(ref MessageData message);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateWindowEx(uint extendedStyle, string className, string title, uint style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr window);
}
