import AppKit
import ApplicationServices

// Exercise real resolution logic with injected AX replies, without inspecting another app.
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    checks += 1
    print("PASS: \(message)")
}

let pid: pid_t = 71001
let field = AXUIElementCreateApplication(pid)
let otherField = AXUIElementCreateApplication(pid + 1)

var reads = 0
let native = FocusedElementReader(frontmostPID: { pid }, read: { _ in
    reads += 1
    return (.success, field)
})
check(native.resolve().element.map { CFEqual($0, field) } == true, "正常系统焦点直接返回")
check(reads == 1, "正常应用不增加焦点查询")

for error in [AXError.cannotComplete, .noValue, .attributeUnsupported] {
    reads = 0
    let fallback = FocusedElementReader(frontmostPID: { pid }, read: { source in
        reads += 1
        var sourcePID: pid_t = 0
        AXUIElementGetPid(source, &sourcePID)
        return sourcePID == pid ? (.success, field) : (error, nil)
    })
    check(fallback.resolve(expectedPID: pid).element.map { CFEqual($0, field) } == true,
          "系统查询失败 \(error.rawValue) 后从当前应用读取焦点")
    check(reads == 2, "失败后只增加一次应用查询")
}

reads = 0
let failed = FocusedElementReader(frontmostPID: { pid }, read: { _ in
    reads += 1
    return (.cannotComplete, nil)
})
let failure = failed.resolve()
check(failure.element == nil && failure.error == .cannotComplete, "保留查询失败原因")
check(failure.failureMessage.contains("未响应"), "查询错误不会误报没有输入框")
check(reads == 2, "一次解析的查询次数有上限")

reads = 0
let missingValue = FocusedElementReader(frontmostPID: { pid }, read: { _ in (.success, nil) })
check(missingValue.resolve().error == .noValue, "空值不能作为成功结果")
let invalidValue = FocusedElementReader(frontmostPID: { pid }, read: { _ in (.success, "text" as CFString) })
check(invalidValue.resolve().element == nil, "非 AX 对象被拒绝，避免强制类型转换崩溃")

let wrongApp = FocusedElementReader(frontmostPID: { pid }, read: { _ in (.success, otherField) })
check(wrongApp.resolve().element == nil, "不接受其他应用的焦点")
reads = 0
let staleSystem = FocusedElementReader(frontmostPID: { pid }, read: { _ in
    reads += 1
    return (.success, reads == 1 ? otherField : field)
})
check(staleSystem.resolve().element.map { CFEqual($0, field) } == true, "系统返回旧应用时仍尝试当前应用")

reads = 0
let changedApp = FocusedElementReader(frontmostPID: { pid + 1 }, read: { _ in
    reads += 1
    return (.success, field)
})
check(changedApp.resolve(expectedPID: pid).element == nil && reads == 0, "重试前切换应用立即拒绝")
var foregroundReads = 0
let changedDuringQuery = FocusedElementReader(frontmostPID: {
    foregroundReads += 1
    return foregroundReads == 1 ? pid : pid + 1
}, read: { _ in (.success, field) })
check(changedDuringQuery.resolve().element == nil, "查询期间切换应用不返回旧焦点")
let noApp = FocusedElementReader(frontmostPID: { nil }, read: { _ in
    fatalError("不应查询没有目标的输入框")
})
check(noApp.resolve().element == nil, "没有前台应用时安全退出")

var roleRequested = false
var roleRequests = 0
let chromium = FocusedElementReader(frontmostPID: { pid }, read: { _ in
    roleRequested ? (.success, field) : (.noValue, nil)
}, requestApplicationRole: { app in
    var owner: pid_t = 0
    AXUIElementGetPid(app, &owner)
    check(owner == pid, "标准角色请求只发给当前目标应用")
    roleRequests += 1
    roleRequested = true
})
check(chromium.resolve().element == nil, "复现未请求应用角色时 Chromium 不返回焦点")
check(roleRequests == 0, "普通焦点查询不反复请求辅助功能初始化")
chromium.prepareAccessibility(for: pid)
check(roleRequests == 1, "不依赖 Electron 框架名称也请求标准应用角色")
check(chromium.resolve(expectedPID: pid).element.map { CFEqual($0, field) } == true,
      "标准角色请求后可解析当前输入焦点")
chromium.prepareAccessibility(for: pid + 1)
check(roleRequests == 1, "不初始化非前台应用的辅助功能")
print("焦点检查通过：\(checks) 项；无界面输入、录音、网络或剪贴板访问。")
