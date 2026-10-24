import Foundation

public enum SessionPhase: Equatable, Sendable {
    case idle
    case starting
    case recording
    case finishing
}

public enum GateAction: Equatable, Sendable {
    case none
    case beginSession
    case ignoreRepeat
    case ignoreBusy
    case beginFinish
    case cancelStartAndFinish
    case enterRecording
    case alreadyStopped
}

public struct SessionGate: Equatable, Sendable {
    public var phase: SessionPhase = .idle
    public var keyHeld = false

    public init() {}

    public mutating func keyDown(isRepeat: Bool) -> GateAction {
        if isRepeat || keyHeld {
            keyHeld = true
            return .ignoreRepeat
        }
        keyHeld = true
        switch phase {
        case .idle:
            phase = .starting
            return .beginSession
        case .starting, .recording:
            return .ignoreRepeat
        case .finishing:
            return .ignoreBusy
        }
    }

    public mutating func keyUp() -> GateAction {
        let wasHeld = keyHeld
        keyHeld = false
        guard wasHeld else { return .none }
        switch phase {
        case .starting:
            phase = .finishing
            return .cancelStartAndFinish
        case .recording:
            phase = .finishing
            return .beginFinish
        case .idle, .finishing:
            return .none
        }
    }

    public mutating func micReady() -> GateAction {
        guard phase == .starting else { return .alreadyStopped }
        if !keyHeld {
            phase = .finishing
            return .cancelStartAndFinish
        }
        phase = .recording
        return .enterRecording
    }

    public mutating func finished() {
        phase = .idle
        keyHeld = false
    }
}

public struct BoundedPCMBuffer: Equatable, Sendable {
    public let capacity: Int
    public private(set) var count = 0
    public private(set) var overflowed = false
    private var storage = Data()

    public init(capacity: Int) {
        self.capacity = capacity
    }

    public mutating func append(_ data: Data) -> Bool {
        if data.isEmpty { return true }
        if storage.count + data.count > capacity {
            overflowed = true
            return false
        }
        storage.append(data)
        count = storage.count
        return true
    }

    public mutating func pop(maxBytes: Int) -> Data {
        guard maxBytes > 0, !storage.isEmpty else { return Data() }
        let take = min(maxBytes, storage.count)
        let out = Data(storage.prefix(take))
        storage.removeFirst(take)
        count = storage.count
        return out
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: false)
        count = 0
    }
}

public enum UTF16Text {
    public static func length(_ text: String) -> Int {
        text.utf16.count
    }
}

public struct OwnedRange: Equatable, Sendable {
    public var location: Int
    public var text: String

    public init(location: Int, text: String) {
        self.location = location
        self.text = text
    }

    public var length: Int {
        UTF16Text.length(text)
    }

    public func nextCursor() -> Int {
        location + length
    }
}

public enum AXRangeMath {
    public static func replacement(location: Int, previousText: String, newText: String) -> OwnedRange {
        OwnedRange(location: location, text: newText)
    }

    public static func previousLength(_ text: String) -> Int {
        UTF16Text.length(text)
    }
}

public struct ModifierMask: OptionSet, Equatable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let shift = ModifierMask(rawValue: 1 << 0)
    public static let control = ModifierMask(rawValue: 1 << 1)
    public static let option = ModifierMask(rawValue: 1 << 2)
    public static let command = ModifierMask(rawValue: 1 << 3)
}

public enum SyntheticInputPolicy {
    public static func mustDefer(held: ModifierMask) -> Bool {
        !held.isEmpty
    }
}

public struct HotkeyChord: Codable, Equatable, Sendable {
    public var keyCode: UInt16?
    public var modifiers: UInt64

    public init(keyCode: UInt16?, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var isConfigured: Bool {
        keyCode != nil || modifiers != 0
    }
}

public enum HotkeyMatcher {
    public static let relevantMask: UInt64 = 0x100000 | 0x80000 | 0x40000 | 0x20000

    public static func matches(chord: HotkeyChord, keyCode: UInt16?, modifiers: UInt64) -> Bool {
        let held = modifiers & relevantMask
        let need = chord.modifiers & relevantMask
        guard held == need else { return false }
        return chord.keyCode == keyCode
    }
}

public enum InsertedText {
    public static func sanitized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\u{2028}", with: " ")
            .replacingOccurrences(of: "\u{2029}", with: " ")
    }
}
