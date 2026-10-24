<p align="center">
  <img src="Resources/Branding/AppIcon.png" alt="VoxType logo" width="120">
</p>
<h1 align="center">VoxType</h1>
<p align="center">
  <strong>Own your Mac dictation: native Swift, your ASR key, speech directly at the cursor.</strong>
</p>
<p align="center">Hold a shortcut. Speak Chinese, English, or both. Keep writing where you already work.</p>
<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-111827" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Apple_Silicon-arm64-007AFF" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-native-F05138" alt="Native Swift">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-2563EB" alt="Apache 2.0"></a>
</p>
<p align="center">
  English · <a href="README.zh-CN.md">简体中文</a><br>
  <a href="#why-voxtype">Why VoxType</a> · <a href="#how-it-compares">Comparison</a> · <a href="#measured-not-guessed">Measurements</a> · <a href="docs/GETTING_STARTED.md">Get started</a>
</p>

| First text · ASR P50 | Final tail · ASR P50 | Local app file contents |
| :---: | :---: | :---: |
| **0.89 s** | **0.47 s** | **2.21 MiB** |

<sub>30 synthetic sentences × 2, real API calls. Transport timing, not microphone-to-field latency. [Methods and full results](benchmarks/RESULTS.md).</sub>

## Why VoxType

VoxType is a focused, open-source dictation utility for people who want to type less on a Mac. It lives in the menu bar and sends microphone audio directly to **Doubao Streaming ASR 2.0** under your own Volcengine account. Text goes into the focused field, so you can keep working in your editor, chat, document, or browser.

Its strengths are **a small native client, an inspectable input pipeline, and control over your own ASR connection**. You do not need a VoxType account, a separate backend, or a local model download. The app concentrates on getting your words into the field with ASR sentence-final correction and no additional LLM rewriting call.

| Designed for everyday dictation | What that means |
| --- | --- |
| **Speak directly into your workflow** | Hold your chosen shortcut to speak, release to finish. No confirmation step or manual transcript copying. |
| **Streaming with sentence-final correction** | Safely editable fields show live text; final ASR results correct the current sentence in place. Other fields fall back to automatic sentence-final or release-time insertion. |
| **A small native implementation** | Swift, AppKit and SwiftUI; no Electron, WebView, helper server or bundled inference model. |
| **Your service connection** | Bring your own API key. The app connects to the ASR provider without a VoxType relay; provider usage charges still apply. |
| **Chinese and English in one workflow** | Chinese, English and mixed-language dictation through the current ASR integration. |
| **Careful text delivery** | Guards against focus/caret changes and manual edits. Password fields are excluded; text is never automatically sent or executed with Enter. |
| **A native Mac utility** | Menu-bar controls, configurable shortcut, Keychain credentials, permission settings, login startup, and a nonactivating recording/status indicator. |

Streaming insertion depends on the target application's accessibility support. Compatibility is a goal, not a promise that every text field is supported.

## How it compares

VoxType's distinction is its **open, focused, native implementation with a direct BYOK ASR connection**. Choose it when that control matters more than broad writing-assistant features.

| Product | Main emphasis | Where VoxType differs |
| --- | --- | --- |
| **VoxType** | Open-source Mac dictation; direct Doubao ASR; live/final text delivery | Inspect and modify the client, use your own ASR account, and avoid a separate rewriting stage. |
| **[Apple Dictation](https://support.apple.com/guide/mac-help/use-dictation-mh40584/mac)** | Built-in dictation, configurable shortcut and supported-language punctuation | VoxType provides a modifiable client and an explicit Doubao ASR connection. Apple Dictation needs no separate app installation. |
| **[Wispr Flow](https://wisprflow.ai/)** | Cross-platform dictation with polished writing, vocabulary and formatting features | VoxType focuses on ASR text delivery with no extra LLM rewriting call. Flow advertises 100+ languages; VoxType currently focuses on Chinese and English. |
| **[Superwhisper](https://superwhisper.com/)** | Offline recognition, custom modes and selectable models | VoxType ships without local models and has a narrower configuration surface. Superwhisper offers offline use and advertises 100+ languages and dialects. |

Descriptions were checked against the linked official pages on **2026-10-24**. This is a positioning comparison, not a head-to-head speed or accuracy benchmark. **VoxType currently needs the network; offline recognition is an advantage of alternatives that support it.**

## Measured, not guessed

Original Chinese, English and mixed-language sentences, a reproducible runner, and raw per-request results are included. The test uses the application's actual ASR client and recognition reducer. See [the benchmark](benchmarks/README.md) for exact methods and limitations.

<!-- BENCHMARK_SUMMARY_EN -->
| Controlled ASR measurement | Result |
| --- | ---: |
| **First text received, P50 / P95** | **891 / 1,292 ms** |
| **Final response tail, P50 / P95** | **471 / 698 ms** |
| Successful requests | 60 / 60 |
| Chinese CER / English WER / mixed MER | 0.58% / 0.00% / 5.17% |

30 original sentences × 2; macOS synthetic voices; real Doubao calls on 2026-10-24. **These are ASR transport/reducer results, not microphone-to-field latency, human-speech accuracy, or a competitor comparison.** Connection setup is measured separately. [Raw results and limitations](benchmarks/RESULTS.md).
<!-- /BENCHMARK_SUMMARY_EN -->

The inspected local `.app` contains **2.21 MiB of file contents**, including its icon and signature; the executable is **754 KiB**. The Swift package declares **0 remote package dependencies**. These are local artifact/source measurements, not comparative CPU or memory claims. See [measurement details](benchmarks/RESULTS.md).

## A short path to speaking

You need **an Apple Silicon Mac running macOS 15+**, a network connection, and your own enabled **Volcengine Doubao Streaming ASR 2.0** account/key.

1. Build/install the native app using [the build guide](docs/BUILDING.md).
2. Open Settings from the menu bar; save your API key and choose a shortcut.
3. Grant Microphone, Accessibility and Input Monitoring permissions.
4. Focus a text field, hold the shortcut and speak. Release to finish; edit the inserted text normally.

The repository currently documents a **local build**, not a notarized public installer. Full setup and fallback behavior are in [Getting started](docs/GETTING_STARTED.md).

## Privacy and boundaries

- Your key is stored in **macOS Keychain**, not a project configuration file.
- Audio is sent to **Volcengine/ByteDance's ASR endpoint** while dictating. This is cloud recognition; provider terms and retention policies apply.
- No recording archive or transcript-history database is implemented. The latest result remains in memory for an explicit “copy last result” action.
- Accessibility APIs inspect the focused field to deliver and verify text. A fallback may temporarily use the clipboard. The recording indicator can display recognized text on screen.
- The idle code path does not start microphone capture or an ASR session. No separate analytics integration exists in the inspected source.

Read [the data-flow and permission notes](docs/PRIVACY.md). Real microphone conditions, accents, Bluetooth devices and application compatibility need broader testing than a controlled ASR sample set.

## Inside the project

`VoxTypeApp` handles the menu bar, settings, microphone, shortcuts and guarded text insertion. `VoxTypeCore` contains the streaming protocol, recognition reducer and delivery/session policies. A small C wrapper uses system zlib for gzip; no model weights are bundled.

Contributions improving text-delivery reliability, real-world bilingual evaluation and reproducible builds are welcome. Include the environment and a minimal reproduction; keep credentials and private transcripts out of issues.

## License

**[Apache License 2.0](LICENSE)**. See [NOTICE](NOTICE) for attribution and [third-party notes](docs/THIRD_PARTY.md) for scope. The license covers this project's original work; ASR service access remains subject to provider terms and fees.
