using System.Drawing;
using System.Windows.Forms;

namespace VoxType.Windows;

internal sealed class StatusOverlay : Form
{
    private readonly Label title = new() { Left = 16, Top = 10, Width = 420, Height = 22, ForeColor = Color.White };
    private readonly Label detail = new() { Left = 16, Top = 36, Width = 420, Height = 28, ForeColor = Color.Gainsboro, AutoEllipsis = true };
    private readonly Timer dismiss = new() { Interval = 2400 };
    private bool persistentDisplay;
    internal StatusOverlay()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false; TopMost = true;
        BackColor = Color.FromArgb(30, 34, 40);
        ClientSize = new Size(452, 76);
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = new Font("Microsoft YaHei UI", 9);
        Controls.Add(title); Controls.Add(detail);
        dismiss.Tick += (_, _) => { if (!persistentDisplay) { dismiss.Stop(); Hide(); } };
    }
    protected override bool ShowWithoutActivation => true;
    protected override CreateParams CreateParams
    {
        get { var p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x80 | 0x20; return p; }
    }
    internal void Update(string state, string text, bool persistent)
    {
        dismiss.Stop();
        persistentDisplay = persistent;
        title.Text = state;
        int start = System.Math.Max(0, text.Length - 120);
        if (start > 0 && char.IsLowSurrogate(text[start])) start++;
        detail.Text = (start > 0 ? "…" : "") + text[start..];
        var area = Screen.FromHandle(Native.GetForegroundWindow()).WorkingArea;
        Location = new Point(area.Left + (area.Width - Width) / 2, area.Top + 16);
        Show();
        if (!persistent) dismiss.Start();
    }
    protected override void Dispose(bool disposing)
    { if (disposing) dismiss.Dispose(); base.Dispose(disposing); }
}
