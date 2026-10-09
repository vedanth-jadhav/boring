using Boring.Core;
using System.IO.Pipes;

namespace Boring.Native;
internal static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Contains("--native-host") || args.Any(a => a.StartsWith("chrome-extension://", StringComparison.Ordinal))) return NativeHost().GetAwaiter().GetResult();
        return NativeUi.Run(async ui => { await using var service = new NativeService(ui); return await service.Run(); });
    }
    private static async Task<int> NativeHost()
    {
        try {
            using var pipe = new NamedPipeClientStream(".", OctavePipe.Name, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            await pipe.ConnectAsync(3000);
            using var stop = new CancellationTokenSource();
            async Task Forward(Stream input, Stream output) {
                while (!stop.IsCancellationRequested) await OctavePipe.WriteFrame(output, await OctavePipe.ReadFrame(input, stop.Token), stop.Token);
            }
            var incoming = Forward(Console.OpenStandardInput(), pipe); var outgoing = Forward(pipe, Console.OpenStandardOutput());
            await Task.WhenAny(incoming, outgoing); stop.Cancel(); pipe.Dispose();
            try { await Task.WhenAll(incoming, outgoing); } catch (OperationCanceledException) { } catch (IOException) { }
            return 0;
        } catch (IOException) { return 1; } catch (TimeoutException) { return 1; }
    }
}
