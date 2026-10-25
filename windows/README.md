# VoxType for Windows · 实验预览版

独立的 Windows 原生客户端，目标为 **Windows 10／11、Intel／AMD x64**。使用 C#、.NET 10 和 WinForms；通过系统 UI Automation 定位输入框，使用 Unicode 键盘事件投递文字。

**此版本尚未在 Windows 实机或虚拟机运行验证。** 核心协议、纠错和本地 WebSocket 测试，以及 macOS 上的 Windows 目标交叉编译，不等于录音、快捷键、凭据和输入兼容性已得到实测确认。先作为预览版试用，不宣称覆盖所有输入框。

本次检查和边界说明见 [复核记录](VERIFICATION.md)。

## 与 Mac 版隔离

所有 Windows 源码、构建配置、图标和产物均放在本目录。现有 Swift 源码、Package.swift、Mac 构建脚本、签名材料、设置与钥匙串不参与 Windows 构建。Windows 的 SDK、运行时和配置不会被打包进 Mac 应用。

## 初版行为

- 按住自定义快捷键录音，悬浮条实时显示中英文识别结果；松开后等待 ASR 句末二遍识别，再将最终文字一次投递到原输入框。尚未实现 Mac 版的实时原位替换。
- 不自动使用剪贴板，不自动按 Enter，不发送消息或执行命令。只有用户选择托盘菜单「复制最近一次结果」才修改剪贴板。
- 切换应用、移动光标、修改原文字或手动键入时停止自动投递。密码框、只读框、无法确认位置的输入框会被拒绝。
- `SendInput` 成功表示系统接受键盘事件，不保证目标应用已经处理文字；部分或失败投递不会重试。管理员权限应用受 Windows 权限隔离限制，应用本身默认以普通权限运行。
- API Key 保存在当前 Windows 用户的凭据管理器；`settings.json` 仅保存快捷键和匿名请求 ID。没有录音归档和转写历史数据库，最近结果只保留在进程内存。
- 登录启动由设置页选择，写入当前用户的启动项；空闲时没有录音、ASR 连接或低级键盘钩子。仅全局快捷键注册持续有效。

## 使用便携包

解压 `VoxType-windows-x64-preview.zip`，运行 `VoxType.exe`。包内携带 .NET 运行时，无需另装 .NET。保留同目录 README、LICENSE、NOTICE。

1. 从托盘打开设置，填写自己的 **火山引擎豆包流式语音识别 2.0 API Key** 并保存。
2. 录制并保存快捷键。没有默认抢占任何键位；例如可尝试 `Ctrl+Alt+空格`，注册失败表示已被占用。`Alt+空格`、`Ctrl+空格` 等系统常用组合会被拒绝。
3. 在 Windows 隐私设置中允许桌面应用使用麦克风，并检查默认麦克风。初版请求 16kHz、16bit、单声道 PCM；不支持的设备会提示失败。
4. 在普通输入框中按住快捷键说话，松开全部组合键，等待最终结果自动投递。
5. 如需开机登录后运行，勾选「登录 Windows 时自动启动」并保存。移动便携目录后应重新保存启动设置。

客户端免费，ASR 仍使用你自己的账号额度或付费资源。接口固定为 `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`，资源 ID 为 `volc.seedasr.sauc.duration`。不会读取 Mac 上的 API Key。

初版没有公开可信签名，也未做 SmartScreen 信任验证；按 Windows 的实际安全提示处理，不要关闭系统防护。仓库提供源代码和构建方式，是否发布二进制 Release 由维护者另行决定。

## 构建和检查

开发机安装 [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)。SDK 仅用于开发，便携包的使用者无需安装它。

```powershell
cd windows
./build.ps1
```

也可以手动运行：

```powershell
dotnet run --project VoxType.Core.Checks -c Release
dotnet publish VoxType.Windows -c Release -r win-x64 --self-contained true -o artifacts/publish
```

产物位于 `artifacts/`，不会进入源码提交。`EnableWindowsTargeting` 允许在 macOS/Linux 下载 Windows 引用程序集并编译，Windows 用户界面与系统接口仍需在 Windows 上执行测试。

核心检查使用自己构造的语音响应和本机回环 WebSocket，不调用豆包、不消耗账号额度、不读取真实凭据，也不访问麦克风或剪贴板。它验证协议头、gzip、最后一包、纠错归并、过期结果、音频缓冲顺序、快捷键策略、x64 结构布局和连接结束/错误清理。

## Windows 待验证项目

- 首次启动、托盘设置、快捷键冲突与按住/松开行为。
- 默认麦克风、蓝牙麦克风、设备中途断开、拒绝麦克风权限。
- Key 保存、替换、删除，退出重开后的设置和登录启动。
- 记事本、浏览器、微信、Office、VS Code/Codex 的中英文和 emoji 输入。
- 选区替换、说话中移动光标、手动编辑、切换窗口、密码框与管理员应用。
- 网络断开、密钥错误、额度不足、录音超过缓冲上限、退出时资源释放。
- 空闲/录音时 CPU、内存、首字和最终投递延迟。没有实测之前不公布 Windows 性能数字，也不将 Mac 的测试数字当作 Windows 成绩。

## Sources / English

This is an **untested-on-Windows preview**, not a parity claim with the Mac client. It displays live ASR text and inserts the final corrected text on release. All Windows work is isolated in this directory. A self-contained x64 package includes the runtime. Native integration and end-to-end dictation still require Windows testing.

Platform references: [UI Automation text insertion](https://learn.microsoft.com/dotnet/framework/ui-automation/add-content-to-a-text-box-using-ui-automation), [SendInput and privilege boundaries](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-sendinput), [waveInOpen](https://learn.microsoft.com/windows/win32/api/mmeapi/nf-mmeapi-waveinopen), [RegisterHotKey](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-registerhotkey), [cross-targeting Windows](https://learn.microsoft.com/dotnet/core/tools/sdk-errors/netsdk1100).

Project code uses the root Apache-2.0 license. The portable package also includes Microsoft .NET runtime components; their upstream license/notice files must remain in the package.
