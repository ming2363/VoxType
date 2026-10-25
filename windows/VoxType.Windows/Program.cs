using System;
using System.Drawing;
using System.Threading;
using System.Windows.Forms;

namespace VoxType.Windows;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        using var instance = new Mutex(true, @"Local\VoxType.Windows", out bool created);
        if (!created) { MessageBox.Show("VoxType 已在系统托盘运行。", "VoxType"); return; }
        ApplicationConfiguration.Initialize();
        try { Application.Run(new TrayApp()); }
        catch { MessageBox.Show("VoxType 无法启动。请检查 Windows 凭据、配置文件和运行环境。", "VoxType"); }
    }
}

internal sealed class TrayApp : ApplicationContext
{
    private Settings settings = SettingsStore.Load();
    private readonly Shortcuts shortcuts = new();
    private readonly StatusOverlay overlay = new();
    private readonly NotifyIcon tray;
    private readonly DictationController controller;
    private readonly ToolStripMenuItem state = new("等待设置快捷键") { Enabled = false };
    private readonly ToolStripMenuItem copy = new("复制最近一次结果");
    private SettingsForm? form;
    private bool exiting;

    internal TrayApp()
    {
        SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());
        controller = new DictationController(shortcuts, SynchronizationContext.Current!);
        controller.Status = (title, detail, persistent) =>
        { if (exiting) return; state.Text = title; overlay.Update(title, detail, persistent); };
        shortcuts.Pressed = () => controller.Start(settings);
        shortcuts.Released = controller.Release;
        var menu = new ContextMenuStrip();
        menu.Items.Add(state);
        menu.Items.Add("设置…", null, (_, _) => OpenSettings());
        copy.Click += (_, _) => CopyLastResult();
        menu.Items.Add(copy);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出", null, (_, _) => ExitThread());
        menu.Opening += (_, _) => copy.Enabled = controller.LastResult.Length != 0;
        tray = new NotifyIcon { Text = "VoxType · 按住说话", ContextMenuStrip = menu, Visible = true,
            Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? SystemIcons.Application };
        tray.DoubleClick += (_, _) => OpenSettings();
        try { shortcuts.Bind(settings); state.Text = "快捷键：" + Shortcuts.Describe(settings); }
        catch { settings = settings with { Key = 0, Modifiers = 0 }; }
        if (settings.Key == 0 || string.IsNullOrEmpty(Credentials.Read())) OpenSettings();
    }

    private void OpenSettings()
    {
        if (controller.Busy) { state.Text = "请先松开快捷键并等待听写结束。"; return; }
        form ??= new SettingsForm(shortcuts, () => settings, Save);
        form.Reload(); form.Show(); form.Activate();
    }

    private void Save(Settings next, bool autoStart)
    {
        var previous = settings;
        bool previousStart = SettingsStore.AutoStart;
        try
        {
            shortcuts.Bind(next);
            SettingsStore.AutoStart = autoStart;
            SettingsStore.Save(next);
            settings = next;
        }
        catch
        {
            shortcuts.Bind(previous);
            SettingsStore.AutoStart = previousStart;
            throw;
        }
        state.Text = "快捷键：" + Shortcuts.Describe(settings);
    }

    private void CopyLastResult()
    {
        if (controller.LastResult.Length == 0) return;
        try { Clipboard.SetText(controller.LastResult); }
        catch { state.Text = "剪贴板正忙，请稍后再复制。"; }
    }

    protected override async void ExitThreadCore()
    {
        if (exiting) return;
        exiting = true;
        await controller.CloseAsync();
        shortcuts.Dispose(); overlay.Dispose(); form?.Dispose();
        var icon = tray.Icon; tray.Visible = false; tray.Dispose(); icon?.Dispose();
        base.ExitThreadCore();
    }
}
