using System.Buffers.Binary;
using System.IO.Pipes;
using System.Text.Json;

namespace Boring.Core;
public sealed class OctavePipe : IAsyncDisposable
{
    public const string Name = "BoringNotch.Octave.v1";
    private readonly CancellationTokenSource stop = new();
    private readonly SemaphoreSlim writeLock = new(1);
    private NamedPipeServerStream? connection;
    private Task? loop;
    public event Action<JsonElement>? Message;
    public event Action<bool>? ConnectionChanged;
    public void Start() => loop ??= Serve();
    private async Task Serve()
    {
        while (!stop.IsCancellationRequested) {
            try {
                using var pipe = new NamedPipeServerStream(Name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(stop.Token); connection = pipe; ConnectionChanged?.Invoke(true);
                while (pipe.IsConnected && !stop.IsCancellationRequested) {
                    var data = await ReadFrame(pipe, stop.Token);
                    using var json = JsonDocument.Parse(data); Message?.Invoke(json.RootElement.Clone());
                }
            } catch (OperationCanceledException) { break; }
            catch (IOException) { }
            catch (JsonException) { }
            finally { connection = null; ConnectionChanged?.Invoke(false); }
        }
    }
    public async Task Send(string action, double? position = null, double? volume = null)
    {
        var data = JsonSerializer.SerializeToUtf8Bytes(new { type = "command", action, position, volume, sequence = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() });
        await writeLock.WaitAsync(stop.Token);
        try { if (connection is { IsConnected: true } pipe) await WriteFrame(pipe, data, stop.Token); }
        finally { writeLock.Release(); }
    }
    public static async Task<byte[]> ReadFrame(Stream stream, CancellationToken token = default)
    {
        var header = new byte[4]; await stream.ReadExactlyAsync(header, token);
        var length = BinaryPrimitives.ReadInt32LittleEndian(header);
        if (length <= 0 || length > 1024 * 1024) throw new IOException("Invalid native message size");
        var body = new byte[length]; await stream.ReadExactlyAsync(body, token); return body;
    }
    public static async Task WriteFrame(Stream stream, byte[] body, CancellationToken token = default)
    {
        if (body.Length is <= 0 or > 1024 * 1024) throw new IOException("Invalid native message size");
        var header = new byte[4]; BinaryPrimitives.WriteInt32LittleEndian(header, body.Length);
        await stream.WriteAsync(header, token); await stream.WriteAsync(body, token); await stream.FlushAsync(token);
    }
    public async ValueTask DisposeAsync() {
        stop.Cancel(); connection?.Dispose(); if (loop != null) await loop;
        stop.Dispose(); writeLock.Dispose();
    }
}
