namespace VoxType.Core;

public sealed record Sentence(string Id, string Text);
public sealed record RecognitionSnapshot(IReadOnlyList<Sentence> Committed, string Live,
    bool CorrectionIncomplete, bool Desynced)
{
    public string Text => string.Concat(Committed.Select(x => x.Text)) + Live;
}

public sealed class RecognitionReducer(string sessionId)
{
    private readonly List<Sentence> committed = [];
    private string live = "";
    private bool incomplete, desynced;
    public RecognitionSnapshot Snapshot => new(committed.ToArray(), live, incomplete, desynced);

    public RecognitionSnapshot? Apply(string eventSessionId, AsrMessage message)
    {
        if (eventSessionId != sessionId) return null;
        if (desynced && !message.Final) return Snapshot;
        if (message.Utterances.Count != 0)
        {
            var partial = new List<string>();
            foreach (var utterance in message.Utterances)
            {
                int index = committed.FindIndex(x => x.Id == utterance.Identity);
                if (utterance.Definite)
                {
                    var sentence = new Sentence(utterance.Identity, utterance.Text);
                    if (index >= 0) committed[index] = sentence;
                    else committed.Add(sentence);
                }
                else if (index < 0) partial.Add(utterance.Text);
            }
            live = string.Concat(partial);
        }
        else if (message.Text is { } full)
        {
            string prefix = string.Concat(committed.Select(x => x.Text));
            if (full.StartsWith(prefix, StringComparison.Ordinal)) live = full[prefix.Length..];
            else if (committed.Count != 0)
            {
                string earlier = string.Concat(committed.Take(committed.Count - 1).Select(x => x.Text));
                if (!full.StartsWith(earlier, StringComparison.Ordinal)) desynced = true;
                else
                {
                    committed[^1] = committed[^1] with { Text = full[earlier.Length..] };
                    live = "";
                }
            }
            else live = full;
        }
        if (message.Final && live.Length != 0)
        {
            committed.Add(new Sentence("final-tail", live));
            live = "";
            incomplete = true;
        }
        return Snapshot;
    }

    public static string Sanitize(string text) => new string(
        text.Replace("\r\n", " ").Replace('\r', ' ').Replace('\n', ' ').Replace('\t', ' ')
            .Replace('\u2028', ' ').Replace('\u2029', ' ')
            .Where(ch => !char.IsControl(ch)).ToArray()).Trim();
}
