using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Channels;
using VoxType.Core;

internal static class TransportChecks
{
    internal static async Task Run(Action<bool, string> check)
    {
        await Exchange(async (socket, token) =>
        {
            var request = await Receive(socket, token);
            check(request[1] == 0x11, "websocket sends full request first");
            await socket.SendAsync(Server("开回忆", false), WebSocketMessageType.Binary, true, token);
            var first = await Receive(socket, token);
            var second = await Receive(socket, token);
            var final = await Receive(socket, token);
            check(first[1] == 0x21 && second[1] == 0x21 && final[1] == 0x23, "audio packets stay ordered and terminate once");
            await socket.SendAsync(Server("开会议。", true, true), WebSocketMessageType.Binary, true, token);
            await WaitForDisconnect(socket, token);
        }, async (uri, token) =>
        {
            var audio = Channel.CreateBounded<byte[]>(15);
            audio.Writer.TryWrite(new byte[6400]); audio.Writer.TryWrite(new byte[6400]); audio.Writer.TryComplete();
            var seen = new List<string>();
            var result = await new DoubaoSession(uri).RunAsync("local-test", "test-session", audio.Reader, s => seen.Add(s.Text), token);
            check(result.Text == "开会议。" && seen.SequenceEqual(new[] { "开回忆", "开会议。" }), "real websocket transport delivers partial and corrected final results");
        });

        await Exchange(async (socket, token) =>
        {
            _ = await Receive(socket, token);
            await socket.SendAsync(Server("Hello", true, true), WebSocketMessageType.Binary, true, token);
            await WaitForDisconnect(socket, token);
        }, async (uri, token) =>
        {
            var audio = Channel.CreateBounded<byte[]>(15);
            var result = await new DoubaoSession(uri).RunAsync("local-test", "early-final", audio.Reader, _ => { }, token)
                .WaitAsync(TimeSpan.FromSeconds(2), token);
            check(result.Text == "Hello", "early server final cancels a sender waiting for audio");
        });

        await Exchange(async (socket, token) =>
        {
            _ = await Receive(socket, token);
            byte[] frame = JsonFrame("{\"code\":45000001,\"message\":\"local-test\"}");
            await socket.SendAsync(frame, WebSocketMessageType.Binary, true, token);
            await WaitForDisconnect(socket, token);
        }, async (uri, token) =>
        {
            var audio = Channel.CreateBounded<byte[]>(15);
            try
            {
                await new DoubaoSession(uri).RunAsync("local-test", "server-error", audio.Reader, _ => { }, token)
                    .WaitAsync(TimeSpan.FromSeconds(2), token);
                throw new Exception("Server error was accepted");
            }
            catch (IOException ex) { check(!ex.Message.Contains("local-test"), "server error cancels blocked sender and does not echo secrets"); }
        });
    }

    private static byte[] Server(string text, bool definite, bool final = false) =>
        JsonFrame(System.Text.Json.JsonSerializer.Serialize(new
        { result = new { text, utterances = new[] { new { text, start_time = 0, definite } } } }), final);

    private static byte[] JsonFrame(string json, bool final = false)
    {
        byte[] data = Encoding.UTF8.GetBytes(json);
        byte[] frame = new byte[8 + data.Length];
        frame[0] = 0x11; frame[1] = final ? (byte)0x92 : (byte)0x90; frame[2] = 0x10;
        System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(frame.AsSpan(4), data.Length);
        data.CopyTo(frame, 8); return frame;
    }

    private static async Task<byte[]> Receive(WebSocket socket, CancellationToken token)
    {
        using var data = new MemoryStream();
        byte[] buffer = new byte[8192];
        WebSocketReceiveResult part;
        do
        {
            part = await socket.ReceiveAsync(new ArraySegment<byte>(buffer), token);
            if (part.MessageType != WebSocketMessageType.Binary) throw new IOException("Expected binary message");
            data.Write(buffer, 0, part.Count);
        } while (!part.EndOfMessage);
        return data.ToArray();
    }

    private static async Task WaitForDisconnect(WebSocket socket, CancellationToken token)
    {
        // Keep the server alive until the client consumes the final frame and closes its socket.
        try { _ = await socket.ReceiveAsync(new ArraySegment<byte>(new byte[8]), token); }
        catch (WebSocketException) { }
        catch (IOException) { }
    }

    private static async Task Exchange(Func<WebSocket, CancellationToken, Task> server,
        Func<Uri, CancellationToken, Task> client)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        var serving = Task.Run(async () =>
        {
            try
            {
                using var tcp = await listener.AcceptTcpClientAsync(timeout.Token);
                using var stream = tcp.GetStream();
                var header = new List<byte>();
                byte[] one = new byte[1];
                while (true)
                {
                    if (await stream.ReadAsync(one, timeout.Token) != 1) throw new IOException("Incomplete handshake");
                    header.Add(one[0]);
                    if (header.Count > 16384) throw new IOException("Handshake too large");
                    if (header.Count >= 4 && header.TakeLast(4).SequenceEqual(new byte[] { 13, 10, 13, 10 })) break;
                }
                string request = Encoding.ASCII.GetString(header.ToArray());
                if (!request.Contains("X-Api-Key: local-test\r\n", StringComparison.OrdinalIgnoreCase)
                    || !request.Contains("X-Api-Resource-Id: " + DoubaoProtocol.ResourceId + "\r\n", StringComparison.OrdinalIgnoreCase))
                    throw new IOException("Unexpected local test authentication headers");
                string key = request.Split("\r\n").Single(line => line.StartsWith("Sec-WebSocket-Key:", StringComparison.OrdinalIgnoreCase)).Split(':', 2)[1].Trim();
                string accept = Convert.ToBase64String(SHA1.HashData(Encoding.ASCII.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
                await stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"), timeout.Token);
                using var socket = WebSocket.CreateFromStream(stream, true, null, Timeout.InfiniteTimeSpan);
                await server(socket, timeout.Token);
            }
            catch { await timeout.CancelAsync(); throw; }
        });
        try { await client(new Uri($"ws://127.0.0.1:{port}/"), timeout.Token); await serving; }
        finally { await timeout.CancelAsync(); listener.Stop(); try { await serving; } catch when (timeout.IsCancellationRequested) { } }
    }
}
