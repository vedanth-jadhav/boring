using System.Runtime.InteropServices;

namespace Boring.Native;
public static class WindowsComposition
{
    // Electron clips the native window to the animated island region. Composition
    // therefore applies only behind that surface, never behind its transparent canvas.
    public static bool Apply(IntPtr window, bool glass) {
        if (!OperatingSystem.IsWindows() || window == IntPtr.Zero) return false;
        using var personalization = Microsoft.Win32.Registry.CurrentUser.OpenSubKey("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
        glass &= personalization?.GetValue("EnableTransparency") is not int value || value != 0;
        var policy = new AccentPolicy { State = glass ? 4 : 0, Flags = 2, Color = 0x90101010 };
        var pointer = Marshal.AllocHGlobal(Marshal.SizeOf<AccentPolicy>());
        try {
            Marshal.StructureToPtr(policy, pointer, false);
            var data = new CompositionData { Attribute = 19, Data = pointer, Size = (nuint)Marshal.SizeOf<AccentPolicy>() };
            return SetWindowCompositionAttribute(window, ref data) != 0 && glass;
        } catch (EntryPointNotFoundException) { return false; }
        finally { Marshal.FreeHGlobal(pointer); }
    }
    [StructLayout(LayoutKind.Sequential)] private struct AccentPolicy { public int State, Flags; public uint Color; public int Animation; }
    [StructLayout(LayoutKind.Sequential)] private struct CompositionData { public int Attribute; public IntPtr Data; public nuint Size; }
    [DllImport("user32.dll")] private static extern int SetWindowCompositionAttribute(IntPtr window, ref CompositionData data);
}
