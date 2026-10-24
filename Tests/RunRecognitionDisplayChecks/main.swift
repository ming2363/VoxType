import AppKit
import Foundation
import VoxTypeCore

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        NSApp.windows.forEach { $0.orderOut(nil) }
        exit(1)
    }
    print("PASS: \(message)")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let model = AppModel(loadPreferences: false)
let floating = FloatingStatusController(model: model)
model.onStatusChanged = { floating.refresh() }
model.updateSessionPhase(.recording)
model.updateStatus(short: "录音", detail: "模拟 ASR 纠错显示检查，无录音或联网")
var reducer = RecognitionReducer()
var writer = DictationWriteModel(route: .liveReplace)
var field = ""

func receive(_ text: String, definite: Bool, final: Bool = false) {
    let result = reducer.apply(activeSessionID: "test", eventSessionID: "test",
        utterances: [UtteranceUpdate(text: text, startTime: 0, endTime: 500, definite: definite)],
        fullText: nil, isFinalPacket: final, forcedFinalize: false)
    guard case .updated(let snapshot) = result else { fatalError("Missing update") }
    model.updateRecognition(snapshot)
    // Exercise the real write planner, without writing into another application's field.
    for op in writer.apply(snapshot: snapshot, focusValid: true).ops {
        switch op {
        case .replaceLive(let text), .replaceLastCommitted(let text): field = text
        case .insert(let text): field += text
        case .lockLive: break
        case .stop: fatalError("Unexpected stop")
        }
    }
    check(field == text && model.overlayText == text, "输入计划与悬浮框同步：\(text)")
}

receive("明天开回忆", definite: false)
receive("明天开会议。", definite: true)
model.updateSessionPhase(.finishing)
receive("明天下午开会议。", definite: true, final: true)
check(writer.finish(snapshot: reducer.snapshot, focusValid: true).ops.isEmpty, "最终纠正不重复输入")
model.updateSessionPhase(.idle)
model.updateStatus(short: "空闲", detail: "已完成")
check(model.statusShort == "已完成" && model.overlayText == field, "收尾不清空最终纠正结果")
guard let panel = app.windows.first(where: { $0 is NSPanel }) else { fatalError("Missing status panel") }
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
check(panel.isVisible && panel.alphaValue == 1, "最终结果可实际绘制，不会同一回调立即隐藏")
if CommandLine.arguments.count > 1, let view = panel.contentView,
   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
RunLoop.main.run(until: Date(timeIntervalSinceNow: 2.6))
check(!panel.isVisible, "最终结果短暂显示后自动隐藏，无需手动确认")
model.updateSessionPhase(.starting)
check(!panel.isVisible, "新会话定位焦点之前不提前弹窗")
model.updateStatus(short: "启动", detail: "模拟目标已绑定")
check(model.overlayText.isEmpty, "新会话清除上一轮结果")
model.updateSessionPhase(.idle)
model.updateStatus(short: "空闲", detail: "已取消")
check(!panel.isVisible && model.statusShort == "空闲", "没有识别文字时正常隐藏")
print("识别显示检查通过：真实归并器、输入计划、模型和浮窗；未访问麦克风、ASR、钥匙串、剪贴板或其他应用。")
