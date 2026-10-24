import Foundation

public struct CommittedSentence: Equatable, Sendable {
    public var id: String
    public var text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public struct RecognitionSnapshot: Equatable, Sendable {
    public var committed: [CommittedSentence]
    public var liveText: String
    public var correctionIncomplete: Bool
    public var desynced: Bool

    public init(committed: [CommittedSentence], liveText: String, correctionIncomplete: Bool, desynced: Bool) {
        self.committed = committed
        self.liveText = liveText
        self.correctionIncomplete = correctionIncomplete
        self.desynced = desynced
    }

    public var displayText: String {
        committed.map(\.text).joined() + liveText
    }
}

public enum RecognitionApplyResult: Equatable, Sendable {
    case ignoredOldSession
    case updated(RecognitionSnapshot)
}

public struct RecognitionReducer: Equatable, Sendable {
    public private(set) var committed: [CommittedSentence] = []
    public private(set) var liveText = ""
    public private(set) var correctionIncomplete = false
    public private(set) var desynced = false
    private var committedIDs: Set<String> = []
    private var liveID: String?

    public init() {}

    public var snapshot: RecognitionSnapshot {
        RecognitionSnapshot(
            committed: committed,
            liveText: liveText,
            correctionIncomplete: correctionIncomplete,
            desynced: desynced
        )
    }

    public mutating func apply(
        activeSessionID: String,
        eventSessionID: String,
        utterances: [UtteranceUpdate],
        fullText: String?,
        isFinalPacket: Bool,
        forcedFinalize: Bool
    ) -> RecognitionApplyResult {
        guard activeSessionID == eventSessionID else { return .ignoredOldSession }
        if desynced && !forcedFinalize && !isFinalPacket {
            return .updated(snapshot)
        }
        let shouldFinalize = isFinalPacket || forcedFinalize
        if !utterances.isEmpty {
            applyUtterances(utterances)
        } else if let fullText {
            applyFullText(fullText)
        }
        if shouldFinalize {
            finalizeLive(incomplete: true)
        }
        return .updated(snapshot)
    }

    private mutating func applyUtterances(_ utterances: [UtteranceUpdate]) {
        var liveParts: [UtteranceUpdate] = []
        for utterance in utterances where !utterance.text.isEmpty || utterance.definite {
            let id = utterance.identity
            if utterance.definite {
                if let index = committed.firstIndex(where: { $0.id == id }) {
                    committed[index].text = utterance.text
                } else {
                    committed.append(CommittedSentence(id: id, text: utterance.text))
                    committedIDs.insert(id)
                }
                if liveID == id {
                    liveID = nil
                    liveText = ""
                }
            } else if !committedIDs.contains(id) {
                liveParts.append(utterance)
            }
        }
        liveText = liveParts.map(\.text).joined()
        liveID = liveParts.last?.identity
    }

    private mutating func applyFullText(_ fullText: String) {
        let prefix = committed.map(\.text).joined()
        if fullText == prefix {
            liveText = ""
            liveID = nil
            return
        }
        if committed.isEmpty {
            liveText = fullText
            liveID = "full"
            return
        }
        guard fullText.hasPrefix(prefix) else {
            let earlier = committed.dropLast().map(\.text).joined()
            if fullText.hasPrefix(earlier), let last = committed.indices.last {
                committed[last].text = String(fullText.dropFirst(earlier.count))
                liveText = ""
                liveID = nil
                return
            }
            desynced = true
            return
        }
        liveText = String(fullText.dropFirst(prefix.count))
        liveID = "full-tail"
    }

    private mutating func finalizeLive(incomplete: Bool) {
        let text = liveText
        guard !text.isEmpty else { return }
        let id = liveID ?? "final-tail"
        if !committedIDs.contains(id) {
            committed.append(CommittedSentence(id: id, text: text))
            committedIDs.insert(id)
            if incomplete {
                correctionIncomplete = true
            }
        }
        liveText = ""
        liveID = nil
    }
}
