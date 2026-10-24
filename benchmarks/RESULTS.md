# VoxType measurement report — 2026-10-24

[中文摘要](#中文摘要) · [Method and reproduction](README.md) · [Raw per-request results](results/2026-10-24-doubao-synthetic.json)

## What was actually run

30 original fictional sentences (10 Chinese, 10 English, 10 mixed), each twice: **60/60 requests succeeded**. Input was synthesized by macOS `say`, not spoken into a microphone. The runner compiled the current application's real ASR client and core reducer without invoking the app UI or text insertion.

- Machine: Apple M4 Pro, arm64; macOS version recorded in the raw result's `environment`.
- Start/end: **2026-10-24 15:13:22–15:18:07, UTC+08:00** (07:13:22–07:18:07 UTC).
- Audio sent in the full run: **221.379 seconds (3.69 minutes)**. One earlier successful smoke test added approximately 3.7 seconds. No exact monetary charge was queried; service billing may round each request.
- 16kHz PCM, 16-bit, mono; 200ms paced packets, with 200ms appended silence.
- Two-pass ASR enabled, punctuation/ITN enabled, semantic smoothing disabled; app's default 3-second final timeout.
- Network route/RTT was not controlled. Connections were fresh per request. No retries or outlier removal.
- Source and audio hashes, individual transcripts/timings, failures and scoring aggregates are recorded in the raw file. No credentials, private user audio or hardware serial numbers are included.

## Latency

| ASR transport metric | N | P50 | P95 |
| --- | ---: | ---: | ---: |
| First nonempty text after starting the post-handshake PCM timeline | 60 | **891 ms** | **1,292 ms** |
| Final response after enqueueing the last audio packet | 60 | **471 ms** | **698 ms** |
| Connection start to first parsed response / handshake | 60 | 418 ms | 482 ms |

These intervals **exclude microphone initialization and text-field insertion**. First-text timing includes the available audio, packet pacing and provider/network processing; it is not measured from a human speech-onset marker. Final tail starts when the last chunk enters the sending queue, not when the user releases a physical shortcut. These numbers cannot be compared with another app's end-to-end timing without a matched protocol.

## Recognition errors

| Category | Unique sentences | Requests | Reference units | Edit errors | Micro-averaged error rate |
| --- | ---: | ---: | ---: | ---: | ---: |
| Chinese CER | 10 | 20 | 344 characters | 2 | **0.58%** |
| English WER | 10 | 20 | 184 words | 0 | **0.00%** |
| Chinese-English MER | 10 | 20 | 232 mixed units | 12 | **5.17%** |

Normalization: NFKC + casefold; punctuation/whitespace ignored as specified in the scorer. English words and individual Chinese characters are different units, so the three percentages must not be ranked as directly equivalent accuracy scores. Two repetitions use identical audio, not independent speakers.

**All normalized mismatches are retained**, including these examples in both repetitions:

| ID | Reference | Output |
| --- | --- | --- |
| zh09 | 我刚才说**得**有点快 | 我刚才说**的**有点快 |
| mix01 | 写进 **README** | 写进 **Redm** |
| mix05 | 轻量的 **Mac** 工具 | 轻量的 **Map** 工具 |
| mix09 | 把 **API key** 保存在 Keychain 里面 | 把 **A P I K** 保存在 Keychain 里面 |

The mixed TTS voice's pronunciation was not independently checked. These are errors against the written prompts and may include synthesis ambiguity. The set does **not** establish 100% English accuracy, human-speaker accuracy, robustness to noise, or superiority over another recognizer.

## Local artifact size

Measured separately from the ASR runner against the existing local `dist/VoxType.app`; the app was not rebuilt or reinstalled for this work.

| Item | Result |
| --- | ---: |
| Sum of logical file sizes in the app (4 files, including icon/signature) | **2,312,041 bytes / 2.21 MiB** |
| Executable | **772,064 bytes / 754 KiB** |
| Remote dependencies declared by Package.swift | **0** |

Executable SHA-256: `00c0fb8ab14ec370213c576014064692727a47c62eb332d73554cf4769116db0`.

Logical size is not filesystem allocation, a ZIP download size, runtime RSS, or a comparison against another product. This bundle was not proven to be bit-for-bit built from the ASR runner's exact source snapshot; the two measurements have separate scopes. CPU/memory goals have not been newly benchmarked here. A single running-process snapshot is not presented as a stable-idle result.

## Competitor results

| Product | Matched speed/accuracy test |
| --- | --- |
| VoxType ASR client/core | Synthetic transport/reducer results above |
| Apple Dictation | Not run |
| Wispr Flow | Not run; no installed client/account was used |
| Superwhisper | Not run; no installed client/account was used |

The README's comparison describes product positioning using linked official sources. It makes no measured “faster by X%,” “more accurate,” or “supports more languages” claim. Follow [the matched-test protocol](README.md#a-fair-future-competitor-test) before adding those claims.

## 中文摘要

真实调用豆包，30 条原创合成语音重复两次，60/60 次成功。首个文本接收 P50/P95 为 **891/1,292 毫秒**，末包后的最终响应为 **471/698 毫秒**。中文 CER **0.58%**，英文 WER **0%**，混合 MER **5.17%**；分母与单位不同，不直接横比。

这是 ASR 传输和归并的受控测试，未操作麦克风或输入框。两次使用相同音频，不代表更多说话人；英文零错误也不代表一般场景零错误。混合语音里的术语错误已经公开保留。没有实测竞品，不作性能胜出宣传。
