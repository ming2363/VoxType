// SPDX-License-Identifier: Apache-2.0
// Compiled with the application's actual DoubaoASRClient and VoxTypeCore.
// No microphone, accessibility input, clipboard or preferences are used.
import Foundation
import VoxTypeCore

final class StreamProbe {
    let client = DoubaoASRClient(sessionID: "public-benchmark")
    let pcm: Data
    var reducer = RecognitionReducer()
    var connectedAt: TimeInterval = 0
    var audioStartedAt: TimeInterval?
    var firstTextAt: TimeInterval?
    var lastSubmittedAt: TimeInterval?
    var handshakeMS: Double?
    var completed = false

    init(pcm: Data) { self.pcm = pcm }
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start(key: String) {
        connectedAt = now()
        client.onHandshake = { [weak self] in self?.stream() }
        client.onMessage = { [weak self] message in self?.receive(message) }
        client.onFailure = { [weak self] failure in
            // Do not serialize arbitrary server/network error strings or request headers.
            let kind: String
            switch failure {
            case .auth: kind = "authentication"
            case .quota: kind = "quota"
            case .network: kind = "network"
            default: kind = "service_or_protocol"
            }
            self?.finish(error: kind)
        }
        client.connect(apiKey: key, resourceID: DoubaoEndpoint.resourceDuration, uid: "voxtype-public-benchmark")
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.audioStartedAt == nil else { return }
            self.finish(error: "handshake_timeout")
        }
    }

    func stream() {
        guard audioStartedAt == nil, !completed else { return }
        handshakeMS = (now() - connectedAt) * 1000
        audioStartedAt = now()
        // Pace chunks by the amount of captured audio they represent, not as a file upload.
        let epoch = DispatchTime.now()
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + DoubaoEndpoint.packetBytes, pcm.count)
            let chunk = pcm.subdata(in: offset..<end)
            let isLast = end == pcm.count
            let delay = Double(end) / Double(DoubaoEndpoint.sampleRate * 2)
            DispatchQueue.main.asyncAfter(deadline: epoch + delay) { [weak self] in
                guard let self, !self.completed else { return }
                if isLast { self.lastSubmittedAt = self.now() }
                self.client.sendAudio(chunk, isLast: isLast)
                if isLast {
                    DispatchQueue.main.asyncAfter(deadline: .now() + DoubaoEndpoint.finishTimeoutSeconds) { [weak self] in
                        self?.finish(error: "final_timeout")
                    }
                }
            }
            offset = end
        }
    }

    func receive(_ message: ASRServerMessage) {
        guard !completed else { return }
        if message.failure != nil { finish(error: "server_error"); return }
        _ = reducer.apply(activeSessionID: "probe", eventSessionID: "probe",
                          utterances: message.utterances,
                          fullText: message.utterances.isEmpty ? message.text : nil,
                          isFinalPacket: message.isLastPackage, forcedFinalize: false)
        if !reducer.snapshot.displayText.isEmpty && firstTextAt == nil { firstTextAt = now() }
        if message.isLastPackage {
            finish(error: lastSubmittedAt == nil ? "early_final" : nil)
        }
    }

    func finish(error: String?) {
        guard !completed else { return }
        completed = true
        let ended = now()
        client.close()
        var result: [String: Any] = [
            "ok": error == nil,
            "transcript": reducer.snapshot.displayText,
            "audio_seconds": Double(pcm.count) / 32000,
            "handshake_ms": handshakeMS as Any? ?? NSNull(),
            "first_text_ms": NSNull(), "final_tail_ms": NSNull()
        ]
        if let start = audioStartedAt, let first = firstTextAt { result["first_text_ms"] = (first - start) * 1000 }
        if let last = lastSubmittedAt { result["final_tail_ms"] = (ended - last) * 1000 }
        if let error { result["error"] = error }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
        exit(error == nil ? 0 : 2)
    }
}

// Key arrives on a pipe, never via an argument, environment variable or file.
let key = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
guard CommandLine.arguments.count == 2, !key.isEmpty,
      let pcm = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
      !pcm.isEmpty, pcm.count % 2 == 0 else {
    fputs("Invalid benchmark input (no credential values are logged).\n", stderr)
    exit(1)
}
let probe = StreamProbe(pcm: pcm)
probe.start(key: key)
RunLoop.main.run()
