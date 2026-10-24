# Reproducible ASR benchmark / 可复现实测

The [published results](RESULTS.md) come from real paid/quota-consuming Doubao calls, using synthetic audio. They are **not** a human microphone test, an input-field test, or a competitor benchmark.

## Dataset and protocol

`corpus.json` contains 30 original fictional sentences: 10 Chinese, 10 English, 10 mixed. Two identical-audio repetitions produce 60 requests, not 60 independent speakers. There is no training split or tuning on this set. These short, clean sentences do not cover accents, background noise, numbers, long-form speech or Bluetooth capture.

`run.py` uses macOS `say`: Tingting for Chinese/mixed, Samantha for English, rate 165. It generates 16kHz, 16-bit mono PCM and appends 200ms silence. Mixed-language pronunciation by Tingting can itself be ambiguous. The transcript is scored against the written prompt; the audio was not human-reviewed. A recognition error can therefore reflect both synthesis pronunciation and ASR behavior. Generated WAV/PCM remain local; SHA-256 hashes identify the exact audio in the published rows.

`stream.swift` compiles with the **actual application `DoubaoASRClient.swift` and VoxTypeCore**. No microphone, hotkey, Accessibility insertion, UI or clipboard is exercised. Each request has a fresh connection, the actual two-pass settings, 200ms packets paced in real time, and the app's 3-second final-response timeout. The clock is monotonic.

## Metrics

| Metric | Definition |
| --- | --- |
| First text | Time from starting the synthetic PCM timeline **after handshake** to receiving the first nonempty reduced text. Includes audio availability/packetization and network/provider processing; excludes connection setup, microphone startup and field insertion. This is not a pure server-compute metric or a speech-onset measurement. |
| Final tail | Time from enqueueing the final PCM packet to receiving the final ASR result. Includes local send-queue, network/provider time; excludes typing/paste confirmation. It is not key-release-to-visible-text latency. |
| Handshake | Connection start to the first parsed server response, which the current app treats as handshake readiness. Reported separately. |
| Chinese CER | Levenshtein edits / reference characters; punctuation and whitespace removed. |
| English WER | Levenshtein edits / reference words. |
| Mixed MER | Each Chinese character is one unit; each contiguous English word/number is one unit. |

Normalization is NFKC + casefold. Latin words/numbers and Chinese characters are retained for WER/MER; punctuation separates tokens, with English internal apostrophes retained. Chinese CER retains alphanumeric characters. There is **no** synonym, numeral, abbreviation or equivalent-spelling substitution. Errors are micro-averaged by reference units across requests; failed requests count as empty output. Insertion errors can make an error rate exceed 100%, so this tool does not label `100 − error rate` as a universal accuracy score.

Latency P50/P95 use linear interpolation and successful requests with the relevant timestamp; counts are reported. No result is dropped as an outlier. This small repeated sample set does not establish population accuracy or long-tail latency.

## Run locally

Requires Python 3 standard library, Swift/clang, a matching macOS SDK, and the installed system voices. No Python packages are required. The runner may reuse an existing `.build/sdk-overlay/overlay.yaml` for the documented local toolchain mismatch; see [build limitations](../docs/BUILDING.md).

```bash
# No API usage: verify scorer and prepare local speech.
python3 benchmarks/run.py --self-test
python3 benchmarks/run.py --prepare-only

# Real API usage: start with one sample.
python3 benchmarks/run.py --limit 1 --repeats 1 --output benchmarks/local/smoke.json

# Real API usage: 30 sentences × 2, with a 600-second total-audio guard.
python3 benchmarks/run.py --output benchmarks/local/full.json

# No API usage: recalculate a published result.
python3 benchmarks/run.py --score benchmarks/results/2026-10-24-doubao-synthetic.json
```

**Running the API commands consumes your own provider quota/billing by audio usage, not LLM tokens.** The default budget guard is audio duration, not a monetary price ceiling. Confirm current provider pricing yourself. There is no automatic retry loop after auth/quota/network/handshake/server errors.

The runner reads only the VoxType Keychain item through `security`, captures the credential in memory and pipes it to the probe. It does not place it in arguments, environment variables, result files or console output. Keychain access may need your approval. It does not modify the stored key or app preferences. Never paste keys into issues or commit signing material.

## A fair future competitor test

Use the same frozen audio, machine, input field, microphone/replay route and network; record each product version, selected ASR/model/language settings and subscription tier. Randomize product order and distinguish cold setup from warm use. Run at least three repetitions per sample; keep failed requests and raw output. For live apps, measure speech-onset-to-first-visible-text and release-to-final-visible-text consistently from recordings. **Do not mix those UI metrics with this runner's transport timestamps.**

If a product only accepts a microphone, use the same physical or virtual replay path for every product and label the acoustic route. Separately evaluate clean transcripts, field-delivery correctness and resource use. One product's advertised typing-speed multiplier is not a matched ASR comparison.

## 中文说明

这里是真实豆包接口测试，不是模拟返回。30 条原创句子重复两次，共 60 次请求，使用系统合成音频，不代表真人麦克风准确率。首字统计从握手后的音频时间线开始，收尾从末包入发送队列开始，均不包含输入框最终落字。原始结果和错误保留，不剔除失败来美化数字。

评分按中文 CER、英文 WER、中英混合 MER 分开计算。当前没有竞品实测数据，不能据此宣称快于或准确于其他产品。复跑会消耗自己的语音服务额度；音频时长上限不是金额上限。
