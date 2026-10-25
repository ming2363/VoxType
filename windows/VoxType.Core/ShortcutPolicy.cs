namespace VoxType.Core;

public static class ShortcutPolicy
{
    public static void Validate(uint modifiers, uint key)
    {
        if ((modifiers & 3) == 0 || (modifiers & ~7u) != 0 || key is < 8 or > 254
            || key is 0x10 or 0x11 or 0x12 or 0x5B or 0x5C)
            throw new InvalidOperationException("请选择 Ctrl 或 Alt 加另一个按键的快捷键。");
        if ((key == 0x20 && modifiers is 1 or 2) || (modifiers == 1 && key is 0x09 or 0x73)
            || (modifiers == 3 && key == 0x2E))
            throw new InvalidOperationException("此组合常用于系统菜单、输入法或系统操作，请选择其他组合。");
    }

    public static bool Held(uint required, uint actual) => (actual & required) == required;
}
