using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;

namespace VoxType.Windows;

internal sealed record Settings
{
    public uint Modifiers { get; init; }
    public uint Key { get; init; }
    public string Uid { get; init; } = "voxtype-win-" + Guid.NewGuid();
}

internal static class SettingsStore
{
    private static readonly string PathName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VoxType", "settings.json");
    internal static Settings Load()
    {
        if (!File.Exists(PathName)) return new Settings();
        try { return JsonSerializer.Deserialize<Settings>(File.ReadAllText(PathName)) ?? new Settings(); }
        catch (JsonException) { throw new InvalidOperationException("设置文件损坏，请备份并移除 VoxType 的 settings.json 后重试。"); }
    }
    internal static void Save(Settings value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(PathName)!);
        File.WriteAllText(PathName + ".tmp", JsonSerializer.Serialize(value));
        File.Move(PathName + ".tmp", PathName, true);
    }
    internal static bool AutoStart
    {
        get { using var run = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"); return run?.GetValue("VoxType") is string; }
        set
        {
            using var run = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
            if (value) run.SetValue("VoxType", "\"" + Environment.ProcessPath + "\"");
            else run.DeleteValue("VoxType", false);
        }
    }
}

internal static class Credentials
{
    private const string Target = "VoxType.Windows.Doubao";
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct Credential
    {
        public uint Flags, Type;
        public string TargetName;
        public nint Comment;
        public long Written;
        public uint BlobSize;
        public nint Blob;
        public uint Persist, AttributeCount;
        public nint Attributes, Alias;
        public string UserName;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CredReadW(string target, uint type, uint flags, out nint credential);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CredWriteW(ref Credential credential, uint flags);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CredDeleteW(string target, uint type, uint flags);
    [DllImport("advapi32.dll")] private static extern void CredFree(nint buffer);
    internal static string? Read()
    {
        if (!CredReadW(Target, 1, 0, out nint pointer))
        {
            if (Marshal.GetLastWin32Error() == 1168) return null;
            throw new InvalidOperationException("无法读取 Windows 凭据管理器。");
        }
        try
        {
            var credential = Marshal.PtrToStructure<Credential>(pointer);
            return Marshal.PtrToStringUni(credential.Blob, (int)credential.BlobSize / 2);
        }
        finally { CredFree(pointer); }
    }
    internal static void Save(string text)
    {
        text = text.Trim();
        if (text.Length == 0) throw new InvalidOperationException("API Key 不能为空。");
        byte[] bytes = Encoding.Unicode.GetBytes(text);
        if (bytes.Length > 2560) throw new InvalidOperationException("API Key 长度异常。");
        nint blob = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var value = new Credential { Type = 1, TargetName = Target, Blob = blob, BlobSize = (uint)bytes.Length, Persist = 2, UserName = "Doubao" };
            if (!CredWriteW(ref value, 0)) throw new InvalidOperationException("无法保存到 Windows 凭据管理器。");
        }
        finally { Marshal.Copy(new byte[bytes.Length], 0, blob, bytes.Length); Marshal.FreeHGlobal(blob); Array.Clear(bytes); }
    }
    internal static void Delete()
    {
        if (!CredDeleteW(Target, 1, 0) && Marshal.GetLastWin32Error() != 1168)
            throw new InvalidOperationException("无法删除 Windows 凭据。");
    }
}
