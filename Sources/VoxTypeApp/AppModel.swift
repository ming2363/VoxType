import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation
import Security
import ServiceManagement
import VoxTypeCore

final class AppModel: ObservableObject {
    static let bundleID = "app.voxtype.mac"
    static let keychainService = "app.voxtype.mac"
    static let keychainAccount = "doubao-api-key"
    static let syntheticMarker: Int64 = 0x564F5854

    @Published var statusShort = "空闲"
    @Published var statusDetail = "等待快捷键"
    @Published private(set) var sessionPhase: SessionPhase = .idle
    @Published var hasAPIKey = false
    @Published var hotkey: HotkeyChord?
    @Published var recordingHotkey = false
    @Published var launchDesired = false
    @Published var launchStatusText = "未开启"
    @Published var microphoneGranted = false
    @Published var accessibilityGranted = false
    @Published var listenGranted = false
    @Published var postGranted = false
    @Published var lastResultAvailable = false
    var overlayText = ""
    var focusRect: CGRect?

    let resourceID = DoubaoEndpoint.resourceDuration
    var onPermissionsUpdated: (() -> Void)?
    var onStatusChanged: (() -> Void)?
    private let defaults = UserDefaults.standard
    private var lastResult = ""

    init(loadPreferences: Bool = true) {
        if loadPreferences { load() }
    }

    var uid: String {
        if let saved = defaults.string(forKey: "anonymousUID"), !saved.isEmpty {
            return saved
        }
        let created = "voxtype-" + UUID().uuidString
        defaults.set(created, forKey: "anonymousUID")
        return created
    }

    var hotkeyDescription: String {
        guard let hotkey, hotkey.isConfigured else { return "未设置" }
        return Self.describe(hotkey)
    }

    func load() {
        hasAPIKey = apiKey() != nil
        if let data = defaults.data(forKey: "hotkey"),
           let chord = try? JSONDecoder().decode(HotkeyChord.self, from: data),
           chord.isConfigured {
            hotkey = chord
        }
        launchDesired = defaults.bool(forKey: "launchDesired")
        refreshPermissions(prompt: false)
        refreshLaunchStatus()
    }

    func apiKey() -> String? {
        keychain.stored
    }

    func saveAPIKey(_ raw: String) -> Bool {
        let ok = CredentialEditor.save(raw, in: keychain, notFound: errSecItemNotFound)
        hasAPIKey = keychain.stored != nil
        return ok
    }

    private var keychain: CredentialKeychain = SecCredentialKeychain()

    func saveHotkey(_ chord: HotkeyChord?) {
        hotkey = chord
        if let chord, chord.isConfigured, let data = try? JSONEncoder().encode(chord) {
            defaults.set(data, forKey: "hotkey")
        } else {
            defaults.removeObject(forKey: "hotkey")
            hotkey = nil
        }
    }

    func remember(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastResult = trimmed
        lastResultAvailable = true
    }

    func copyLastResult() {
        guard !lastResult.isEmpty else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(lastResult, forType: .string)
    }

