import AppKit
import ApplicationServices
import Foundation
import VoxTypeCore

enum WriteOutcome: Equatable {
    case applied
    case failedClear
    case uncertain
    case focusLost
}

enum InputProbe {
    case live(AXUIElement, pid_t)
    case sentence(AXUIElement, pid_t)
    case unicode(AXUIElement, pid_t)
    case focusUnavailable(String)
    case blocked(String)
}

final class TextInserter {
    private var element: AXUIElement?
    private var targetPID: pid_t = 0
    private var owned: OwnedRange?
    private var lastLocked: OwnedRange?
    private var cursor: Int?
    private var consumedInitialSelection = false
    private var uncertain = false
    private var guardState = InsertionGuard()
    private let marker = AppModel.syntheticMarker
    private var delivery: PendingDelivery?
    private let focusReader = FocusedElementReader()

    func prepareAccessibility(for pid: pid_t) {
        focusReader.prepareAccessibility(for: pid)
    }

    func probe(targetPID: pid_t? = nil) -> InputProbe {
        guard AXIsProcessTrusted() else { return .blocked("需要辅助功能权限") }
        let focus = focusReader.resolve(expectedPID: targetPID)
        guard let element = focus.element else { return .focusUnavailable(focus.failureMessage) }
        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute) ?? ""
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" || role.contains("Secure") {
            return .blocked("不支持密码框")
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let selectedSettable = isSettable(element, kAXSelectedTextAttribute)
        let rangeSettable = isSettable(element, kAXSelectedTextRangeAttribute)
        let canReadRange = readString(element, range: CFRange(location: 0, length: 0)) != nil
            || readSelection(element) != nil && parameterizedAvailable(element)
        let textRole = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXTextView"].contains(role)
        if selectedSettable && rangeSettable && canReadRange && (textRole || selectedSettable) {
            return .live(element, pid)
        }
        if selectedSettable && textRole {
            return .sentence(element, pid)
        }
        if textRole || role == "AXWebArea" || selectedSettable {
            return .unicode(element, pid)
        }
        return .blocked("当前焦点不是可编辑输入框")
    }

    func prepare(_ element: AXUIElement) {
        self.element = element
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        targetPID = pid
        owned = nil
        cursor = readSelection(element)?.location
        consumedInitialSelection = false
        uncertain = false
        guardState = InsertionGuard()
        if let cursor {
            guardState.expectedCursor = cursor
        }
        delivery = nil
    }

    func invalidate() {
        guardState.invalidate()
        uncertain = true
        delivery = nil
    }

    func focusStillValid() -> Bool {
        guard !guardState.invalidated else { return false }
        guard let element else { return false }
        guard let current = systemFocus() else { return false }
        if CFEqual(element, current) { return true }
        if sameField(element, current) {
            self.element = current
            return true
        }
        return false
    }

    func focusRect() -> CGRect? {
        let target = systemFocus() ?? element
        guard let target else { return nil }
        if let range = readSelection(target), let bounds = boundsForRange(target, range) {
            let caret = axToAppKit(bounds)
            if isUsableCaret(caret) {
                return caret
            }
        }
        if let frame = axFrame(target).map(axToAppKit), isUsableCaret(frame) {
            return frame
        }
        if let window = windowFrame(from: target) {
            return CGRect(x: window.minX + 20, y: window.minY + 12, width: 28, height: 22)
        }
        return nil
    }

    func contains(_ text: String) -> Bool {
        let text = InsertedText.sanitized(text)
        guard !text.isEmpty, let element = resolvedFocus() else { return false }
        return contains(text, in: element)
    }

    @discardableResult
    func commit(_ text: String) -> Bool {
        let text = InsertedText.sanitized(text)
        guard !text.isEmpty else { return true }
        guard let element = resolvedFocus() else { return false }
        if contains(text, in: element) { return true }
        let readable = stringAttribute(element, kAXValueAttribute) != nil || readSelection(element) != nil
        guard readable, setSelectedText(element, text), contains(text, in: element) else { return false }
        self.element = element
        let selection = readSelection(element)
        cursor = selection?.location ?? ((cursor ?? 0) + UTF16Text.length(text))
        guardState = InsertionGuard()
        if let cursor {
            guardState.expectedCursor = cursor
        }
        return true
    }

    func bindCurrentFocus() -> Bool {
        guard let current = systemFocus() else { return false }
        let role = stringAttribute(current, kAXRoleAttribute) ?? ""
        let subrole = stringAttribute(current, kAXSubroleAttribute) ?? ""
        if role.contains("Secure") || subrole.contains("Secure") { return false }
        element = current
        targetPID = pid(of: current)
        uncertain = false
        guardState = InsertionGuard()
        owned = nil
        return true
    }

    func acceptsTargetApp() -> Bool {
        guard targetPID != 0, let current = systemFocus() else { return false }
        return pid(of: current) == targetPID
    }

    func insertionStillAllowed() -> Bool {
        guard !guardState.invalidated else { return false }
        let matches = focusStillValid()
        let selection = element.flatMap { readSelection($0) }
        let ownedActual = owned.flatMap { range in
            element.flatMap { readString($0, range: CFRange(location: range.location, length: range.length)) }
        }
        return guardState.observe(
            focusMatches: matches,
            selectionLocation: selection.map { $0.location },
            selectionLength: selection.map { $0.length },
            ownedActual: owned == nil ? nil : ownedActual
        )
    }

    func replaceLive(_ text: String) -> WriteOutcome {
        let text = InsertedText.sanitized(text)
        guard let element else { return .focusLost }
        guard focusStillValid() else { return .focusLost }
        if uncertain { return .uncertain }
        if owned == nil {
            return firstLiveWrite(element, text: text)
        }
        guard let owned else { return .uncertain }
        guard let actual = readString(element, range: CFRange(location: owned.location, length: owned.length)) else {
            uncertain = true
            return .uncertain
        }
        if actual != owned.text {
            uncertain = true
            return .uncertain
        }
        guard select(element, range: CFRange(location: owned.location, length: owned.length)) else {
            uncertain = true
            return .uncertain
        }
        guard setSelectedText(element, text) else {
            uncertain = true
            return .uncertain
        }
        let updated = OwnedRange(location: owned.location, text: text)
        if let read = readString(element, range: CFRange(location: updated.location, length: updated.length)), read != text {
            uncertain = true
            return .uncertain
        }
        self.owned = updated
        cursor = updated.nextCursor()
        guardState.noteLive(location: updated.location, text: text)
        return .applied
    }

    func lockLive() {
        if let owned {
            lastLocked = owned
            cursor = owned.nextCursor()
        }
        owned = nil
        guardState.noteLock()
    }

    func replaceLastCommitted(_ text: String) -> WriteOutcome {
        let text = InsertedText.sanitized(text)
        guard let element, let locked = lastLocked else { return .uncertain }
        guard focusStillValid() else { return .focusLost }
        guard select(element, range: CFRange(location: locked.location, length: locked.length)) else {
            return .uncertain
        }
        guard setSelectedText(element, text) else { return .uncertain }
        let updated = OwnedRange(location: locked.location, text: text)
        let delta = updated.length - locked.length
        lastLocked = updated
        if let cursor {
            self.cursor = cursor + delta
            guardState.expectedCursor = self.cursor
        }
        return .applied
    }

    func insert(_ text: String) -> WriteOutcome {
        let text = InsertedText.sanitized(text)
        guard !text.isEmpty else { return .applied }
        guard let element else { return .focusLost }
        guard focusStillValid() else { return .focusLost }
        if uncertain { return .uncertain }
        let selection = readSelection(element) ?? CFRange(location: cursor ?? 0, length: 0)
        if selection.length > 0 && consumedInitialSelection {
            uncertain = true
            return .uncertain
        }
        guard setSelectedText(element, text) else {
            uncertain = true
            return .uncertain
        }
        consumedInitialSelection = true
        let written = OwnedRange(location: selection.location, text: text)
        lastLocked = written
        cursor = written.nextCursor()
        guardState.noteCommittedInsert(endCursor: cursor ?? selection.location)
        return .applied
    }

    func beginUnicode(_ text: String) -> Bool {
        let text = InsertedText.sanitized(text)
        guard !text.isEmpty else { return false }
        guard acceptsTargetApp() || insertionStillAllowed() else { return false }
        let before = element.flatMap { stringAttribute($0, kAXValueAttribute) }
        for chunk in UTF16Chunker.chunks(text, limit: 20) {
            var slice = Array(chunk.utf16)
            let source = CGEventSource(stateID: .privateState)
            source?.userData = marker
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else { return false }
            down.flags = []
            down.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
            down.setIntegerValueField(.eventSourceUserData, value: marker)
            down.post(tap: .cgAnnotatedSessionEventTap)
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.setIntegerValueField(.eventSourceUserData, value: marker)
                up.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
        delivery = PendingDelivery(
            text: text,
            before: before,
            insertionIndex: cursor ?? UTF16Text.length(before ?? ""),
            confirmer: DeliveryConfirmer()
        )
        return true
    }

    func pollDelivery() -> DeliveryObservation? {
        guard var pending = delivery else { return .uncertain }
        let focusOK = focusStillValid()
        let after = element.flatMap { stringAttribute($0, kAXValueAttribute) }
        let userEdited = after != nil && pending.before != nil && after != pending.before && !(after?.contains(pending.text) ?? false)
        let observation = pending.confirmer.observe(
            before: pending.before,
            after: after,
            expected: pending.text,
            insertionIndex: pending.insertionIndex,
            focusValid: focusOK,
            userEdited: userEdited
        )
        delivery = pending
        guard let observation else { return nil }
        delivery = nil
        if observation == .focusLost || observation == .editedByUser {
            guardState.invalidate()
        }
        return observation
    }

    var hasPendingDelivery: Bool { delivery != nil }
    private func firstLiveWrite(_ element: AXUIElement, text: String) -> WriteOutcome {
        let selection = readSelection(element) ?? CFRange(location: 0, length: 0)
        guard setSelectedText(element, text) else {
            uncertain = true
            return .uncertain
        }
        let owned = OwnedRange(location: selection.location, text: text)
        if let read = readString(element, range: CFRange(location: owned.location, length: owned.length)), read != text && !text.isEmpty {
            uncertain = true
            return .uncertain
        }
        self.owned = owned
        cursor = owned.nextCursor()
        guardState.noteLive(location: owned.location, text: text)
        consumedInitialSelection = true
        return .applied
    }

    private func resolvedFocus() -> AXUIElement? {
        guard let current = systemFocus() else { return element }
        if let element {
            if CFEqual(element, current) || sameField(element, current) {
                self.element = current
                return current
            }
            return nil
        }
        return current
    }

    private func sameField(_ left: AXUIElement, _ right: AXUIElement) -> Bool {
        if CFEqual(left, right) { return true }
        let leftPID = pid(of: left)
        guard leftPID != 0, leftPID == pid(of: right) else { return false }
        let leftRole = stringAttribute(left, kAXRoleAttribute)
        let rightRole = stringAttribute(right, kAXRoleAttribute)
        if leftRole != rightRole { return false }
        guard let leftFrame = axFrame(left), let rightFrame = axFrame(right) else { return true }
        return leftFrame.insetBy(dx: -12, dy: -12).intersects(rightFrame)
    }

    private func contains(_ text: String, in element: AXUIElement) -> Bool {
        if let value = stringAttribute(element, kAXValueAttribute), value.contains(text) {
            return true
        }
        guard let selection = readSelection(element) else { return false }
        let length = UTF16Text.length(text)
        let start = selection.location - length
        guard start >= 0 else { return false }
        return readString(element, range: CFRange(location: start, length: length)) == text
    }

    private func pid(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    private func axFrame(_ element: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size,
              let point = axPoint(from: pos),
              let dimensions = axSize(from: size) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func boundsForRange(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        var mutable = range
        guard let axRange = AXValueCreate(.cfRange, &mutable) else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            axRange,
            &value
        )
        guard error == .success, let value, let rect = axRect(from: value) else { return nil }
        return rect
    }

    private func axToAppKit(_ rect: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
        let flipped = CGRect(
            x: rect.origin.x,
            y: top - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
        if intersectsScreen(flipped) { return flipped }
        if intersectsScreen(rect) { return rect }
        return flipped
    }

    private func isUsableCaret(_ rect: CGRect) -> Bool {
        rect.width >= 0 && rect.height > 1 && rect.height < 72 && rect.width < 520 && intersectsScreen(rect)
    }

    private func intersectsScreen(_ rect: CGRect) -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(rect.insetBy(dx: -8, dy: -8)) }
    }

    private func windowFrame(from element: AXUIElement) -> CGRect? {
        var node: AXUIElement? = element
        for _ in 0..<12 {
            guard let current = node else { break }
            let role = stringAttribute(current, kAXRoleAttribute) ?? ""
            if role == "AXWindow" || role == "AXDialog" || role == "AXSheet" {
                if let frame = axFrame(current) {
                    let cocoa = axToAppKit(frame)
                    if intersectsScreen(cocoa), cocoa.width > 80, cocoa.height > 80 {
                        return cocoa
                    }
                }
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent,
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            node = unsafeBitCast(parent, to: AXUIElement.self)
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeBitCast(value, to: AXUIElement.self)
        guard let frame = axFrame(window) else { return nil }
        let cocoa = axToAppKit(frame)
        return intersectsScreen(cocoa) ? cocoa : nil
    }

    private func axRect(from value: CFTypeRef) -> CGRect? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(ax) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(ax, .cgRect, &rect) else { return nil }
        return rect
    }

    private func axPoint(from value: CFTypeRef) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(ax) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(ax, .cgPoint, &point) else { return nil }
        return point
    }

    private func axSize(from value: CFTypeRef) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(ax) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(ax, .cgSize, &size) else { return nil }
        return size
    }

    private func systemFocus() -> AXUIElement? {
        focusReader.resolve().element
    }

    private func parameterizedAvailable(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        let error = AXUIElementCopyParameterizedAttributeNames(element, &names)
        guard error == .success, let names else { return false }
        return (names as? [String])?.contains(kAXStringForRangeParameterizedAttribute as String) == true
    }

    private func readString(_ element: AXUIElement, range: CFRange) -> String? {
        var mutable = range
        guard let axRange = AXValueCreate(.cfRange, &mutable) else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            axRange,
            &value
        )
        guard error == .success, let text = value as? String else { return nil }
        return text
    }

    private func readSelection(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard error == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(ax) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ax, .cfRange, &range) else { return nil }
        return range
    }

    private func select(_ element: AXUIElement, range: CFRange) -> Bool {
        var mutable = range
        guard let value = AXValueCreate(.cfRange, &mutable) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    private func setSelectedText(_ element: AXUIElement, _ text: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    private func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return error == .success && settable.boolValue
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? String
    }
}

private struct PendingDelivery {
    var text: String
    var before: String?
    var insertionIndex: Int
    var confirmer: DeliveryConfirmer
}
