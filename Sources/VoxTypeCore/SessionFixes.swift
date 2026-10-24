import Foundation

public enum AudioPumpAction: Equatable, Sendable {
    case wait(TimeInterval)
    case send(isLast: Bool)
    case stop
}

public enum AudioSendScheduler {
    public static let idleWait: TimeInterval = 0.05
    public static let backlogWait: TimeInterval = 0.02

    public static func decide(
        phase: SessionPhase,
        handshakeReady: Bool,
        lastPacketSent: Bool,
        pendingBytes: Int,
        conversionPending: Bool,
        packetBytes: Int
    ) -> AudioPumpAction {
        guard handshakeReady, !lastPacketSent else { return .stop }
        if pendingBytes >= packetBytes {
            return .send(isLast: false)
        }
        switch phase {
        case .recording, .starting:
            return .wait(idleWait)
        case .finishing:
            if conversionPending {
                return .wait(idleWait)
            }
            return .send(isLast: true)
        case .idle:
            return .stop
        }
    }
}

public struct LiveTextDocument: Equatable, Sendable {
    public private(set) var text = ""
    public private(set) var owned: String?

    public init() {}

    public mutating func apply(_ op: WriteOp) {
        switch op {
        case .replaceLive(let next):
            if let owned, text.hasSuffix(owned) {
                text = String(text.dropLast(owned.count)) + next
            } else if owned == nil {
                text += next
            }
            owned = next
        case .lockLive:
            owned = nil
        case .insert(let next):
            text += next
            owned = nil
        case .replaceLastCommitted(let next):
            if let owned, text.hasSuffix(owned) {
                text = String(text.dropLast(owned.count)) + next
            }
            owned = nil
        case .stop:
            break
        }
    }
}

public struct InsertionGuard: Equatable, Sendable {
    public private(set) var invalidated = false
    public var ownedLocation: Int?
    public var ownedText: String?
    public var expectedCursor: Int?

    public init() {}

    public mutating func noteLive(location: Int, text: String) {
        guard !invalidated else { return }
        ownedLocation = location
        ownedText = text
        expectedCursor = location + UTF16Text.length(text)
    }

    public mutating func noteLock() {
        guard !invalidated else { return }
        expectedCursor = ownedLocation.map { $0 + UTF16Text.length(ownedText ?? "") } ?? expectedCursor
        ownedLocation = nil
        ownedText = nil
    }

    public mutating func noteCommittedInsert(endCursor: Int) {
        guard !invalidated else { return }
        expectedCursor = endCursor
        ownedLocation = nil
        ownedText = nil
    }

    public mutating func invalidate() {
        invalidated = true
    }

    public mutating func observe(
        focusMatches: Bool,
        selectionLocation: Int?,
        selectionLength: Int?,
        ownedActual: String?
    ) -> Bool {
        if invalidated { return false }
        guard focusMatches else {
            invalidated = true
            return false
        }
        if let ownedText, let ownedLocation {
            if ownedActual != ownedText {
                invalidated = true
                return false
            }
            let length = UTF16Text.length(ownedText)
            let atEnd = selectionLocation == ownedLocation + length && selectionLength == 0
            let covering = selectionLocation == ownedLocation && selectionLength == length
            if !atEnd && !covering {
                invalidated = true
                return false
            }
        } else if let expectedCursor {
            let location = selectionLocation ?? -1
            let length = selectionLength ?? 0
            if location != expectedCursor && location + length != expectedCursor {
                invalidated = true
                return false
            }
        }
        return true
    }
}

public enum DeliveryObservation: Equatable, Sendable {
    case success
    case unchanged
    case focusLost
    case editedByUser
    case uncertain
}

public struct DeliveryConfirmer: Equatable, Sendable {
    public let maxObservations: Int
    public private(set) var observations = 0

    public init(maxObservations: Int = 5) {
        self.maxObservations = maxObservations
    }

    public mutating func observe(
        before: String?,
        after: String?,
        expected: String,
        insertionIndex: Int?,
        focusValid: Bool,
        userEdited: Bool
    ) -> DeliveryObservation? {
        if !focusValid { return .focusLost }
        if userEdited { return .editedByUser }
        observations += 1
        guard let before, let after, let insertionIndex else {
            return observations >= maxObservations ? .uncertain : nil
        }
        if InsertionProof.confirmed(before: before, after: after, expected: expected, insertionIndex: insertionIndex) {
            return .success
        }
        if after == before {
            return observations >= maxObservations ? .uncertain : nil
        }
        return .uncertain
    }
}

public enum InsertionProof {
    public static func confirmed(before: String, after: String, expected: String, insertionIndex: Int) -> Bool {
        let beforeUnits = Array(before.utf16)
        let afterUnits = Array(after.utf16)
        let expectedUnits = Array(expected.utf16)
        guard insertionIndex >= 0, insertionIndex <= beforeUnits.count else { return false }
        var rebuilt = Array(beforeUnits.prefix(insertionIndex))
        rebuilt.append(contentsOf: expectedUnits)
        rebuilt.append(contentsOf: beforeUnits.suffix(beforeUnits.count - insertionIndex))
        return afterUnits == rebuilt
    }
}

