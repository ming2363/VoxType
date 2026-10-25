namespace VoxType.Core;

/// <summary>Keep device buffers in enqueue order when multiple completions arrive together.</summary>
public sealed class AudioRingCursor
{
    private readonly int count;
    private int next;
    public AudioRingCursor(int count)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(count);
        this.count = count;
    }
    public bool TryTake(Func<int, bool> completed, out int index)
    {
        index = next;
        if (!completed(next)) return false;
        next = (next + 1) % count;
        return true;
    }
}
