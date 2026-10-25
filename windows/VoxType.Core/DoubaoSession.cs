using System.Net.WebSockets;
using System.Threading.Channels;

namespace VoxType.Core;

public sealed class DoubaoSession
{
    private readonly Uri endpoint;
    public DoubaoSession() : this(new Uri(DoubaoProtocol.Endpoint)) { }
    internal DoubaoSession(Uri endpoint) { this.endpoint = endpoint; }
    public async Task<RecognitionSnapshot> RunAsync(string key, string uid,
        ChannelReader<byte[]> audio, Action<RecognitionSnapshot> onResult, CancellationToken cancellationToken)
    {
        using var socket = new ClientWebSocket();
        socket.Options.SetRequestHeader("X-Api-Key", key);
        socket.Options.SetRequestHeader("X-Api-Resource-Id", DoubaoProtocol.ResourceId);
        socket.Options.SetRequestHeader("X-Api-Request-Id", Guid.NewGuid().ToString());
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        using var connecting = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        connecting.CancelAfter(TimeSpan.FromSeconds(8));
        try { await socket.ConnectAsync(endpoint, connecting.Token); }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        { throw new TimeoutException("识别连接超时，请重试。"); }
        catch (WebSocketException) { throw new IOException("识别连接失败，请检查网络、API Key 和服务额度。"); }
        connecting.CancelAfter(Timeout.InfiniteTimeSpan);
        await socket.SendAsync(DoubaoProtocol.FullRequest(1, uid), WebSocketMessageType.Binary, true, lifetime.Token);
        var reducer = new RecognitionReducer(uid);
        bool finalReceived = false;

        async Task Send()
        {
            try
            {
                int sequence = 2;
                await foreach (byte[] chunk in audio.ReadAllAsync(lifetime.Token))
                    await socket.SendAsync(DoubaoProtocol.Audio(sequence++, chunk, false),
                        WebSocketMessageType.Binary, true, lifetime.Token);
                await socket.SendAsync(DoubaoProtocol.Audio(sequence, [], true),
                    WebSocketMessageType.Binary, true, lifetime.Token);
                lifetime.CancelAfter(TimeSpan.FromSeconds(3));
            }
            catch (OperationCanceledException) when (Volatile.Read(ref finalReceived) && !cancellationToken.IsCancellationRequested) { }
            catch { lifetime.Cancel(); throw; }
        }

        async Task Receive()
        {
            try
            {
                byte[] buffer = new byte[8192];
                while (true)
                {
                    using var frame = new MemoryStream();
                    WebSocketReceiveResult read;
                    do
                    {
                        read = await socket.ReceiveAsync(new ArraySegment<byte>(buffer), lifetime.Token);
                        if (read.MessageType == WebSocketMessageType.Close)
                            throw new IOException("识别连接提前关闭，尚未收到最终结果。");
                        if (read.MessageType != WebSocketMessageType.Binary)
                            throw new InvalidDataException("识别服务返回了非二进制消息。");
                        if (frame.Length + read.Count > DoubaoProtocol.MaxFrameBytes)
                            throw new InvalidDataException("识别消息过大。");
                        frame.Write(buffer, 0, read.Count);
                    } while (!read.EndOfMessage);
                    var message = DoubaoProtocol.Decode(frame.ToArray());
                    if (message is null) continue;
                    if (message.Failed) throw new IOException($"识别失败（{message.Code}），请检查 API Key、额度和音频设置。");
                    if (reducer.Apply(uid, message) is { } snapshot) onResult(snapshot);
                    if (message.Final)
                    {
                        Volatile.Write(ref finalReceived, true);
                        lifetime.Cancel();
                        return;
                    }
                }
            }
            catch { lifetime.Cancel(); throw; }
        }

        try { await Task.WhenAll(Send(), Receive()); }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        { throw new TimeoutException("等待句末纠正超时，本次未自动输入。"); }
        catch (WebSocketException) { throw new IOException("语音识别连接中断，请重试。"); }
        finally { lifetime.Cancel(); socket.Abort(); }
        if (!finalReceived) throw new IOException("识别未正常完成。");
        return reducer.Snapshot;
    }
}
