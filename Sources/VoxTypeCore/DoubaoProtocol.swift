import Foundation

/// 豆包流式语音识别模型 2.0 双向流式协议。
/// 帧布局对齐官方运行示例 sauc_python/protocol.py（文档附件，2026-09-28）：
/// 4 字节头、大端序号、Gzip；音频帧沿用默认头的 JSON 序列化标志，负序号表示最后一包。
public enum DoubaoEndpoint {
    public static let webSocketURL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
    public static let resourceDuration = "volc.seedasr.sauc.duration"
    public static let resourceConcurrent = "volc.seedasr.sauc.concurrent"
    public static let sampleRate = 16_000
    public static let packetMilliseconds = 200
    public static let packetBytes = sampleRate * 2 * packetMilliseconds / 1000
    public static let connectBufferSeconds = 3
    public static let connectBufferBytes = sampleRate * 2 * connectBufferSeconds
    public static let finishTimeoutSeconds = 3.0
    public static let endWindowSize = 800
}

public enum DoubaoFailure: Equatable, Sendable {
    case invalidParameter
    case emptyAudio
    case packetTimeout
    case badAudioFormat
    case serverBusy
    case auth
    case network
    case quota
    case protocolError(String)
    case other(code: Int, message: String)

    public var userMessage: String {
        switch self {
        case .invalidParameter:
            return "识别请求参数无效"
        case .emptyAudio:
            return "没有采集到音频"
        case .packetTimeout:
            return "音频发送超时"
        case .badAudioFormat:
            return "音频格式不被接受"
        case .serverBusy:
            return "识别服务繁忙"
        case .auth:
            return "鉴权失败，请检查 API Key 和资源 ID"
        case .network:
            return "网络连接失败"
        case .quota:
            return "额度或资源不足"
        case .protocolError:
            return "识别协议解析失败"
        case .other(let code, let message):
            if message.isEmpty {
                return "识别失败（\(code)）"
            }
            return "识别失败（\(code)）：\(message)"
        }
    }

    public static func fromServer(code: Int, message: String) -> DoubaoFailure {
        let lowered = message.lowercased()
        if lowered.contains("quota") || message.contains("额度") || message.contains("余额") || message.contains("资源包") {
            return .quota
        }
        switch code {
        case 45000001:
            return .invalidParameter
        case 45000002:
            return .emptyAudio
        case 45000081:
            return .packetTimeout
        case 45000151:
            return .badAudioFormat
        case 55000031:
            return .serverBusy
        case 401, 403:
            return .auth
        default:
            if code >= 55000000 && code < 56000000 {
                return .serverBusy
            }
            return .other(code: code, message: message)
        }
    }
}

public struct UtteranceUpdate: Equatable, Sendable {
    public var text: String
    public var startTime: Int?
    public var endTime: Int?
    public var definite: Bool
    public var source: String?

    public init(text: String, startTime: Int?, endTime: Int?, definite: Bool, source: String? = nil) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.definite = definite
        self.source = source
    }

    public var identity: String {
        if let startTime {
            return "t:\(startTime)"
        }
        return "x:\(text)"
    }
}

public struct ASRServerMessage: Equatable, Sendable {
    public var isLastPackage: Bool
    public var sequence: Int?
    public var event: Int?
    public var errorCode: Int?
    public var errorMessage: String?
    public var text: String?
    public var utterances: [UtteranceUpdate]
    public var logID: String?

    public init(
        isLastPackage: Bool = false,
        sequence: Int? = nil,
        event: Int? = nil,
        errorCode: Int? = nil,
        errorMessage: String? = nil,
        text: String? = nil,
        utterances: [UtteranceUpdate] = [],
        logID: String? = nil
    ) {
        self.isLastPackage = isLastPackage
        self.sequence = sequence
        self.event = event
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.text = text
        self.utterances = utterances
        self.logID = logID
    }

    public var failure: DoubaoFailure? {
        guard let errorCode, errorCode != 0, errorCode != 20000000 else { return nil }
        return DoubaoFailure.fromServer(code: errorCode, message: errorMessage ?? "")
    }
}

