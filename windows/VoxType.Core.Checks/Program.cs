using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using VoxType.Core;

int checks = 0;
void Check(bool value, string name)
{
    if (!value) throw new Exception(name);
    checks++;
    Console.WriteLine($"PASS: {name}");
}
byte[] Unzip(byte[] bytes)
{
    using var zip = new GZipStream(new MemoryStream(bytes), CompressionMode.Decompress);
    using var output = new MemoryStream(); zip.CopyTo(output); return output.ToArray();
}
byte[] Server(string json, bool final = false)
{
    byte[] payload = Encoding.UTF8.GetBytes(json);
    byte[] frame = new byte[8 + payload.Length];
    frame[0] = 0x11; frame[1] = final ? (byte)0x92 : (byte)0x90; frame[2] = 0x10;
    BinaryPrimitives.WriteInt32BigEndian(frame.AsSpan(4), payload.Length);
    payload.CopyTo(frame, 8); return frame;
}
byte[] request = DoubaoProtocol.FullRequest(1, "test");
Check(request.Take(4).SequenceEqual(new byte[] { 0x11, 0x11, 0x11, 0 }), "official request header");
Check(BinaryPrimitives.ReadInt32BigEndian(request.AsSpan(4)) == 1, "first sequence");
using (var json = JsonDocument.Parse(Unzip(request[12..])))
{
    var options = json.RootElement.GetProperty("request");
    Check(options.GetProperty("enable_nonstream").GetBoolean(), "sentence-final recognition enabled");
    Check(!options.GetProperty("enable_ddc").GetBoolean(), "no semantic rewriting");
    Check(json.RootElement.GetProperty("audio").GetProperty("rate").GetInt32() == 16000, "16 kHz PCM");
}
byte[] finalAudio = DoubaoProtocol.Audio(7, [1, 2, 3, 4], true);
Check(finalAudio[1] == 0x23 && BinaryPrimitives.ReadInt32BigEndian(finalAudio.AsSpan(4)) == -7, "last packet uses negative sequence");
Check(Unzip(finalAudio[12..]).SequenceEqual(new byte[] { 1, 2, 3, 4 }), "PCM is unchanged by framing");
var message = DoubaoProtocol.Decode(Server("{\"result\":{\"text\":\"你好\",\"utterances\":[{\"text\":\"你好\",\"start_time\":0,\"definite\":true}]}}", true))!;
Check(message.Final && message.Utterances[0].Definite && message.Text == "你好", "server result parsed");
try { DoubaoProtocol.Decode(Server("{}")[..^1]); throw new Exception("Accepted truncated payload"); }
catch (InvalidDataException) { Check(true, "truncated frame rejected"); }
try { DoubaoProtocol.Decode([0x10, 0x90, 0x10, 0]); throw new Exception("Accepted zero header"); }
catch (InvalidDataException) { Check(true, "zero header rejected"); }
var reducer = new RecognitionReducer("session");
RecognitionSnapshot Update(string text, bool definite, bool final = false) =>
    reducer.Apply("session", new AsrMessage(final, text, [new Utterance(text, 0, definite)]))!;
Check(Update("开回忆", false).Text == "开回忆", "partial result");
Check(Update("开会议。", true).Text == "开会议。", "sentence-final correction replaces partial");
Check(Update("明天开会议。", true, true).Text == "明天开会议。", "second-pass correction replaces committed sentence");
Check(reducer.Snapshot.Committed.Count == 1, "no duplicate sentence");
Check(reducer.Apply("old", message) is null, "old session ignored");
Check(RecognitionReducer.Sanitize("a\r\nb\tc\0\u2028d") == "a b c d", "no injected Enter or control characters");
var timeout = new RecognitionReducer("s");
_ = timeout.Apply("s", new AsrMessage(false, "未定稿", []));
Check(timeout.Apply("s", new AsrMessage(true, null, []))!.CorrectionIncomplete, "unconfirmed final tail is marked incomplete");
Check(RecognitionReducer.Sanitize("a\u0008\u001bb😀") == "ab😀", "backspace and escape removed, emoji preserved");
Check(System.Runtime.InteropServices.Marshal.SizeOf<VoxType.Windows.Native.Input>() == 40, "Windows x64 INPUT ABI size");
Check(System.Runtime.InteropServices.Marshal.SizeOf<VoxType.Windows.Native.GuiInfo>() == 72, "Windows x64 GUI thread ABI size");
Check(System.Runtime.InteropServices.Marshal.SizeOf<VoxType.Windows.Native.KeyboardEvent>() == 24, "Windows x64 keyboard hook ABI size");
var headerType = typeof(VoxType.Windows.WaveCapture).GetNestedType("Header", System.Reflection.BindingFlags.NonPublic)!;
var formatType = typeof(VoxType.Windows.WaveCapture).GetNestedType("Format", System.Reflection.BindingFlags.NonPublic)!;
Check(System.Runtime.InteropServices.Marshal.SizeOf(headerType) == 48, "Windows x64 WAVEHDR ABI size");
Check(System.Runtime.InteropServices.Marshal.SizeOf(formatType) == 18, "packed WAVEFORMATEX ABI size");
ShortcutPolicy.Validate(3, 32);
Check(ShortcutPolicy.Held(3, 7) && !ShortcutPolicy.Held(3, 2), "releasing a required modifier ends a held shortcut");
foreach (var rejected in new[] { (0u, 32u), (1u, 32u), (2u, 32u), (1u, 9u), (1u, 0x73u), (3u, 0x2Eu), (8u, 65u) })
{
    try { ShortcutPolicy.Validate(rejected.Item1, rejected.Item2); throw new Exception("Accepted reserved shortcut"); }
    catch (InvalidOperationException) { Check(true, "reserved or ambiguous shortcut rejected"); }
}
var ring = new AudioRingCursor(4);
bool[] complete = [true, false, false, false];
Check(ring.TryTake(i => complete[i], out int taken) && taken == 0, "first microphone buffer consumed");
complete = [true, false, true, true];
Check(!ring.TryTake(i => complete[i], out _), "completed later buffer cannot overtake an earlier pending buffer");
complete[1] = true;
var order = new List<int>();
for (int i = 0; i < 4; i++) if (ring.TryTake(n => complete[n], out taken)) order.Add(taken);
Check(order.SequenceEqual(new[] { 1, 2, 3, 0 }), "wrapped device buffers preserve audio order");
try { _ = new AudioRingCursor(0); throw new Exception("Accepted empty audio ring"); }
catch (ArgumentOutOfRangeException) { Check(true, "audio ring rejects invalid capacity"); }
await TransportChecks.Run(Check);
Console.WriteLine($"{checks} checks passed. Loopback websocket only; no Windows API calls, microphone, real credentials or provider usage.");
