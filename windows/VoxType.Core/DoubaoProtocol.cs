using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;
using System.Text.Json;

namespace VoxType.Core;

public sealed record Utterance(string Text, int? StartTime, bool Definite)
{
    public string Identity => StartTime is { } start ? $"t:{start}" : $"x:{Text}";
}

public sealed record AsrMessage(bool Final, string? Text, IReadOnlyList<Utterance> Utterances,
    int Code = 0, string? Error = null)
{
    public bool Failed => Code is not (0 or 20000000);
}

public static class DoubaoProtocol
{
    public const string Endpoint = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async";
    public const string ResourceId = "volc.seedasr.sauc.duration";
    public const int SampleRate = 16000;
    public const int PacketBytes = 6400;
    public const int MaxFrameBytes = 4 * 1024 * 1024;

    public static byte[] Request(string uid) => JsonSerializer.SerializeToUtf8Bytes(new
    {
        user = new { uid },
        audio = new { format = "pcm", codec = "raw", rate = SampleRate, bits = 16, channel = 1 },
        request = new
        {
            model_name = "bigmodel", enable_itn = true, enable_punc = true,
            enable_ddc = false, show_utterances = true, enable_nonstream = true,
            result_type = "full", end_window_size = 800
        }
    });

    public static byte[] FullRequest(int sequence, string uid) => Encode(0x11, sequence, Request(uid));

    public static byte[] Audio(int sequence, byte[] pcm, bool last) =>
        Encode(last ? (byte)0x23 : (byte)0x21, last ? -Math.Abs(sequence) : sequence, pcm);

    private static byte[] Encode(byte typeAndFlags, int sequence, byte[] data)
    {
        using var buffer = new MemoryStream();
        using (var zip = new GZipStream(buffer, CompressionLevel.Fastest, leaveOpen: true)) zip.Write(data);
        byte[] payload = buffer.ToArray();
        byte[] frame = new byte[12 + payload.Length];
        frame[0] = 0x11;
        frame[1] = typeAndFlags;
        frame[2] = 0x11; // Official example uses JSON/gzip flags on PCM packets too.
        BinaryPrimitives.WriteInt32BigEndian(frame.AsSpan(4), sequence);
        BinaryPrimitives.WriteInt32BigEndian(frame.AsSpan(8), payload.Length);
        payload.CopyTo(frame, 12);
        return frame;
    }

    public static AsrMessage? Decode(byte[] frame)
    {
        if (frame.Length < 4 || frame.Length > MaxFrameBytes || frame[0] >> 4 != 1)
            throw new InvalidDataException("Invalid ASR frame header.");
        int offset = (frame[0] & 15) * 4;
        if (offset < 4 || offset > frame.Length) throw new InvalidDataException("Invalid ASR header size.");
        int type = frame[1] >> 4, flags = frame[1] & 15;
        if ((flags & 1) != 0) _ = ReadInt(frame, ref offset);
        if ((flags & 4) != 0) _ = ReadInt(frame, ref offset);
        int code = type == 15 ? ReadInt(frame, ref offset) : 0;
        if (type is not (9 or 15)) return null;
        int size = ReadInt(frame, ref offset);
        if (size < 0 || size > MaxFrameBytes || size != frame.Length - offset)
            throw new InvalidDataException("Truncated ASR payload.");
        byte[] payload = frame.AsSpan(offset, size).ToArray();
        int compression = frame[2] & 15;
        if (compression == 1)
        {
            using var input = new GZipStream(new MemoryStream(payload), CompressionMode.Decompress);
            using var output = new MemoryStream();
            byte[] chunk = new byte[8192];
            int count;
            while ((count = input.Read(chunk)) != 0)
            {
                if (output.Length + count > MaxFrameBytes) throw new InvalidDataException("ASR payload too large.");
                output.Write(chunk, 0, count);
            }
            payload = output.ToArray();
        }
        else if (compression != 0) throw new InvalidDataException("Unsupported ASR compression.");
        if (type == 15 && frame[2] >> 4 == 0)
            return new AsrMessage((flags & 2) != 0, null, [], code, Encoding.UTF8.GetString(payload));
        using var json = JsonDocument.Parse(payload);
        var root = json.RootElement;
        if (root.TryGetProperty("code", out var c) && c.TryGetInt32(out int serverCode)) code = serverCode;
        var utterances = new List<Utterance>();
        string? text = null;
        if (root.TryGetProperty("result", out var result))
        {
            if (result.ValueKind == JsonValueKind.Array)
            {
                var parts = new List<string>();
                foreach (var item in result.EnumerateArray())
                {
                    parts.Add(String(item, "text") ?? "");
                    AddUtterances(item, utterances);
                }
                text = string.Concat(parts);
            }
            else if (result.ValueKind == JsonValueKind.Object)
            {
                text = String(result, "text");
                AddUtterances(result, utterances);
            }
        }
        return new AsrMessage((flags & 2) != 0, text, utterances, code,
            String(root, "message") ?? String(root, "error"));
    }

    private static void AddUtterances(JsonElement item, List<Utterance> output)
    {
        if (item.TryGetProperty("utterances", out var nested) && nested.ValueKind == JsonValueKind.Array)
            foreach (var sentence in nested.EnumerateArray()) output.Add(ParseUtterance(sentence));
        else if (item.TryGetProperty("definite", out _)) output.Add(ParseUtterance(item));
    }

    private static Utterance ParseUtterance(JsonElement item) => new(String(item, "text") ?? "",
        item.TryGetProperty("start_time", out var start) && start.TryGetInt32(out int n) ? n : null,
        item.TryGetProperty("definite", out var definite) && definite.ValueKind == JsonValueKind.True);

    private static string? String(JsonElement item, string name) =>
        item.ValueKind == JsonValueKind.Object && item.TryGetProperty(name, out var value)
        && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static int ReadInt(byte[] frame, ref int offset)
    {
        if (offset > frame.Length - 4) throw new InvalidDataException("Truncated ASR frame.");
        int value = BinaryPrimitives.ReadInt32BigEndian(frame.AsSpan(offset, 4));
        offset += 4;
        return value;
    }
}
