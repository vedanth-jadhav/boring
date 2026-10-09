using System.Runtime.InteropServices;
#if WINDOWS
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
#endif

namespace Boring.Native;
public static class WindowsSharing
{
#if WINDOWS
    [ComImport, Guid("3A3DCD6C-3EAB-43DC-BCDE-45671CE800C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShareInterop {
        void GetForWindow(IntPtr window, ref Guid iid, out IntPtr manager);
        void ShowShareUIForWindow(IntPtr window);
    }
    public static async Task Share(IntPtr window, string[] paths) {
        var files = new List<IStorageItem>();
        foreach (var path in paths) files.Add(await StorageFile.GetFileFromPathAsync(path));
        if (files.Count == 0) throw new InvalidOperationException("Select files to share.");
        const string className = "Windows.ApplicationModel.DataTransfer.DataTransferManager";
        Marshal.ThrowExceptionForHR(WindowsCreateString(className, className.Length, out var name));
        IntPtr factory = IntPtr.Zero, pointer = IntPtr.Zero;
        try {
            var iid = typeof(IShareInterop).GUID; Marshal.ThrowExceptionForHR(RoGetActivationFactory(name, ref iid, out factory));
            var interop = (IShareInterop)Marshal.GetObjectForIUnknown(factory);
            var managerId = new Guid("A5CAEE9B-8708-49D1-8D36-67D25A8DA00C");
            interop.GetForWindow(window, ref managerId, out pointer);
            var manager = WinRT.MarshalInspectable<DataTransferManager>.FromAbi(pointer);
            void Requested(DataTransferManager sender, DataRequestedEventArgs args) {
                args.Request.Data.Properties.Title = "Share from Boring Notch";
                args.Request.Data.SetStorageItems(files); manager.DataRequested -= Requested;
            }
            manager.DataRequested += Requested; interop.ShowShareUIForWindow(window);
        } finally { if (pointer != IntPtr.Zero) Marshal.Release(pointer); if (factory != IntPtr.Zero) Marshal.Release(factory); WindowsDeleteString(name); }
    }
    [DllImport("combase.dll", CharSet = CharSet.Unicode)] private static extern int WindowsCreateString(string source, int length, out IntPtr value);
    [DllImport("combase.dll")] private static extern int WindowsDeleteString(IntPtr value);
    [DllImport("combase.dll")] private static extern int RoGetActivationFactory(IntPtr name, ref Guid iid, out IntPtr factory);
#else
    public static Task Share(IntPtr window, string[] paths) => Task.FromException(new PlatformNotSupportedException("Sharing requires Windows."));
#endif
}
