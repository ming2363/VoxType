using System;
using System.Runtime.InteropServices;

namespace VoxType.Windows;

internal static class Native
{
    internal const ulong Marker = 0x564F5854;
    [StructLayout(LayoutKind.Sequential)] internal struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] internal struct GuiInfo
    {
        public uint Size, Flags;
        public nint Active, Focus, Capture, MenuOwner, MoveSize, Caret;
        public Rect CaretRect;
    }
    [StructLayout(LayoutKind.Sequential)] internal struct KeyboardEvent
    {
        public uint Key, Scan, Flags, Time;
        public nuint Extra;
    }
    [StructLayout(LayoutKind.Sequential)] internal struct KeyboardInput
    {
        public ushort Key, Scan;
        public uint Flags, Time;
        public nuint Extra;
    }
    [StructLayout(LayoutKind.Explicit, Size = 32)] internal struct InputData
    { [FieldOffset(0)] public KeyboardInput Keyboard; }
    [StructLayout(LayoutKind.Sequential)] internal struct Input
    { public uint Type; public InputData Data; }
    internal delegate nint Hook(int code, nint message, nint data);
    [DllImport("user32.dll")] internal static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(nint window, out uint pid);
    [DllImport("user32.dll")] internal static extern bool GetGUIThreadInfo(uint thread, ref GuiInfo info);
    [DllImport("user32.dll")] internal static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll", SetLastError = true)] internal static extern bool RegisterHotKey(nint window, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] internal static extern bool UnregisterHotKey(nint window, int id);
    [DllImport("user32.dll", SetLastError = true)] internal static extern uint SendInput(uint count, Input[] inputs, int size);
    [DllImport("user32.dll", SetLastError = true)] internal static extern nint SetWindowsHookExW(int id, Hook callback, nint module, uint thread);
    [DllImport("user32.dll")] internal static extern bool UnhookWindowsHookEx(nint hook);
    [DllImport("user32.dll")] internal static extern nint CallNextHookEx(nint hook, int code, nint message, nint data);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] internal static extern nint GetModuleHandle(string? module);
    internal static bool KeyDown(int key) => (GetAsyncKeyState(key) & 0x8000) != 0;
    internal static bool ModifiersDown() => KeyDown(0x10) || KeyDown(0x11) || KeyDown(0x12) || KeyDown(0x5B) || KeyDown(0x5C);
}
