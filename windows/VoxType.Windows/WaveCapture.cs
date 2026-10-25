using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using VoxType.Core;

namespace VoxType.Windows;

internal sealed class WaveCapture
{
    [StructLayout(LayoutKind.Sequential, Pack = 2)] private struct Format
    {
        public ushort Tag, Channels;
        public uint Rate, BytesPerSecond;
        public ushort BlockAlign, Bits, Extra;
    }
    [StructLayout(LayoutKind.Sequential)] private struct Header
    {
        public nint Data;
        public uint Length, Recorded;
        public nuint User;
        public uint Flags, Loops;
        public nint Next;
        public nuint Reserved;
    }
    [DllImport("winmm.dll")] private static extern uint waveInOpen(out nint handle, uint device, ref Format format, nint callback, nint instance, uint flags);
    [DllImport("winmm.dll")] private static extern uint waveInPrepareHeader(nint handle, nint header, uint size);
    [DllImport("winmm.dll")] private static extern uint waveInUnprepareHeader(nint handle, nint header, uint size);
    [DllImport("winmm.dll")] private static extern uint waveInAddBuffer(nint handle, nint header, uint size);
    [DllImport("winmm.dll")] private static extern uint waveInStart(nint handle);
    [DllImport("winmm.dll")] private static extern uint waveInReset(nint handle);
    [DllImport("winmm.dll")] private static extern uint waveInClose(nint handle);
    private readonly AutoResetEvent ready = new(false);
    private readonly List<(nint Header, nint Data)> buffers = new();
    private readonly object ioLock = new();
    private readonly AudioRingCursor cursor = new(4);
    private readonly Action<byte[]> onAudio;
    private readonly Action onFailure;
    private nint handle;
    private volatile bool running;
    private Task? worker, stopping;
    private static readonly uint HeaderSize = (uint)Marshal.SizeOf<Header>();

    internal WaveCapture(Action<byte[]> onAudio, Action onFailure)
    { this.onAudio = onAudio; this.onFailure = onFailure; }

    internal void Start()
    {
        var format = new Format { Tag = 1, Channels = 1, Rate = 16000, Bits = 16, BlockAlign = 2, BytesPerSecond = 32000 };
        if (waveInOpen(out handle, uint.MaxValue, ref format, ready.SafeWaitHandle.DangerousGetHandle(), 0, 0x50000) != 0)
            throw new InvalidOperationException("无法打开默认麦克风，请检查麦克风隐私权限和设备。需要 16kHz 单声道 PCM 支持。");
        try
        {
            for (int i = 0; i < 4; i++)
            {
                nint data = Marshal.AllocHGlobal(DoubaoProtocol.PacketBytes);
                nint header = Marshal.AllocHGlobal((int)HeaderSize);
                Marshal.StructureToPtr(new Header { Data = data, Length = DoubaoProtocol.PacketBytes }, header, false);
                buffers.Add((header, data));
                if (waveInPrepareHeader(handle, header, HeaderSize) != 0 || waveInAddBuffer(handle, header, HeaderSize) != 0)
                    throw new InvalidOperationException("无法建立麦克风录音缓冲区。");
            }
            running = true;
            worker = Task.Factory.StartNew(ReadLoop, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
            if (waveInStart(handle) != 0) throw new InvalidOperationException("无法开始麦克风录音。");
        }
        catch { lock (ioLock) { running = false; waveInReset(handle); } ready.Set(); throw; }
    }

    private void ReadLoop()
    {
        while (true)
        {
            ready.WaitOne(250);
            lock (ioLock)
            {
                for (int i = 0; i < buffers.Count; i++)
                {
                    if (!cursor.TryTake(index => (Marshal.PtrToStructure<Header>(buffers[index].Header).Flags & 1) != 0, out int index)) break;
                    var buffer = buffers[index];
                    var header = Marshal.PtrToStructure<Header>(buffer.Header);
                    if (header.Recorded > 0 && header.Recorded <= header.Length)
                    {
                        byte[] data = new byte[header.Recorded];
                        Marshal.Copy(header.Data, data, 0, data.Length);
                        onAudio(data);
                    }
                    if (running && waveInAddBuffer(handle, buffer.Header, HeaderSize) != 0)
                    { running = false; onFailure(); }
                }
            }
            if (!running) return;
        }
    }

    internal Task StopAsync()
    {
        lock (buffers) return stopping ??= Task.Run(StopCoreAsync);
    }

    private async Task StopCoreAsync()
    {
        uint reset = 0;
        lock (ioLock)
        {
            running = false;
            if (handle != 0) reset = waveInReset(handle);
        }
        ready.Set();
        if (worker != null) await worker.ConfigureAwait(false);
        if (handle != 0)
        {
            // Never free memory while the audio driver may still own a prepared buffer.
            if (reset != 0) throw new InvalidOperationException("麦克风重置失败，请退出 VoxType 后重开。");
            foreach (var buffer in buffers)
            {
                var header = Marshal.PtrToStructure<Header>(buffer.Header);
                if ((header.Flags & 2) != 0 && waveInUnprepareHeader(handle, buffer.Header, HeaderSize) != 0)
                    throw new InvalidOperationException("麦克风缓冲未释放，请退出 VoxType 后重开。");
            }
            if (waveInClose(handle) != 0) throw new InvalidOperationException("麦克风关闭失败，请退出 VoxType 后重开。");
            handle = 0;
        }
        foreach (var buffer in buffers) { Marshal.FreeHGlobal(buffer.Header); Marshal.FreeHGlobal(buffer.Data); }
        buffers.Clear();
        ready.Dispose();
    }
}
