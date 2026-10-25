using System;
using System.Drawing;
using System.Windows.Forms;

namespace VoxType.Windows;

internal sealed class SettingsForm : Form
{
    private readonly Shortcuts shortcuts;
    private readonly Func<Settings> getSettings;
    private readonly Action<Settings, bool> saveSettings;
    private readonly TextBox apiKey = new() { Width = 400, UseSystemPasswordChar = true };
    private readonly Label keyState = new() { AutoSize = true };
    private readonly Label shortcutState = new() { AutoSize = true };
    private readonly Label notice = new() { AutoSize = true, MaximumSize = new Size(460, 0), ForeColor = Color.DarkSlateBlue };
    private readonly CheckBox autoStart = new() { Text = "登录 Windows 时自动启动", AutoSize = true };
    private bool recording;
    private uint key, modifiers;

    internal SettingsForm(Shortcuts shortcuts, Func<Settings> getSettings, Action<Settings, bool> saveSettings)
    {
        this.shortcuts = shortcuts; this.getSettings = getSettings; this.saveSettings = saveSettings;
        Text = "VoxType for Windows · 预览版";
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(520, 510);
        MinimumSize = new Size(520, 550);
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = new Font("Microsoft YaHei UI", 9);
        var layout = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown,
            WrapContents = false, AutoScroll = true, Padding = new Padding(20) };
        Controls.Add(layout);
        layout.Controls.Add(new Label { Text = "按住说话，松开后输入定稿。", AutoSize = true, Font = new Font(Font, FontStyle.Bold) });
        layout.Controls.Add(new Label { Text = "豆包流式语音识别 2.0 API Key", AutoSize = true, Margin = new Padding(3, 18, 3, 5) });
        layout.Controls.Add(apiKey);
        var keys = new FlowLayoutPanel { AutoSize = true };
        var saveKey = new Button { Text = "保存 Key", AutoSize = true };
        saveKey.Click += (_, _) => Try(() => { Credentials.Save(apiKey.Text); apiKey.Clear(); RefreshKeyState(); notice.Text = "Key 已保存在 Windows 凭据管理器。"; });
        var deleteKey = new Button { Text = "删除已保存 Key", AutoSize = true };
        deleteKey.Click += (_, _) => Try(() => { Credentials.Delete(); apiKey.Clear(); RefreshKeyState(); });
        keys.Controls.Add(saveKey); keys.Controls.Add(deleteKey); layout.Controls.Add(keys); layout.Controls.Add(keyState);
        layout.Controls.Add(new Label { Text = "全局听写快捷键", AutoSize = true, Margin = new Padding(3, 18, 3, 5) });
        layout.Controls.Add(shortcutState);
        var record = new Button { Text = "录制快捷键", AutoSize = true };
        record.Click += (_, _) =>
        {
            shortcuts.Suspend(); recording = true;
            notice.Text = "请按 Ctrl 或 Alt 加另一个键；按 Esc 取消。";
        };
        layout.Controls.Add(record);
        autoStart.Margin = new Padding(3, 18, 3, 10); layout.Controls.Add(autoStart);
        var save = new Button { Text = "保存设置", AutoSize = true };
        save.Click += (_, _) => Try(() =>
        {
            CancelRecording();
            Shortcuts.Validate(modifiers, key);
            saveSettings(getSettings() with { Key = key, Modifiers = modifiers }, autoStart.Checked);
            notice.Text = "设置已保存。回到目标输入框，按住快捷键说话。";
        });
        layout.Controls.Add(save); layout.Controls.Add(notice);
        layout.Controls.Add(new Label { AutoSize = true, MaximumSize = new Size(460, 0), Margin = new Padding(3, 18, 3, 5),
            Text = "仅在听写时采集麦克风并连接豆包，ASR 用量由服务商计费。\n自动输入不占剪贴板；不支持密码框，不自动按回车。\n本预览版尚未通过 Windows 实机验证，部分输入框和管理员权限应用可能不兼容。" });
        FormClosing += (_, e) =>
        {
            if (e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                Try(() => { CancelRecording(); Hide(); });
            }
        };
        Reload();
    }

    internal void Reload()
    {
        var settings = getSettings(); key = settings.Key; modifiers = settings.Modifiers;
        shortcutState.Text = Shortcuts.Describe(settings);
        Try(() => { autoStart.Checked = SettingsStore.AutoStart; RefreshKeyState(); });
    }
    private void RefreshKeyState() => keyState.Text = string.IsNullOrEmpty(Credentials.Read()) ? "尚未保存 Key" : "已保存 Key（不会在界面回显）";
    private void Try(Action action)
    { try { action(); } catch (Exception ex) { notice.Text = ex.Message; } }
    private void CancelRecording()
    {
        if (!recording) return;
        shortcuts.Resume();
        recording = false;
    }
    protected override bool ProcessCmdKey(ref Message message, Keys keyData)
    {
        if (!recording) return base.ProcessCmdKey(ref message, keyData);
        var code = keyData & Keys.KeyCode;
        if (code == Keys.Escape) { Try(CancelRecording); notice.Text = "已取消录制。"; return true; }
        if (code is Keys.ControlKey or Keys.Menu or Keys.ShiftKey) return true;
        uint next = ((keyData & Keys.Control) != 0 ? 2u : 0) | ((keyData & Keys.Alt) != 0 ? 1u : 0)
            | ((keyData & Keys.Shift) != 0 ? 4u : 0);
        Try(() =>
        {
            Shortcuts.Validate(next, (uint)code);
            modifiers = next; key = (uint)code;
            shortcutState.Text = Shortcuts.Describe(getSettings() with { Key = key, Modifiers = modifiers });
            CancelRecording(); notice.Text = "快捷键已录制，点击保存设置后生效。";
        });
        return true;
    }
}
