# Getting started / 使用说明

需要 Apple 芯片 Mac、macOS 15+、网络，以及已开通的火山引擎豆包流式语音识别 2.0 账号。安装方式见 [构建说明](BUILDING.md)。

## 配置

1. 启动 `~/Applications/VoxType.app`，从菜单栏 V 形图标选择「设置…」。应用已运行时再次打开它，也会显示设置窗口。
2. 到 [火山引擎控制台](https://console.volcengine.com/) 的豆包语音开通管理，确认开通的是「流式语音识别 2.0」，创建对应 API Key，在设置页保存。参考 [官方双向流式接口文档](https://docs.volcengine.com/docs/DoubaoVoice/bidirectional-streaming-automatic-speech-recognition-websocket?lang=zh)。
3. 当前实现固定使用 `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async` 和时长资源 `volc.seedasr.sauc.duration`。开通服务不等于所有 Key 都有对应资源权限；鉴权与额度以你的账号为准。
4. 在系统设置中允许麦克风、辅助功能和输入监控。若列表没有应用，使用设置页对应按钮加入；授权后仍无效时退出再打开。
5. 录制听写快捷键。不能只用修饰键，也不能使用应用拒绝的系统保留组合。
6. 把光标放进普通输入框，按住快捷键说话，松开结束。工具不会自动按回车。

设置页的保存状态只表示本机已保存 Key，不代表服务商已验证可用。空白密钥输入框不会通过普通保存覆盖旧 Key；删除时使用清除操作。

## 输入行为

- 能安全修改范围时，替换当前未定稿文字，句末用 ASR 定稿纠正；其他情况自动在句末或松开后输入。
- 手动输入、移动光标或切换焦点可能使本次写入停止，避免修改错误位置。
- 带修饰键的快捷键可能使模拟输入等待修饰键完全松开。
- 听写直接写入焦点输入框；辅助功能不能直接写入时，使用 Unicode 键盘事件，不读写剪贴板。无法确认输入成功时停止，避免重复插入。「复制上次结果」仍是用户主动操作，会覆盖剪贴板。
- 不支持密码框。当前版本清理换行为空格，避免通过换行发送消息或执行命令。

如果 Codex 等 Chromium/Electron 应用已显示文字光标，却提示无法读取焦点，VoxType 会尝试应用级焦点查询；必要时通过标准的应用角色查询请求辅助功能支持，再对普通 Electron 包补充其专用请求，并最多短暂重试 3 次。标准请求不依赖框架文件名，适用于使用定制框架名的客户端。松开快捷键或切换应用会取消等待；仍失败时，请重新点击输入框再试。此兼容处理不使用剪贴板，也不会绕过密码框限制。

## 登录启动

设置页可开启，按系统提示批准登录项。构建脚本安装到 `~/Applications/VoxType.app`，移动应用后需要重新检查登录项与权限。

## English quick setup

Build the app, open Settings from the menu bar, save a valid Doubao Streaming ASR 2.0 key, record a shortcut, and grant Microphone, Accessibility and Input Monitoring permissions. Focus an ordinary field, hold the shortcut, speak, and release. Some settings labels are currently Chinese.

Streaming edits depend on accessibility support; otherwise finalized text is inserted with direct Unicode keyboard events. Changing focus, moving the caret or typing can stop insertion. Automatic dictation never reads or writes the clipboard; only the explicit Copy Last Result action does. If delivery cannot be confirmed, it stops rather than retrying with paste. Login startup is optional; password fields are excluded, and the app never presses Enter to submit text.