public enum DoubaoRequestBuilder {
    public static func object(uid: String, endWindowSize: Int = DoubaoEndpoint.endWindowSize) -> [String: Any] {
        [
            "user": ["uid": uid],
            "audio": [
                "format": "pcm",
                "codec": "raw",
                "rate": DoubaoEndpoint.sampleRate,
                "bits": 16,
                "channel": 1
            ],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": true,
                "enable_punc": true,
                "enable_ddc": false,
                "show_utterances": true,
                "enable_nonstream": true,
                "result_type": "full",
                "end_window_size": endWindowSize
            ]
        ]
    }

    public static func jsonData(uid: String, endWindowSize: Int = DoubaoEndpoint.endWindowSize) throws -> Data {
        try JSONSerialization.data(withJSONObject: object(uid: uid, endWindowSize: endWindowSize))
    }
}

public enum DoubaoHandshake {
    public static func headers(apiKey: String, resourceID: String, requestID: String) -> [String: String] {
        [
            "X-Api-Key": apiKey,
            "X-Api-Resource-Id": resourceID,
            "X-Api-Request-Id": requestID
        ]
    }

    public static func redact(_ text: String, secrets: [String]) -> String {
        var output = text
        for secret in secrets where secret.count >= 4 {
            output = output.replacingOccurrences(of: secret, with: "[redacted]")
        }
        return output
    }
}

public struct DoubaoSequence: Equatable, Sendable {
    public var next = 1

    public init() {}

    public mutating func nextFullRequest() -> Int {
        let current = next
        next += 1
        return current
    }

    public mutating func nextAudio(isLast: Bool) -> Int {
        let current = next
        if !isLast {
            next += 1
        }
        return current
    }
}

public enum DoubaoFrameEncoder {
    public static func fullClientRequest(sequence: Int, json: Data) -> Data? {
        guard let payload = Gzip.compress(json) else { return nil }
        return frame(
            messageType: 0b0001,
            flags: 0b0001,
            serialization: 0b0001,
            compression: 0b0001,
            sequence: sequence,
            payload: payload
        )
    }

    public static func audioPacket(sequence: Int, pcm: Data, isLast: Bool) -> Data? {
        guard let payload = Gzip.compress(pcm) else { return nil }
        let flags = isLast ? 0b0011 : 0b0001
        let signedSequence = isLast ? -abs(sequence) : sequence
        return frame(
            messageType: 0b0010,
            flags: flags,
            serialization: 0b0001,
            compression: 0b0001,
            sequence: signedSequence,
            payload: payload
        )
    }

    private static func frame(
        messageType: Int,
        flags: Int,
        serialization: Int,
        compression: Int,
        sequence: Int?,
        payload: Data
    ) -> Data {
        var data = Data(capacity: 8 + payload.count)
        data.append(UInt8((0b0001 << 4) | 0b0001))
        data.append(UInt8((messageType << 4) | flags))
        data.append(UInt8((serialization << 4) | compression))
        data.append(0)
        if let sequence {
            var seq = Int32(sequence).bigEndian
            data.append(Data(bytes: &seq, count: 4))
        }
        var size = UInt32(payload.count).bigEndian
        data.append(Data(bytes: &size, count: 4))
        data.append(payload)
        return data
    }
}

public enum DoubaoFrameDecoder {
    public static func decode(_ data: Data) -> ASRServerMessage? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        let headerSize = Int(bytes[0] & 0x0F)
        let messageType = Int(bytes[1] >> 4)
        let flags = Int(bytes[1] & 0x0F)
        let serialization = Int(bytes[2] >> 4)
        let compression = Int(bytes[2] & 0x0F)
        var offset = headerSize * 4
        guard offset <= bytes.count else { return nil }

        var message = ASRServerMessage()
        if flags & 0x01 != 0 {
            guard let sequence = readInt32(bytes, &offset) else { return nil }
            message.sequence = sequence
        }
        if flags & 0x02 != 0 {
            message.isLastPackage = true
        }
        if flags & 0x04 != 0 {
            guard let event = readInt32(bytes, &offset) else { return nil }
            message.event = event
        }

