using System;
using System.IO;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;
using VoxType.Core;

namespace VoxType.Windows;

internal sealed class DictationController
{
    private sealed class Session
    {
        internal readonly CancellationTokenSource Cancel = new();
        internal readonly Channel<byte[]> Audio = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(15)
        { SingleReader = true, SingleWriter = true, FullMode = BoundedChannelFullMode.Wait });
        internal WaveCapture? Capture;
        internal volatile bool Released;
        internal string? Reason;
        internal Task? StopTask;
    }
    // shortcut: a permanently hung UIA provider needs an app restart; isolate it in a helper if Windows testing encounters this.
    private static readonly SemaphoreSlim FocusReader = new(1);
    private readonly SynchronizationContext ui;
    private readonly Shortcuts shortcuts;
    private Session? current;
    private Task? work;
    private bool closing;
    private WaveCapture? failedCapture;
    internal Action<string, string, bool> Status = (_, _, _) => { };
    internal string LastResult { get; private set; } = "";
    internal bool Busy => current != null;

    internal DictationController(Shortcuts shortcuts, SynchronizationContext ui)
    { this.shortcuts = shortcuts; this.ui = ui; }

    internal void Start(Settings settings)
    {
        if (Busy || closing) return;
        if (failedCapture != null) { Status("请重启 VoxType", "上次麦克风资源未正确释放，已禁止再次打开录音。", false); return; }
        var session = new Session();
        current = session;
        work = Run(session, settings);
    }

    private async Task Run(Session session, Settings settings)
    {
        var token = session.Cancel.Token;
        try
        {
            string key = Credentials.Read() ?? throw new InvalidOperationException("请先在设置中保存豆包 API Key。");
            var captureFocus = Task.Run(() =>
            {
                if (!FocusReader.Wait(0)) throw new InvalidOperationException("目标应用的焦点查询仍未返回，请稍后再试。");
                try { return InputTarget.Capture(); }
                finally { FocusReader.Release(); }
            }, token);
            var target = await captureFocus.WaitAsync(TimeSpan.FromSeconds(1), token);
            if (session.Released || !shortcuts.IsHeld) return;
            LastResult = "";
            shortcuts.WatchManualInput(() =>
            {
                session.Reason = "检测到手动输入，本次听写已取消，未自动插入文字。";
                _ = session.Cancel.CancelAsync();
            });
            session.Capture = new WaveCapture(data =>
            {
                if (!session.Audio.Writer.TryWrite(data))
                {
                    session.Reason = "识别连接或发送过慢，音频缓冲已满，本次已取消。";
                    _ = session.Cancel.CancelAsync();
                }
            }, () =>
            {
                session.Reason = "麦克风录音中断，本次已取消。";
                _ = session.Cancel.CancelAsync();
            });
            session.Capture.Start();
            Status("正在听", "说话时实时识别，松开快捷键后输入定稿。", true);
            var result = await new DoubaoSession().RunAsync(key, settings.Uid, session.Audio.Reader, snapshot =>
            {
                ui.Post(_ =>
                {
                    if (current != session || token.IsCancellationRequested || closing) return;
                    LastResult = snapshot.Text;
                    Status(session.Released ? "识别中" : "正在听", snapshot.Text, true);
                }, null);
            }, token);
            await StopAudio(session);
            token.ThrowIfCancellationRequested();
            if (current != session || closing) return;
            LastResult = RecognitionReducer.Sanitize(result.Text);
            if (result.Desynced) throw new InvalidOperationException("识别结果无法安全对齐，已停止自动输入。");
            if (LastResult.Length == 0) { Status("未识别到文字", "请检查麦克风后重试。", false); return; }
            for (int i = 0; Native.ModifiersDown() && i < 100; i++)
            {
                Status("等待松开", "松开 Ctrl、Alt、Shift 等修饰键后自动输入。", true);
                await Task.Delay(20, token);
            }
            string finalText = LastResult;
            await Task.Run(() =>
            {
                if (!FocusReader.Wait(0)) throw new InvalidOperationException("目标应用的辅助功能查询仍未返回，请稍后再试。");
                try { target.Insert(finalText, token); }
                finally { FocusReader.Release(); }
            }, token).WaitAsync(TimeSpan.FromSeconds(2), token);
            Status(result.CorrectionIncomplete ? "已投递（定稿不完整）" : "已投递", finalText, false);
        }
        catch (OperationCanceledException)
        { if (!closing) Status("已取消", session.Reason ?? "本次听写已取消。", false); }
        catch (Exception ex)
        {
            if (!closing)
            {
                string message = ex is InvalidOperationException or IOException or TimeoutException
                    ? ex.Message : "无法完成听写，请检查网络、设备和目标输入框后重试。";
                Status("无法输入", message, false);
            }
        }
        finally
        {
            // A timed-out native UI query may return later; it must never inject stale text.
            await session.Cancel.CancelAsync();
            try { await StopAudio(session); }
            catch
            {
                failedCapture = session.Capture;
                if (!closing) Status("录音停止失败", "请退出并重新打开 VoxType。", false);
            }
            shortcuts.EndWatch();
            if (current == session) current = null;
            session.Cancel.Dispose();
        }
    }

    internal void Release()
    {
        if (current is not { } session) return;
        session.Released = true;
        _ = StopAudio(session);
        if (session.Capture != null) Status("识别中", LastResult.Length == 0 ? "等待句末纠正结果。" : LastResult, true);
    }

    private static Task StopAudio(Session session)
    {
        if (session.Capture == null) return Task.CompletedTask;
        return session.StopTask ??= Stop();
        async Task Stop()
        {
            try { await session.Capture.StopAsync(); }
            finally { session.Audio.Writer.TryComplete(); }
        }
    }

    internal async Task CloseAsync()
    {
        closing = true;
        if (current is { } session) await session.Cancel.CancelAsync();
        if (work != null) await work;
    }
}
