import Foundation

public enum WriteRoute: Equatable, Sendable {
    case liveReplace
    case sentenceInsert
    case releaseInsert
}

public enum WriteOp: Equatable, Sendable {
    case replaceLive(String)
    case lockLive
    case insert(String)
    case replaceLastCommitted(String)
    case stop
}

public struct WritePlan: Equatable, Sendable {
    public var ops: [WriteOp]

    public init(ops: [WriteOp]) {
        self.ops = ops
    }

    public static let none = WritePlan(ops: [])
}

public struct DictationWriteModel: Equatable, Sendable {
    public var route: WriteRoute
    public private(set) var stopped = false
    public private(set) var committedWritten = 0
    private var liveWritten = ""
    private var liveOpen = false
    private var releaseDone = false
    private var lastCommittedID: String?
    private var lastCommittedText: String?

    public init(route: WriteRoute) {
        self.route = route
    }

    public mutating func apply(snapshot: RecognitionSnapshot, focusValid: Bool) -> WritePlan {
        if stopped || releaseDone {
            return .none
        }
        if !focusValid || snapshot.desynced {
            stopped = true
            return WritePlan(ops: [.stop])
        }
        var ops = correctionOps(snapshot)
        switch route {
        case .liveReplace:
            ops.append(contentsOf: liveOps(snapshot))
        case .sentenceInsert:
            ops.append(contentsOf: sentenceOps(snapshot))
        case .releaseInsert:
            break
        }
        return WritePlan(ops: ops)
    }

    public mutating func finish(snapshot: RecognitionSnapshot, focusValid: Bool) -> WritePlan {
        if stopped || releaseDone {
            return .none
        }
        if !focusValid || snapshot.desynced {
            stopped = true
            return WritePlan(ops: [.stop])
        }
        switch route {
        case .liveReplace:
            var ops = correctionOps(snapshot)
            ops.append(contentsOf: liveOps(snapshot))
            if liveOpen {
                if snapshot.liveText != liveWritten {
                    ops.append(.replaceLive(snapshot.liveText))
                    liveWritten = snapshot.liveText
                }
                if snapshot.liveText.isEmpty {
                    ops.append(.lockLive)
                    liveOpen = false
                }
            }
            releaseDone = true
            return WritePlan(ops: ops)
        case .sentenceInsert, .releaseInsert:
            let pending = unwrittenText(snapshot)
            committedWritten = snapshot.committed.count
            liveWritten = snapshot.liveText
            releaseDone = true
            if pending.isEmpty {
                return .none
            }
            return WritePlan(ops: [.insert(pending)])
        }
    }

    private mutating func liveOps(_ snapshot: RecognitionSnapshot) -> [WriteOp] {
        var ops: [WriteOp] = []
        let fresh = Array(snapshot.committed.dropFirst(committedWritten))
        if let first = fresh.first {
            if liveOpen {
                if first.text != liveWritten {
                    ops.append(.replaceLive(first.text))
                }
                ops.append(.lockLive)
                liveOpen = false
                liveWritten = ""
            } else if !first.text.isEmpty {
                ops.append(.insert(first.text))
            }
            committedWritten += 1
            noteCommitted(first)
            for sentence in fresh.dropFirst() where !sentence.text.isEmpty {
                ops.append(.insert(sentence.text))
                committedWritten += 1
                noteCommitted(sentence)
            }
        }
        if snapshot.liveText != liveWritten || (snapshot.liveText.isEmpty && liveOpen) {
            if !snapshot.liveText.isEmpty || liveOpen {
                ops.append(.replaceLive(snapshot.liveText))
                liveOpen = !snapshot.liveText.isEmpty
            }
            liveWritten = snapshot.liveText
        }
        return ops
    }

    private mutating func sentenceOps(_ snapshot: RecognitionSnapshot) -> [WriteOp] {
        let fresh = snapshot.committed.dropFirst(committedWritten)
        let text = fresh.map(\.text).joined()
        committedWritten = snapshot.committed.count
        if let last = snapshot.committed.last {
            noteCommitted(last)
        }
        if text.isEmpty {
            return []
        }
        return [.insert(text)]
    }

    private mutating func correctionOps(_ snapshot: RecognitionSnapshot) -> [WriteOp] {
        guard let last = snapshot.committed.last,
              last.id == lastCommittedID,
              let previous = lastCommittedText,
              previous != last.text else {
            return []
        }
        lastCommittedText = last.text
        return [.replaceLastCommitted(last.text)]
    }

    private mutating func noteCommitted(_ sentence: CommittedSentence) {
        lastCommittedID = sentence.id
        lastCommittedText = sentence.text
    }

    private func unwrittenText(_ snapshot: RecognitionSnapshot) -> String {
        let committed = snapshot.committed.dropFirst(committedWritten).map(\.text).joined()
        if route == .sentenceInsert && liveWritten == snapshot.liveText {
            return committed
        }
        return committed + snapshot.liveText
    }
}
