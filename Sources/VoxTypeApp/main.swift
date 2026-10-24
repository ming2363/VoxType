import AppKit
import Foundation
import VoxTypeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    var menu: MenuBarController?
    var session: SessionController?
    var hotkey: HotkeyMonitor?
    private var cancellable: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let menu = MenuBarController(model: model)
        let session = SessionController(model: model)
        let hotkey = HotkeyMonitor()
        self.menu = menu
        self.session = session
        self.hotkey = hotkey
        session.onStatus = { _, _ in
            menu.refresh()
            hotkey.syncContext()
        }
        model.onStatusChanged = { [weak menu] in
            menu?.refresh()
        }
        hotkey.chordProvider = { [weak model] in model?.hotkey }
        hotkey.recordingProvider = { [weak model] in model?.recordingHotkey ?? false }
        hotkey.sessionActiveProvider = { [weak session] in session?.sessionActive ?? false }
        hotkey.onDown = { [weak session] isRepeat in session?.hotkeyDown(isRepeat: isRepeat) }
        hotkey.onUp = { [weak session] in session?.hotkeyUp() }
        hotkey.onUserKey = { [weak session] in session?.userTyped() }
        hotkey.onModifiers = { [weak session] mask in session?.modifiersChanged(mask) }
        hotkey.onUnavailable = { [weak model, weak menu] in
            model?.updateStatus(short: "无权限", detail: "请打开辅助功能和输入监控，然后退出并重新打开")
            menu?.refresh()
        }
        model.onPermissionsUpdated = { [weak self] in
            self?.restoreHotkeyMonitor()
        }
        hotkey.start()
        menu.refresh()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleReopen(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEReopenApplication)
        )
        if model.hotkey == nil || !model.accessibilityGranted || !model.listenGranted {
            menu.openSettings()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            if !self.model.accessibilityGranted || !self.model.listenGranted {
                self.model.requestMissingSystemPermissions()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshPermissions(prompt: false)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menu?.openSettings()
        return false
    }

    @objc func handleReopen(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        menu?.openSettings()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.stop()
    }

    private func restoreHotkeyMonitor() {
        guard model.listenGranted || model.accessibilityGranted else { return }
        if hotkey?.isRunning != true {
            hotkey?.start()
            menu?.refresh()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