    func refreshPermissions(prompt: Bool) {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneGranted = mic == .authorized
        if prompt && mic == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.microphoneGranted = granted
                    self?.onPermissionsUpdated?()
                }
            }
        }
        if prompt && !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [key: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        accessibilityGranted = AXIsProcessTrusted()
        listenGranted = CGPreflightListenEventAccess()
        // 投递事件走辅助功能。单独预检在已授权时仍可能返回否。
        postGranted = accessibilityGranted || CGPreflightPostEventAccess()
        if prompt && !listenGranted {
            CGRequestListenEventAccess()
        }
        onPermissionsUpdated?()
    }

    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.8 && /usr/bin/open \"$1\"", "sh", path]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            updateStatus(short: "未重启", detail: "请从菜单退出后重新打开")
        }
    }

    var appLocation: String {
        Bundle.main.bundlePath
    }

    func requestMissingSystemPermissions() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            accessibilityGranted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        if !CGPreflightListenEventAccess() {
            listenGranted = CGRequestListenEventAccess()
        } else {
            listenGranted = true
        }
        postGranted = accessibilityGranted || CGPreflightPostEventAccess()
        onPermissionsUpdated?()
    }

    func requestAccessibility() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            accessibilityGranted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshPermissions(prompt: false)
            self?.openPrivacy("Accessibility")
        }
    }

    func requestInputMonitoring() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        listenGranted = CGPreflightListenEventAccess() || CGRequestListenEventAccess()
        onPermissionsUpdated?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshPermissions(prompt: false)
            self?.openPrivacy("ListenEvent")
        }
    }

    func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func openPrivacy(_ pane: String) {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_\(pane)",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)"
        ]
        for text in urls {
            if let url = URL(string: text) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    func setLaunchEnabled(_ enabled: Bool) {
        launchDesired = enabled
        defaults.set(enabled, forKey: "launchDesired")
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchStatusText = "注册失败"
        }
        refreshLaunchStatus()
    }

    func refreshLaunchStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchStatusText = "已开启"
        case .requiresApproval:
            launchStatusText = "需要在系统设置中允许"
        case .notRegistered:
            launchStatusText = "未开启"
        case .notFound:
            launchStatusText = "未找到，请从应用程序文件夹启动"
        @unknown default:
            launchStatusText = "状态未知"
        }
    }

    func updateSessionPhase(_ phase: SessionPhase) {
        guard sessionPhase != phase else { return }
        sessionPhase = phase
        // Showing the panel before the startup focus probe can disturb the target's AX focus.
        // startSession publishes its first status after binding the input field.
        guard phase != .starting else { return }
        onStatusChanged?()
    }

    func updateStatus(short: String, detail: String) {
        // Let the final correction paint before the existing transient indicator dismisses it.
        statusShort = short == "空闲" && !overlayText.isEmpty ? "已完成" : short
        statusDetail = detail
        if short == "启动" {
            overlayText = ""
        }
        onStatusChanged?()
    }

    func updateRecognition(_ snapshot: RecognitionSnapshot) {
        remember(snapshot.displayText)
        updateOverlay(snapshot.displayText)
    }

    func updateOverlay(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != overlayText else { return }
        overlayText = trimmed
        onStatusChanged?()
    }

    static func describe(_ chord: HotkeyChord) -> String {
        var parts: [String] = []
        let mods = chord.modifiers & HotkeyMatcher.relevantMask
        if mods & 0x40000 != 0 { parts.append("⌃") }
        if mods & 0x80000 != 0 { parts.append("⌥") }
        if mods & 0x20000 != 0 { parts.append("⇧") }
        if mods & 0x100000 != 0 { parts.append("⌘") }
        if let keyCode = chord.keyCode {
            parts.append(keyName(keyCode))
        } else if parts.isEmpty {
            return "未设置"
        }
        return parts.joined()
    }

    private static func keyName(_ code: UInt16) -> String {
        let names: [UInt16: String] = [
            49: "空格", 36: "回车", 48: "Tab", 51: "删除", 53: "Esc",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            123: "左", 124: "右", 125: "下", 126: "上"
        ]
        if let name = names[code] { return name }
        let letters: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
            24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]",
            31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'",
            40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
            50: "`"
        ]
        return letters[code] ?? "键码\(code)"
    }
}

private final class SecCredentialKeychain: CredentialKeychain {
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppModel.keychainService,
            kSecAttrAccount as String: AppModel.keychainAccount
        ]
    }

    var stored: String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func update(_ value: String) -> Int32 {
        let attrs = [kSecValueData as String: Data(value.utf8)]
        return SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
    }

    func add(_ value: String) -> Int32 {
        var attrs = query
        attrs[kSecValueData as String] = Data(value.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attrs as CFDictionary, nil)
    }

    func delete() -> Int32 {
        SecItemDelete(query as CFDictionary)
    }
}
