# Privacy and data flow / 隐私与数据流

This describes the inspected implementation, not a provider privacy guarantee.

| Data | Local handling | Network handling |
| --- | --- | --- |
| API key | Keychain service `app.voxtype.mac`, account `doubao-api-key`; process memory during recognition | Authentication header to the Doubao endpoint |
| Microphone audio | Captured while dictating, converted to 16kHz/16-bit mono PCM; in-memory buffers | Secure WebSocket to `openspeech.bytedance.com` |
| Recognition text | In memory, focused-field insertion, possible status-indicator display | Returned by the provider; no separate rewriting service called |
| Latest result | Memory for explicit copy action; no history database | No separate transcript archive upload implemented |
| Focused text and selection | Accessibility inspection to constrain and confirm insertion | Not included as text context by the current ASR request builder |
| Anonymous ID | Random UUID stored in UserDefaults, not a hardware serial number | Included as `user.uid`; stable per local preference profile |
| Shortcut/startup preference | UserDefaults/system login settings | Not in ASR requests |

No audio-file archive, transcript-history database or separate analytics integration is implemented. The idle path does not start microphone capture or an ASR session. These are source observations, not a complete network or operating-system audit.

Microphone permission enables capture. Input Monitoring observes the shortcut. Accessibility/event posting supports focused-field inspection and text delivery. Clipboard fallback temporarily exposes the transcript to clipboard managers; an explicit copy action replaces clipboard contents normally. The on-screen status indicator may display recognized words.

The app excludes password fields and does not press Enter to submit text. Focus, caret and manual-edit guards reduce unintended changes, but every application and field cannot be guaranteed compatible.

“Direct to ASR” does **not** mean offline or zero retention. Consult your provider's contract, region, retention policy and pricing. Apache-2.0 grants no rights to use that service.

## 中文说明

密钥进入系统钥匙串，听写音频会发给火山引擎／豆包，不是本地离线识别。应用没有录音归档、转写历史数据库或独立统计分析接入；最近结果保留在内存，状态提示可能显示识别文字。

为了安全写入，会读取焦点输入框和选区，当前请求构造器不会把这些文字作为上下文上传。ASR 请求携带随机生成并持久保存的匿名 UUID，不是电脑序列号。粘贴回退和主动复制会使用剪贴板，剪贴板管理工具可能保留这些内容。服务商的数据处理与保留政策需要另行查看。
