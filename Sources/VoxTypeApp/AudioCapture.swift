import AVFoundation
import Foundation
import VoxTypeCore

final class AudioCapture {
    var onOverflow: (() -> Void)?
    var onStarted: (() -> Void)?

    private let engine = AVAudioEngine()
    private let convertQueue = DispatchQueue(label: "app.voxtype.audio")
    private let lock = NSLock()
    private var pcm = BoundedPCMBuffer(capacity: DoubaoEndpoint.connectBufferBytes)
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var running = false
    private var pendingCopies = 0

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.noInput
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw AudioCaptureError.format
        }
        self.targetFormat = target
        self.converter = converter
        lock.lock()
        pcm = BoundedPCMBuffer(capacity: DoubaoEndpoint.connectBufferBytes)
        pendingCopies = 0
        lock.unlock()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.enqueue(buffer)
        }
        engine.prepare()
        try engine.start()
        running = true
        onStarted?()
    }

    func stopCapture() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    func pendingBytes() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return pcm.count
    }

    func conversionPending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingCopies > 0
    }

    func pop(maxBytes: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        return pcm.pop(maxBytes: maxBytes)
    }

    func discard() {
        stopCapture()
        lock.lock()
        pcm.removeAll()
        converter = nil
        targetFormat = nil
        lock.unlock()
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if pendingCopies > 80 {
            lock.unlock()
            return
        }
        pendingCopies += 1
        lock.unlock()
        guard let copy = Self.copy(buffer) else {
            lock.lock()
            pendingCopies -= 1
            lock.unlock()
            return
        }
        convertQueue.async { [weak self] in
            self?.convert(copy)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) {
        defer {
            lock.lock()
            pendingCopies = max(0, pendingCopies - 1)
            lock.unlock()
        }
        guard let converter, let targetFormat else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(capacity, 1)) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let channel = output.int16ChannelData?[0] else { return }
        let data = Data(bytes: channel, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
        lock.lock()
        if !pcm.append(data) {
            _ = pcm.pop(maxBytes: data.count)
            _ = pcm.append(data)
        }
        lock.unlock()
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channels {
                memcpy(destination[channel], source[channel], frames * MemoryLayout<Float>.size)
            }
            return copy
        }
        if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<channels {
                memcpy(destination[channel], source[channel], frames * MemoryLayout<Int16>.size)
            }
            return copy
        }
        return nil
    }
}

enum AudioCaptureError: Error {
    case noInput
    case format
}
