using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using VoxType.Core;

namespace VoxType.Windows;

internal sealed class Shortcuts : NativeWindow, IDisposable
{
    private Settings settings = new();
    private readonly Timer released = new() { Interval = 25 };
    private bool held;
    private nint hook;
    private Native.Hook? callback;
    internal Action Pressed = () => { };
    internal Action Released = () => { };

    internal Shortcuts()
    {
        CreateHandle(new CreateParams { Caption = "VoxType shortcut", Parent = new nint(-3) });
        released.Tick += (_, _) =>
        {
            if (!held || IsHeld) return;
            held = false; released.Stop(); Released();
        };
    }

    internal static void Validate(uint modifiers, uint key)
        => ShortcutPolicy.Validate(modifiers, key);

    internal void Bind(Settings next)
    {
        if (next.Key != 0) Validate(next.Modifiers, next.Key);
        Native.UnregisterHotKey(Handle, 1);
        if (next.Key != 0 && !Native.RegisterHotKey(Handle, 1, next.Modifiers | 0x4000, next.Key))
        {
            if (settings.Key != 0) Native.RegisterHotKey(Handle, 1, settings.Modifiers | 0x4000, settings.Key);
            throw new InvalidOperationException("快捷键已被占用，原设置已保留。");
        }
        settings = next;
    }

    internal bool IsHeld => held && Native.KeyDown((int)settings.Key) && ShortcutPolicy.Held(settings.Modifiers,
        (Native.KeyDown(0x11) ? 2u : 0) | (Native.KeyDown(0x12) ? 1u : 0) | (Native.KeyDown(0x10) ? 4u : 0));
    internal void Suspend() => Native.UnregisterHotKey(Handle, 1);
    internal void Resume() => Bind(settings);

    internal void WatchManualInput(Action changed)
    {
        EndWatch();
        callback = (code, message, data) =>
        {
            if (code >= 0 && (message == 0x100 || message == 0x104))
            {
                var key = Marshal.PtrToStructure<Native.KeyboardEvent>(data);
                bool modifier = key.Key is 0x10 or 0x11 or 0x12 or >= 0xA0 and <= 0xA5;
                if (key.Extra != (nuint)Native.Marker && !modifier && key.Key != settings.Key) changed();
            }
            return Native.CallNextHookEx(hook, code, message, data);
        };
        hook = Native.SetWindowsHookExW(13, callback, Native.GetModuleHandle(null), 0);
        if (hook == 0) { callback = null; throw new InvalidOperationException("无法监测听写期间的手动输入，本次已取消。"); }
    }

    internal void EndWatch()
    {
        if (hook != 0) Native.UnhookWindowsHookEx(hook);
        hook = 0; callback = null;
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == 0x312 && message.WParam == 1 && !held)
        { held = true; released.Start(); Pressed(); }
        base.WndProc(ref message);
    }

    internal static string Describe(Settings value) => value.Key == 0 ? "未设置" :
        ((value.Modifiers & 2) != 0 ? "Ctrl + " : "") + ((value.Modifiers & 1) != 0 ? "Alt + " : "")
        + ((value.Modifiers & 4) != 0 ? "Shift + " : "") + (value.Key == 32 ? "空格" : ((Keys)value.Key).ToString());

    public void Dispose()
    { released.Dispose(); EndWatch(); Native.UnregisterHotKey(Handle, 1); DestroyHandle(); }
}
