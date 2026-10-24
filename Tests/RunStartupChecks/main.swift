import Foundation
import VoxTypeCore

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
    print("PASS: \(message)")
}

// Real SessionGate + AppModel, with the same synchronous bridge as SessionController.
// Skip preference loading so this test never reads Keychain, permissions or user settings.
final class StartupHarness {
    let model = AppModel(loadPreferences: false)
    var gate = SessionGate() {
        didSet { model.updateSessionPhase(gate.phase) }
    }
    var events: [String] = []

    init() {
        model.onStatusChanged = { [weak self] in
            self?.events.append("refresh")
        }
    }

    func bindTarget() {
        events.append("focus-bound")
        model.updateStatus(short: "启动", detail: "输入框已绑定，开始录音")
    }
}

let startup = StartupHarness()
check(startup.gate.keyDown(isRepeat: false) == .beginSession, "快捷键进入启动阶段")
check(startup.model.sessionPhase == .starting, "启动状态仍立即同步")
check(startup.events.isEmpty, "焦点探测前不触发悬浮框刷新")
startup.bindTarget()
check(startup.events == ["focus-bound", "refresh"], "先绑定输入框，再显示启动状态")
check(startup.gate.micReady() == .enterRecording, "正常进入录音")
check(startup.events.count == 3 && startup.model.sessionPhase == .recording, "录音状态仍立即刷新并保持可见")
check(startup.gate.keyUp() == .beginFinish, "松开后进入收尾")
check(startup.events.count == 4 && startup.model.sessionPhase == .finishing, "收尾状态仍立即刷新")
startup.gate.finished()
check(startup.events.count == 5 && startup.model.sessionPhase == .idle, "结束状态仍立即刷新")

let cancelled = StartupHarness()
_ = cancelled.gate.keyDown(isRepeat: false)
cancelled.gate.finished()
check(cancelled.events.count == 1 && cancelled.model.sessionPhase == .idle, "探测期间取消不会显示启动状态")

let retry = StartupHarness()
_ = retry.gate.keyDown(isRepeat: false)
retry.model.updateSessionPhase(.starting)
retry.model.updateSessionPhase(.starting)
check(retry.events.isEmpty, "重复同步启动状态不会提前显示悬浮框")
retry.model.updateStatus(short: "无法输入", detail: "测试错误")
check(retry.events.count == 1, "明确的状态消息仍可刷新")
print("启动时序检查通过：无录音、网络、钥匙串、剪贴板或其他应用界面访问。")
