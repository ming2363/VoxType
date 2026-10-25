using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Automation;
using System.Windows.Automation.Text;
using VoxType.Core;

namespace VoxType.Windows;

internal sealed class InputTarget
{
    private readonly nint window;
    private readonly int[] identity;
    private readonly string? originalValue;
    private readonly TextPatternRange? originalSelection;
    private readonly Native.GuiInfo caret;

    private InputTarget(nint window, AutomationElement element)
    {
        this.window = window;
        identity = element.GetRuntimeId();
        RequireEditable(element);
        if (element.TryGetCurrentPattern(TextPattern.Pattern, out var text))
        {
            var pattern = (TextPattern)text;
            var selections = pattern.GetSelection();
            if (selections.Length != 1) throw new InvalidOperationException("当前选区不明确，请重新点击输入框。");
            originalSelection = selections[0].Clone();
            originalValue = pattern.DocumentRange.GetText(32769);
        }
        else if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var value))
            originalValue = ((ValuePattern)value).Current.Value;
        if (originalValue?.Length > 32768) throw new InvalidOperationException("当前输入框内容过长，初版暂不自动输入。");
        caret = new Native.GuiInfo { Size = (uint)Marshal.SizeOf<Native.GuiInfo>() };
        var info = caret;
        if (Native.GetGUIThreadInfo(0, ref info)) caret = info;
        if (originalSelection == null && (caret.Focus == 0 || caret.Caret == 0))
            throw new InvalidOperationException("无法确认输入位置，初版暂不支持这个输入框。");
        if (Native.GetForegroundWindow() != window) throw new InvalidOperationException("焦点已变化，请重试。");
    }

    internal static InputTarget Capture()
    {
        nint window = Native.GetForegroundWindow();
        Native.GetWindowThreadProcessId(window, out uint pid);
        if (window == 0 || pid == Environment.ProcessId) throw new InvalidOperationException("请先点击其他应用的输入框。");
        var element = AutomationElement.FocusedElement ?? throw new InvalidOperationException("目标应用未返回输入焦点。");
        if (element.Current.ProcessId != pid) throw new InvalidOperationException("无法确认焦点所属应用。");
        return new InputTarget(window, element);
    }

    private static void RequireEditable(AutomationElement element)
    {
        var current = element.Current;
        if (current.IsPassword) throw new InvalidOperationException("不支持密码输入框。");
        if (!current.IsEnabled || !current.IsKeyboardFocusable || !current.HasKeyboardFocus
            || (current.ControlType != ControlType.Edit && current.ControlType != ControlType.Document))
            throw new InvalidOperationException("当前焦点不是可编辑输入框。");
        bool writable = false;
        if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var value))
        {
            if (((ValuePattern)value).Current.IsReadOnly) throw new InvalidOperationException("当前输入框是只读的。");
            writable = true;
        }
        if (element.TryGetCurrentPattern(TextPattern.Pattern, out var text))
        {
            object readOnly = ((TextPattern)text).DocumentRange.GetAttributeValue(TextPattern.IsReadOnlyAttribute);
            if (readOnly is true) throw new InvalidOperationException("当前文档是只读的。");
            if (readOnly is false) writable = true;
        }
        if (!writable) throw new InvalidOperationException("无法确认当前区域可编辑，已停止输入。");
    }

    private AutomationElement Validate(bool originalPosition)
    {
        if (Native.GetForegroundWindow() != window) throw new InvalidOperationException("应用已切换，已停止输入。");
        var current = AutomationElement.FocusedElement ?? throw new InvalidOperationException("输入焦点已丢失。");
        RequireEditable(current);
        if (!current.GetRuntimeId().SequenceEqual(identity)) throw new InvalidOperationException("输入框已切换，已停止输入。");
        if (originalPosition)
        {
            if (originalSelection != null)
            {
                var pattern = (TextPattern)current.GetCurrentPattern(TextPattern.Pattern);
                var selection = pattern.GetSelection();
                if (selection.Length != 1 || selection[0].CompareEndpoints(TextPatternRangeEndpoint.Start, originalSelection, TextPatternRangeEndpoint.Start) != 0
                    || selection[0].CompareEndpoints(TextPatternRangeEndpoint.End, originalSelection, TextPatternRangeEndpoint.End) != 0
                    || pattern.DocumentRange.GetText(32769) != originalValue)
                    throw new InvalidOperationException("光标或文字已变化，已停止输入。");
            }
            else
            {
                var info = new Native.GuiInfo { Size = (uint)Marshal.SizeOf<Native.GuiInfo>() };
                if (!Native.GetGUIThreadInfo(0, ref info) || info.Focus != caret.Focus || !info.CaretRect.Equals(caret.CaretRect))
                    throw new InvalidOperationException("光标已变化，已停止输入。");
                if (originalValue != null && ((ValuePattern)current.GetCurrentPattern(ValuePattern.Pattern)).Current.Value != originalValue)
                    throw new InvalidOperationException("文字已变化，已停止输入。");
            }
        }
        return current;
    }

    internal void Insert(string text, CancellationToken cancellation)
    {
        text = RecognitionReducer.Sanitize(text);
        if (text.Length == 0) return;
        Validate(true);
        // Submit once, as one serial input batch; a partial result is never retried with paste.
        if (text.Length > 16384) throw new InvalidOperationException("单次听写过长，已保留结果供手动复制。");
        var inputs = new Native.Input[text.Length * 2];
        for (int i = 0; i < text.Length; i++)
        {
            inputs[2 * i] = new Native.Input { Type = 1, Data = new Native.InputData { Keyboard = new Native.KeyboardInput
            { Scan = text[i], Flags = 4, Extra = (nuint)Native.Marker } } };
            inputs[2 * i + 1] = inputs[2 * i];
            inputs[2 * i + 1].Data.Keyboard.Flags = 4 | 2;
        }
        cancellation.ThrowIfCancellationRequested();
        if (Native.ModifiersDown()) throw new InvalidOperationException("修饰键仍按着，本次未输入。");
        if (Native.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Native.Input>()) != inputs.Length)
            throw new InvalidOperationException("无法确认输入完成；可能受管理员权限限制，已停止且不会重试。");
    }
}