public enum DeliveryRetry {
    public static func mayPostAgain(_ observation: DeliveryObservation) -> Bool {
        switch observation {
        case .success, .unchanged, .focusLost, .editedByUser, .uncertain:
            return false
        }
    }
}

public enum UTF16Chunker {
    public static func chunks(_ text: String, limit: Int = 20) -> [String] {
        let units = Array(text.utf16)
        guard limit > 1, !units.isEmpty else { return text.isEmpty ? [] : [text] }
        var result: [String] = []
        var index = 0
        while index < units.count {
            var end = min(index + limit, units.count)
            if end < units.count && end > index {
                let boundary = units[end - 1]
                if boundary >= 0xD800 && boundary <= 0xDBFF {
                    end -= 1
                }
            }
            if end <= index {
                end = min(index + 2, units.count)
            }
            let slice = Array(units[index..<end])
            result.append(String(utf16CodeUnits: slice, count: slice.count))
            index = end
        }
        return result
    }
}

public struct ASRDeliveryHandoff: Equatable, Sendable {
    public var asrReleased = false
    public var deliveryPollCancelled = false
    public var pendingDelivery = false
    public var waitingModifiers = false
    public var status = "空闲"

    public init() {}

    public var sessionStillLocal: Bool { pendingDelivery || waitingModifiers }

    public mutating func asrCompleted(startedDelivery: Bool, modifiersHeld: Bool) {
        asrReleased = true
        deliveryPollCancelled = false
        if startedDelivery {
            pendingDelivery = true
            waitingModifiers = false
            status = "确认输入"
        } else if modifiersHeld {
            waitingModifiers = true
            status = "等待松开"
        } else {
            waitingModifiers = false
            pendingDelivery = false
            status = "空闲"
        }
    }

    public mutating func deliveryResolved() {
        pendingDelivery = false
        waitingModifiers = false
        status = "空闲"
    }

    public mutating func cancelLocalDelivery() {
        deliveryPollCancelled = true
        pendingDelivery = false
        waitingModifiers = false
    }
}

public enum DeferredClose {
    public static func enqueue(on queue: DispatchQueue, owner: AnyObject, work: @escaping () -> Void) {
        queue.async {
            withExtendedLifetime(owner) {
                work()
            }
        }
    }
}

public enum SessionCallbackFilter {
    public static func shouldApply(activeSessionID: String, eventSessionID: String, cleanedUp: Bool) -> Bool {
        !cleanedUp && !activeSessionID.isEmpty && activeSessionID == eventSessionID
    }
}

public final class SessionCallbackGate {
    public private(set) var acceptID = ""
    public private(set) var cleanedUp = false
    public private(set) var handshakeReady = false
    public private(set) var failed = false

    public init() {}

    public func begin(_ id: String) {
        acceptID = id
        cleanedUp = false
        handshakeReady = false
        failed = false
    }

    public func accepts(_ eventID: String) -> Bool {
        SessionCallbackFilter.shouldApply(activeSessionID: acceptID, eventSessionID: eventID, cleanedUp: cleanedUp)
    }

    @discardableResult
    public func handshake(_ eventID: String) -> Bool {
        guard accepts(eventID) else { return false }
        handshakeReady = true
        return true
    }

    @discardableResult
    public func failure(_ eventID: String) -> Bool {
        guard accepts(eventID) else { return false }
        failed = true
        cleanedUp = true
        return true
    }

    @discardableResult
    public func timeout(_ eventID: String) -> Bool {
        guard accepts(eventID), !handshakeReady else { return false }
        failed = true
        cleanedUp = true
        return true
    }

    public func releaseASR() {
        cleanedUp = true
    }
}

public struct SessionDeliveryState: Equatable, Sendable {
    public var unicodeTried = false
    public var fallbackIsUnicode = false

    public init() {}

    public mutating func reset(fallbackIsUnicode: Bool) {
        unicodeTried = false
        self.fallbackIsUnicode = fallbackIsUnicode
    }

    public mutating func nextChannel() -> String {
        if fallbackIsUnicode && !unicodeTried {
            unicodeTried = true
            return "unicode"
        }
        return "paste"
    }
}

public enum FinishStatus {
    public static func resolve(
        writeFailed: Bool,
        pendingDelivery: Bool,
        waitingModifiers: Bool,
        incomplete: Bool,
        successDetail: String
    ) -> (short: String, detail: String)? {
        if writeFailed { return nil }
        if pendingDelivery { return ("确认输入", "正在确认文字是否写入") }
        if waitingModifiers { return ("等待松开", "松开修饰键后输入剩余文字") }
        if incomplete { return ("未完成", successDetail) }
        return ("空闲", successDetail)
    }
}

public protocol CredentialKeychain: AnyObject {
    var stored: String? { get }
    func update(_ value: String) -> Int32
    func add(_ value: String) -> Int32
    func delete() -> Int32
}