        if messageType == 0b1111 {
            guard let code = readInt32(bytes, &offset), let size = readUInt32(bytes, &offset) else { return nil }
            message.errorCode = code
            let payload = slice(bytes, &offset, count: Int(size))
            if let json = decodeJSON(payload, compression: compression, serialization: serialization) {
                fill(&message, from: json)
                if message.errorMessage == nil {
                    message.errorMessage = json["message"] as? String ?? json["error"] as? String
                }
            } else {
                message.errorMessage = decodeText(payload, compression: compression, serialization: serialization)
            }
            return message
        }

        guard messageType == 0b1001 else {
            return message
        }
        guard let size = readUInt32(bytes, &offset) else { return message }
        let payload = slice(bytes, &offset, count: Int(size))
        guard let json = decodeJSON(payload, compression: compression, serialization: serialization) else {
            return message
        }
        fill(&message, from: json)
        return message
    }

    private static func fill(_ message: inout ASRServerMessage, from json: [String: Any]) {
        if let code = json["code"] as? Int {
            message.errorCode = code
        } else if let code = json["code"] as? NSNumber {
            message.errorCode = code.intValue
        }
        if let text = json["message"] as? String {
            message.errorMessage = text
        }
        if let result = json["result"] as? [String: Any] {
            message.text = result["text"] as? String
            if let additions = result["additions"] as? [String: Any], let logID = additions["log_id"] as? String {
                message.logID = logID
            }
            message.utterances = utterances(from: result["utterances"] as? [[String: Any]] ?? [])
        } else if let results = json["result"] as? [[String: Any]] {
            message.text = results.compactMap { $0["text"] as? String }.joined()
            message.utterances = results.flatMap { item in
                if let nested = item["utterances"] as? [[String: Any]] {
                    return utterances(from: nested)
                }
                return utterances(from: [item])
            }
        }
    }

    private static func utterances(from raw: [[String: Any]]) -> [UtteranceUpdate] {
        raw.map { item in
            let additions = item["additions"] as? [String: Any]
            return UtteranceUpdate(
                text: item["text"] as? String ?? "",
                startTime: intValue(item["start_time"]),
                endTime: intValue(item["end_time"]),
                definite: item["definite"] as? Bool ?? false,
                source: additions?["source"] as? String
            )
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func decodeJSON(_ payload: Data, compression: Int, serialization: Int) -> [String: Any]? {
        guard let data = inflate(payload, compression: compression) else { return nil }
        guard serialization == 0b0001 || serialization == 0 else {
            return nil
        }
        guard !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func decodeText(_ payload: Data, compression: Int, serialization: Int) -> String? {
        guard let data = inflate(payload, compression: compression) else { return nil }
        if serialization == 0b0001, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = json["message"] as? String { return message }
            if let error = json["error"] as? String { return error }
        }
        return String(data: data, encoding: .utf8)
    }

    private static func inflate(_ payload: Data, compression: Int) -> Data? {
        if compression == 0b0001 {
            return Gzip.decompress(payload)
        }
        return payload
    }

    private static func readInt32(_ bytes: [UInt8], _ offset: inout Int) -> Int? {
        guard offset + 4 <= bytes.count else { return nil }
        let value = Int32(bytes[offset]) << 24
            | Int32(bytes[offset + 1]) << 16
            | Int32(bytes[offset + 2]) << 8
            | Int32(bytes[offset + 3])
        offset += 4
        return Int(value)
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: inout Int) -> UInt32? {
        guard offset + 4 <= bytes.count else { return nil }
        let value = UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
        offset += 4
        return value
    }

    private static func slice(_ bytes: [UInt8], _ offset: inout Int, count: Int) -> Data {
        let available = max(0, bytes.count - offset)
        let take = min(count, available)
        let data = Data(bytes[offset..<(offset + take)])
        offset += take
        return data
    }
}
