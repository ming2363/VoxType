import AppKit
import Foundation
import VoxTypeCore

// A display-only model: this executable never opens a microphone, ASR session or Keychain.
final class AppModel {
    var statusShort = "连接提示"
    var statusDetail = "悬浮框显示测试（未录音、不调用 ASR）"
    var sessionPhase: SessionPhase = .recording
    var overlayText = ""
    var focusRect: CGRect?
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        NSApp.windows.forEach { $0.orderOut(nil) }
        exit(1)
    }
    print("PASS: \(message)")
}

func advance(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let model = AppModel()
let floating = FloatingStatusController(model: model)
floating.refresh()
guard let panel = app.windows.first(where: { $0 is NSPanel }) else { fatalError("Missing status panel") }
let originalKeyWindow = app.keyWindow

advance(2.7)
check(panel.isVisible && panel.alphaValue == 1, "录音中即使状态文案不是录音，超过 2.4 秒仍可见")
model.statusShort = "已停止"
floating.refresh()
check(panel.isVisible, "只停止文字写入时，不隐藏仍在录音的状态条")
model.sessionPhase = .starting
model.statusShort = "空闲"
floating.refresh()
check(panel.isVisible, "启动阶段覆盖旧的空闲提示")
model.sessionPhase = .finishing
floating.refresh()
check(panel.isVisible, "收尾阶段持续可见")
model.sessionPhase = .idle
floating.refresh()
check(!panel.isVisible, "空闲后立即隐藏")

model.statusShort = "无法输入"
floating.refresh()
advance(0.1)
model.sessionPhase = .recording
floating.refresh()
advance(2.7)
check(panel.isVisible && panel.alphaValue == 1, "旧提示的延迟隐藏不会关闭新录音的状态条")

model.sessionPhase = .idle
model.statusShort = "确认输入"
floating.refresh()
advance(2.7)
check(panel.isVisible, "本地投递确认期间持续可见")
model.statusShort = "等待松开"
floating.refresh()
check(panel.isVisible, "等待修饰键松开时持续可见")
model.statusShort = "无法输入"
floating.refresh()
advance(2.7)
check(!panel.isVisible, "真正空闲的临时提示仍会自动隐藏")

model.sessionPhase = .recording
floating.refresh()
advance(0.2)
check(panel.isVisible && panel.alphaValue == 1, "隐藏后立即开始录音，不会被旧淡出动画变透明")
check(!panel.canBecomeKey && !panel.canBecomeMain && app.keyWindow === originalKeyWindow, "状态条不抢键盘焦点")
model.sessionPhase = .idle
model.statusShort = "空闲"
floating.refresh()
check(!panel.isVisible, "结束后关闭显示并停止显示计时器")
print("悬浮框检查通过（仅显示测试，无录音或网络请求）")
