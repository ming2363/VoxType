import AppKit
import ApplicationServices

struct FocusedElementLookup {
    var element: AXUIElement?
    var error: AXError

    var failureMessage: String {
        switch error {
        case .apiDisabled: return "需要重新开启 VoxType 的辅助功能权限"
        case .cannotComplete: return "目标应用暂时未响应焦点查询，请重试"
        case .noValue: return "目标应用未返回输入焦点，请重新点击输入框后重试"
        default: return "无法读取目标应用的输入焦点（\(error.rawValue)），请重试"
        }
    }
}

struct FocusedElementReader {
    var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var read: (AXUIElement) -> (AXError, CFTypeRef?) = { source in
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(source, kAXFocusedUIElementAttribute as CFString, &value)
        return (error, value)
    }
    var requestApplicationRole: (AXUIElement) -> Void = { app in
        var role: CFTypeRef?
        // BrowserCrApplication activates native accessibility when its standard role is requested.
        _ = AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &role)
    }

    func prepareAccessibility(for pid: pid_t) {
        guard frontmostPID() == pid else { return }
        // Do this before the optional Electron-specific path: Chromium bundles can rename frameworks.
        requestApplicationRole(AXUIElementCreateApplication(pid))
        Self.enableElectronAccessibility(for: pid)
    }

    func resolve(expectedPID: pid_t? = nil) -> FocusedElementLookup {
        guard let pid = frontmostPID(), expectedPID == nil || expectedPID == pid else {
            return FocusedElementLookup(element: nil, error: .invalidUIElement)
        }
        var lastError = AXError.noValue
        // Some Electron applications expose focus on the application before the system root does.
        for source in [AXUIElementCreateSystemWide(), AXUIElementCreateApplication(pid)] {
            let (error, value) = read(source)
            lastError = error
            guard error == .success, let value else { continue }
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                lastError = .illegalArgument
                continue
            }
            let element = unsafeBitCast(value, to: AXUIElement.self)
            var owner: pid_t = 0
            guard frontmostPID() == pid else {
                return FocusedElementLookup(element: nil, error: .invalidUIElement)
            }
            guard AXUIElementGetPid(element, &owner) == .success, owner == pid else {
                lastError = .invalidUIElement
                continue
            }
            return FocusedElementLookup(element: element, error: .success)
        }
        return FocusedElementLookup(element: nil, error: lastError == .success ? .noValue : lastError)
    }

    static func enableElectronAccessibility(for pid: pid_t) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let url = NSRunningApplication(processIdentifier: pid)?.bundleURL,
              let frameworks = Bundle(url: url)?.privateFrameworksURL,
              FileManager.default.fileExists(atPath: frameworks.appendingPathComponent("Electron Framework.framework").path) else { return }
        let app = AXUIElementCreateApplication(pid)
        // Electron's documented opt-in: only on a failed startup probe, never in an idle timer.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}
