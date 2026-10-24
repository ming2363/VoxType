import AppKit
import os
import ServiceManagement
import SwiftUI
import VoxTypeCore

final class MenuBarController: NSObject {
    // Cache a template mark so macOS can tint it for light and dark menu bars.
    private static let logoImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            let bars: [NSRect] = [
                NSRect(x: 1, y: 8, width: 2.2, height: 4.8),
                NSRect(x: 4.4, y: 5.7, width: 2.2, height: 5.2),
                NSRect(x: 7.8, y: 3, width: 2.2, height: 4.8),
                NSRect(x: 11.2, y: 5.2, width: 2.2, height: 5.7),
                NSRect(x: 14.6, y: 6.4, width: 2.2, height: 8.4)
            ]
            for bar in bars {
                NSBezierPath(roundedRect: bar, xRadius: 1.1, yRadius: 1.1).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "VoxType"
        return image
    }()

    let model: AppModel
    private let floating: FloatingStatusController
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var settingsWindow: NSWindow?
    private let openSettingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
    private let copyItem = NSMenuItem(title: "复制最近一次结果", action: #selector(copyResult), keyEquivalent: "")
    private let statusMenuItem = NSMenuItem(title: "等待快捷键", action: nil, keyEquivalent: "")

    init(model: AppModel) {
        self.model = model
        self.floating = FloatingStatusController(model: model)
        super.init()
        if let button = statusItem.button {
            button.image = Self.logoImage
        }
        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        openSettingsItem.target = self
        copyItem.target = self
        menu.addItem(openSettingsItem)
        menu.addItem(copyItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        refresh()
    }

    func refresh() {
        statusItem.button?.title = ""
        statusItem.button?.image = Self.logoImage
        statusMenuItem.title = model.statusDetail
        copyItem.isEnabled = model.lastResultAvailable
        floating.refresh()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: host)
            window.title = "VoxType 设置"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 560, height: 680))
            window.minSize = NSSize(width: 460, height: 520)
            window.isReleasedWhenClosed = false
            window.delegate = self
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if settingsWindow?.isVisible != true {
            settingsWindow?.center()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        model.refreshPermissions(prompt: false)
        startPermissionWatch()
        Logger(subsystem: "app.voxtype.mac", category: "settings").notice("打开设置窗口")
    }

    private var permissionTimer: Timer?

    private func startPermissionWatch() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.model.refreshPermissions(prompt: false)
        }
    }

    @objc private func copyResult() {
        model.copyLastResult()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension MenuBarController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        permissionTimer?.invalidate()
        permissionTimer = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var keyDraft = ""
    @State private var keyMessage = ""
    @State private var hotkeyMessage = ""
    @State private var monitor: Any?

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("VoxType").font(.title2.bold())
                    Text(model.statusDetail).font(.callout).foregroundStyle(.secondary)
                }
            }
        Form {
            Section("API Key") {
                Text(model.hasAPIKey ? "本机钥匙串：已配置" : "本机钥匙串：未配置")
                Text("已配置只表示钥匙串里有密钥，不表示云端鉴权已通过。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField(model.hasAPIKey ? "输入新密钥以替换" : "输入 API Key", text: $keyDraft)
                HStack {
                    Button(model.hasAPIKey ? "替换" : "保存") { saveKey() }
                    Button("清除") { clearKey() }
                        .disabled(!model.hasAPIKey)
                }
                if !keyMessage.isEmpty {
                    Text(keyMessage).foregroundStyle(.secondary)
                }
                Text("资源 ID：\(model.resourceID)。语音会发到你的豆包账号，本应用不保存录音。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("快捷键") {
                Text("当前：\(model.hotkeyDescription)")
                HStack {
                    Button(model.recordingHotkey ? "取消录制" : "录制快捷键") {
                        toggleRecording()
                    }
                    Button("清除") {
                        model.saveHotkey(nil)
                        hotkeyMessage = "已清除快捷键"
                    }
                }
                if !hotkeyMessage.isEmpty {
                    Text(hotkeyMessage).foregroundStyle(.orange)
                }
                Text("按住录音，松开结束。听写键不会传给当前应用。仅修饰键和系统保留组合不能使用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("权限") {
                permissionRow("麦克风", model.microphoneGranted) { model.openPrivacy("Microphone") }
                permissionRow("辅助功能", model.accessibilityGranted) { model.requestAccessibility() }
                permissionRow("输入监控", model.listenGranted) { model.requestInputMonitoring() }
                Text("事件投递包含在辅助功能里。这两项都要打开，打开后点「退出并重新打开」才生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.accessibilityGranted || !model.listenGranted {
                    Text("辅助功能里旧开关对不上当前程序。请关掉 VoxType 再打开。输入监控列表默认没有本应用，点「加入输入监控」后才会出现。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(model.appLocation)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    HStack {
                        Button("加入输入监控") { model.requestInputMonitoring() }
                        Button("在访达中显示") { model.revealApp() }
                    }
                    Text("若列表仍没有：点下方 +，按 Command+Shift+G，粘贴上面的路径。应用在个人应用程序文件夹，不在系统“应用程序”里。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("退出并重新打开") { model.relaunch() }
                }
                Button("重新检查并请求") { model.requestMissingSystemPermissions() }
            }
            Section("登录时启动") {
                Toggle("登录 macOS 后启动", isOn: Binding(
                    get: { model.launchDesired },
                    set: { model.setLaunchEnabled($0) }
                ))
                Text(model.launchStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("打开登录项设置") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
            Section("兼容性") {
                Text("能安全修改的输入框会边说边替换当前句子。其他输入框在句末或松开后通过键盘直接输入，不占用剪贴板。若无法确认输入成功，会停止并保留最近结果；只有主动选择「复制上次结果」才会修改剪贴板。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("不会自动按回车，不会发送消息或执行命令。录音时屏幕上方只出现状态条，不用点击确认。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        }
        .padding(20)
        }
        .frame(minWidth: 460, minHeight: 520)
        .onAppear { model.refreshPermissions(prompt: false) }
        .onDisappear { stopRecording() }
    }

    private func permissionRow(_ title: String, _ granted: Bool, open: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(granted ? "已授权" : "未授权")
                .foregroundStyle(granted ? .green : .orange)
            Button("打开") { open() }
        }
    }

    private func saveKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            keyMessage = model.hasAPIKey ? "未输入新密钥，已保留原密钥" : "请输入 API Key"
            return
        }
        if model.saveAPIKey(trimmed) {
            keyDraft = ""
            keyMessage = "已写入钥匙串。这还不是云端鉴权成功。"
        } else {
            keyMessage = "保存失败"
        }
    }

    private func clearKey() {
        if model.saveAPIKey("") {
            keyDraft = ""
            keyMessage = "已从钥匙串清除"
        } else {
            keyMessage = "清除失败"
        }
    }

    private func toggleRecording() {
        if model.recordingHotkey {
            stopRecording()
            return
        }
        model.recordingHotkey = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .keyDown && event.keyCode == 53 {
                stopRecording()
                return nil
            }
            if event.type == .keyDown {
                let flags = event.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue
                let chord = HotkeyChord(keyCode: event.keyCode, modifiers: UInt64(flags))
                switch HotkeySafety.assess(chord) {
                case .usable:
                    model.saveHotkey(chord)
                    hotkeyMessage = ""
                case .rejected(let reason):
                    hotkeyMessage = reason
                }
                stopRecording()
                return nil
            }
            return event
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        model.recordingHotkey = false
    }
}