public enum CredentialEditor {
    public static func save(_ raw: String, in keychain: CredentialKeychain, notFound: Int32 = -25300) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            let status = keychain.delete()
            return status == 0 || status == notFound
        }
        if keychain.stored != nil {
            return keychain.update(value) == 0
        }
        return keychain.add(value) == 0
    }
}

public enum KeyEventKind: Equatable, Sendable {
    case keyDown
    case keyUp
    case flagsChanged
}

public enum HotkeyAction: Equatable, Sendable {
    case none
    case down(isRepeat: Bool)
    case up
    case userKey
}

public struct HotkeyDecision: Equatable, Sendable {
    public var action: HotkeyAction
    public var swallow: Bool

    public init(action: HotkeyAction, swallow: Bool) {
        self.action = action
        self.swallow = swallow
    }
}

public struct HotkeyEventState: Equatable, Sendable {
    public var engaged = false
    public var capturedKey: UInt16?

    public init() {}

    public mutating func handle(
        kind: KeyEventKind,
        keyCode: UInt16,
        modifiers: UInt64,
        isRepeat: Bool,
        isSynthetic: Bool,
        chord: HotkeyChord?,
        sessionActive: Bool,
        recordingShortcut: Bool,
        keyPhysicallyDown: Bool = false
    ) -> HotkeyDecision {
        if isSynthetic || recordingShortcut {
            return HotkeyDecision(action: .none, swallow: false)
        }
        if kind == .keyDown && (54...63).contains(Int(keyCode)) {
            return HotkeyDecision(action: .none, swallow: false)
        }
        guard let chord, chord.isConfigured, chord.keyCode != nil else {
            if kind == .keyDown && sessionActive && !isRepeat {
                return HotkeyDecision(action: .userKey, swallow: false)
            }
            return HotkeyDecision(action: .none, swallow: false)
        }
        let matches = HotkeyMatcher.matches(chord: chord, keyCode: keyCode, modifiers: modifiers)
        if kind == .keyDown && keyCode == capturedKey {
            let repeatDown = engaged && isRepeat
            if !engaged {
                return HotkeyDecision(action: .none, swallow: true)
            }
            engaged = true
            capturedKey = keyCode
            return HotkeyDecision(action: .down(isRepeat: repeatDown), swallow: true)
        }
        if kind == .keyDown && matches {
            engaged = true
            capturedKey = keyCode
            return HotkeyDecision(action: .down(isRepeat: false), swallow: true)
        }
        if kind == .keyUp && keyCode == capturedKey {
            if keyPhysicallyDown {
                return HotkeyDecision(action: .none, swallow: true)
            }
            let shouldEnd = engaged
            engaged = false
            capturedKey = nil
            return HotkeyDecision(action: shouldEnd ? .up : .none, swallow: true)
        }
        if kind == .flagsChanged && engaged {
            if keyPhysicallyDown {
                return HotkeyDecision(action: .none, swallow: false)
            }
            let held = modifiers & HotkeyMatcher.relevantMask
            let need = chord.modifiers & HotkeyMatcher.relevantMask
            if need != 0 && held & need == 0 {
                engaged = false
                return HotkeyDecision(action: .up, swallow: false)
            }
        }
        if kind == .keyDown && (engaged || sessionActive) && !isRepeat {
            return HotkeyDecision(action: .userKey, swallow: false)
        }
        return HotkeyDecision(action: .none, swallow: false)
    }
}

public enum HotkeySupport: Equatable, Sendable {
    case usable
    case rejected(String)
}

public enum HotkeySafety {
    public static func assess(_ chord: HotkeyChord) -> HotkeySupport {
        guard chord.isConfigured else {
            return .rejected("未设置快捷键")
        }
        if chord.keyCode == nil {
            return .rejected("仅修饰键无法可靠拦截，请同时指定一个主键")
        }
        let mods = chord.modifiers & HotkeyMatcher.relevantMask
        let key = chord.keyCode
        if key == 49 && (mods == 0x100000 || mods == 0x40000) {
            return .rejected("空格配合 Command 或 Control 是系统保留组合，不能用作听写键")
        }
        if key == 48 && mods == 0x100000 {
            return .rejected("Command+Tab 是系统保留组合，不能用作听写键")
        }
        if key == 53 && mods == (0x100000 | 0x80000) {
            return .rejected("Command+Option+Esc 是系统保留组合，不能用作听写键")
        }
        if key == 12 && mods == 0x100000 {
            return .rejected("Command+Q 会退出应用，不能用作听写键")
        }
        return .usable
    }
}

public extension SessionGate {
    mutating func interrupt() -> GateAction {
        switch phase {
        case .starting:
            phase = .finishing
            keyHeld = false
            return .cancelStartAndFinish
        case .recording:
            phase = .finishing
            keyHeld = false
            return .beginFinish
        case .finishing:
            return .beginFinish
        case .idle:
            return .none
        }
    }
}
