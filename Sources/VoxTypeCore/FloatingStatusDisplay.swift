import Foundation

/// Recording visibility follows the session, independently of transient status messages.
public enum FloatingStatusDisplay: Equatable, Sendable {
    case hidden
    case persistent(String)
    case transient(String)

    public init(phase: SessionPhase, status: String) {
        switch phase {
        case .starting: self = .persistent("启动")
        case .recording: self = .persistent("录音")
        case .finishing: self = .persistent("收尾")
        case .idle:
            switch status {
            case "空闲", "已停止": self = .hidden
            case "等待松开", "确认输入": self = .persistent(status)
            default: self = .transient(status)
            }
        }
    }

    public var status: String? {
        switch self {
        case .hidden: return nil
        case .persistent(let status), .transient(let status): return status
        }
    }

    public var autoHides: Bool {
        if case .transient = self { return true }
        return false
    }
}
