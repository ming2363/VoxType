import AppKit
import CoreGraphics
import Foundation
import VoxTypeCore

final class HotkeyMonitor {
    var chordProvider: () -> HotkeyChord? = { nil }
    var recordingProvider: () -> Bool = { false }
    var sessionActiveProvider: () -> Bool = { false }
    var onDown: (Bool) -> Void = { _ in }
    var onUp: () -> Void = {}
    var onUserKey: () -> Void = {}
    var onModifiers: (ModifierMask) -> Void = { _ in }
    var onUnavailable: () -> Void = {}

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var state = HotkeyEventState()
    private let contextLock = NSLock()
    private var chordSnapshot: HotkeyChord?
    private var recordingSnapshot = false
    private var sessionActiveSnapshot = false
    private(set) var isRunning = false

    func syncContext() {
        let chord = chordProvider()
        let recording = recordingProvider()
        let active = sessionActiveProvider()
        contextLock.lock()
        chordSnapshot = chord
        recordingSnapshot = recording
        sessionActiveSnapshot = active
        contextLock.unlock()
    }

    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        syncContext()
        let started = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.runTap(started: started)
        }
        thread.name = "VoxTypeHotkey"
        thread.qualityOfService = .userInteractive
        thread.start()
        _ = started.wait(timeout: .now() + 1.5)
        return isRunning
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let tapRunLoop {
            CFRunLoopStop(tapRunLoop)
        }
        tap = nil
        runLoopSource = nil
        tapRunLoop = nil
        isRunning = false
        state = HotkeyEventState()
    }

    private func runTap(started: DispatchSemaphore) {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyTapCallback,
            userInfo: userInfo
        ) else {
            isRunning = false
            started.signal()
            DispatchQueue.main.async { [weak self] in self?.onUnavailable() }
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        let loop = CFRunLoopGetCurrent()
        tapRunLoop = loop
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        started.signal()
        CFRunLoopRun()
        isRunning = false
    }

    func restart() -> Bool {
        stop()
        return start()
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        }
        let modifiers = Self.mask(from: event.flags)
        let synthetic = event.getIntegerValueField(.eventSourceUserData) == AppModel.syntheticMarker
        if !synthetic {
            let mask = modifiers
            DispatchQueue.main.async { [weak self] in self?.onModifiers(mask) }
        }
        let kind: KeyEventKind
        switch type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        default: kind = .flagsChanged
        }
        contextLock.lock()
        let chord = chordSnapshot
        let recording = recordingSnapshot
        let active = sessionActiveSnapshot
        contextLock.unlock()
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let watched = chord?.keyCode ?? keyCode
        let physicallyDown = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(watched))
        let decision = state.handle(
            kind: kind,
            keyCode: keyCode,
            modifiers: event.flags.rawValue,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) == 1,
            isSynthetic: synthetic,
            chord: chord,
            sessionActive: active,
            recordingShortcut: recording,
            keyPhysicallyDown: physicallyDown
        )
        switch decision.action {
        case .none:
            break
        case .down(let isRepeat):
            DispatchQueue.main.async { [weak self] in
                self?.onDown(isRepeat)
                self?.syncContext()
            }
        case .up:
            DispatchQueue.main.async { [weak self] in
                self?.onUp()
                self?.syncContext()
            }
        case .userKey:
            DispatchQueue.main.async { [weak self] in self?.onUserKey() }
        }
        return decision.swallow
    }

    private static func mask(from flags: CGEventFlags) -> ModifierMask {
        var mask: ModifierMask = []
        if flags.contains(.maskShift) { mask.insert(.shift) }
        if flags.contains(.maskControl) { mask.insert(.control) }
        if flags.contains(.maskAlternate) { mask.insert(.option) }
        if flags.contains(.maskCommand) { mask.insert(.command) }
        return mask
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    if monitor.handle(type: type, event: event) {
        return nil
    }
    return Unmanaged.passUnretained(event)
}
