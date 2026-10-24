import Foundation
import VoxTypeCore

final class DoubaoASRClient {
    var onHandshake: (() -> Void)?
    var onMessage: ((ASRServerMessage) -> Void)?
    var onFailure: ((DoubaoFailure) -> Void)?
    var onLogID: ((String) -> Void)?

    private let sendQueue: DispatchQueue
    private let stateLock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var sequence = DoubaoSequence()
    private var closed = false
    private var handshakeSent = false
    private var apiKey = ""
    let boundSessionID: String
    private(set) var closeCompleted = false

    init(sessionID: String, sendQueue: DispatchQueue = DispatchQueue(label: "app.voxtype.asr.send")) {
        self.boundSessionID = sessionID
        self.sendQueue = sendQueue
    }

    func connect(apiKey: String, resourceID: String, uid: String) {
        stateLock.lock()
        closed = false
        handshakeSent = false
        sequence = DoubaoSequence()
        self.apiKey = apiKey
        stateLock.unlock()

        guard let url = URL(string: DoubaoEndpoint.webSocketURL) else {
            onFailure?(.protocolError("地址无效"))
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let headers = DoubaoHandshake.headers(
            apiKey: apiKey,
            resourceID: resourceID,
            requestID: UUID().uuidString
        )
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        task.resume()
        receive()
        sendQueue.async { [weak self] in
            self?.sendFullRequest(uid: uid)
        }
    }

    func sendAudio(_ pcm: Data, isLast: Bool) {
        sendQueue.async { [weak self] in
            self?.sendAudioLocked(pcm, isLast: isLast)
        }
    }

    func close() {
        stateLock.lock()
        if closed {
            stateLock.unlock()
            return
        }
        closed = true
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        self.apiKey = ""
        stateLock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        DeferredClose.enqueue(on: sendQueue, owner: self) {
            self.closeCompleted = true
        }
    }

    private func sendFullRequest(uid: String) {
        stateLock.lock()
        let closed = self.closed
        let seq = sequence.nextFullRequest()
        stateLock.unlock()
        guard !closed, let task else { return }
        guard let json = try? DoubaoRequestBuilder.jsonData(uid: uid),
              let frame = DoubaoFrameEncoder.fullClientRequest(sequence: seq, json: json) else {
            DispatchQueue.main.async { [weak self] in self?.onFailure?(.protocolError("请求编码失败")) }
            return
        }
        task.send(.data(frame)) { [weak self] error in
            if let error {
                self?.fail(.network, detail: error.localizedDescription)
            }
        }
    }

    private func sendAudioLocked(_ pcm: Data, isLast: Bool) {
        stateLock.lock()
        let closed = self.closed
        let seq = sequence.nextAudio(isLast: isLast)
        stateLock.unlock()
        guard !closed, let task else { return }
        guard let frame = DoubaoFrameEncoder.audioPacket(sequence: seq, pcm: pcm, isLast: isLast) else {
            fail(.protocolError("音频封包失败"), detail: "")
            return
        }
        task.send(.data(frame)) { [weak self] error in
            if let error {
                self?.fail(.network, detail: error.localizedDescription)
            }
        }
    }

    private func receive() {
        stateLock.lock()
        let task = self.task
        let closed = self.closed
        stateLock.unlock()
        guard !closed, let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handle(message, task: task)
                self.receive()
            case .failure(let error):
                self.stateLock.lock()
                let closed = self.closed
                self.stateLock.unlock()
                if !closed {
                    self.fail(self.map(error, task: task), detail: error.localizedDescription)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, task: URLSessionWebSocketTask) {
        if let response = task.response as? HTTPURLResponse,
           let logID = response.value(forHTTPHeaderField: "X-Tt-Logid") {
            DispatchQueue.main.async { [weak self] in self?.onLogID?(logID) }
        }
        guard case .data(let data) = message, let parsed = DoubaoFrameDecoder.decode(data) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.handshakeSent {
                self.handshakeSent = true
                self.onHandshake?()
            }
            self.onMessage?(parsed)
        }
    }

    private func map(_ error: Error, task: URLSessionWebSocketTask) -> DoubaoFailure {
        if let response = task.response as? HTTPURLResponse, response.statusCode == 401 || response.statusCode == 403 {
            return .auth
        }
        return .network
    }

    private func fail(_ failure: DoubaoFailure, detail: String) {
        stateLock.lock()
        let key = apiKey
        let closed = self.closed
        stateLock.unlock()
        if closed { return }
        let redacted = DoubaoHandshake.redact(detail, secrets: [key])
        _ = redacted
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?(failure)
        }
    }
}
