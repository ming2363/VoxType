import AppKit
import ApplicationServices
import Foundation
import VoxTypeCore

final class SessionController {
    let model: AppModel
    var onStatus: ((String, String) -> Void)?

    private let inserter = TextInserter()
    private var gate = SessionGate() {
        didSet { model.updateSessionPhase(gate.phase) }
    }
    private var audio: AudioCapture?
    private var asr: DoubaoASRClient?
    private var reducer = RecognitionReducer()
    private var writer = DictationWriteModel(route: .releaseInsert)
    private var sessionID = ""
    private var element: AXUIElement?
    private var targetPID: pid_t = 0
    private var fallback: Fallback = .none
    private var handshakeReady = false
    private var lastPacketSent = false
    private var stoppedWriting = false
    private var cleanupDone = false
    private var modifiers = ModifierMask()
    private var pendingSynthetic: String?
    private var callbacks = SessionCallbackGate()
    private var writeFailed = false
    private var pumpItem: DispatchWorkItem?
    private var timeoutItem: DispatchWorkItem?
    private var deliveryItem: DispatchWorkItem?
    private var focusRestoreAttempts = 0
    private var observer: NSObjectProtocol?
    private var logID: String?
    private var acceptSessionID = ""
    private var focusProbeID: UUID?
    private var focusProbeItem: DispatchWorkItem?

    private enum Fallback {
        case none
        case unicode
    }

    init(model: AppModel) {
        self.model = model
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.noteFocusChange(notification)
        }
    }

    func hotkeyDown(isRepeat: Bool) {
        let action = gate.keyDown(isRepeat: isRepeat)
        switch action {
        case .beginSession:
            begin()
        case .ignoreBusy:
            publish("请稍后", "收尾尚未完成，本次触发已忽略")
        case .ignoreRepeat, .none, .beginFinish, .cancelStartAndFinish, .enterRecording, .alreadyStopped:
            break
        }
    }

    func hotkeyUp() {
        if focusProbeID != nil {
            cancelFocusProbe()
            gate.finished()
            publish("空闲", "已取消启动")
            return
        }
        let action = gate.keyUp()
        if action == .beginFinish || action == .cancelStartAndFinish {
            beginFinish()
            return
        }
        if gate.phase == .idle {
            deliverOverlayIfMissing()
        }
    }

    func userTyped() {
        guard gate.phase == .starting || gate.phase == .recording || gate.phase == .finishing || pendingSynthetic != nil || inserter.hasPendingDelivery else { return }
        stoppedWriting = true
        inserter.invalidate()
        pendingSynthetic = nil
        if gate.keyHeld {
            publish("录音", "检测到其他按键，已暂停写入，松开快捷键后结束")
            return
        }
        writeFailed = true
        publish("已停止", "检测到手动输入，已停止自动写入")
        let action = gate.interrupt()
        if action == .beginFinish || action == .cancelStartAndFinish {
            beginFinish()
        }
    }

    var sessionActive: Bool {
        gate.phase != .idle || pendingSynthetic != nil || inserter.hasPendingDelivery
    }

    func modifiersChanged(_ mask: ModifierMask) {
        modifiers = mask
        flushSyntheticIfPossible()
    }

    private func begin() {
        model.overlayText = ""
        guard let hotkey = model.hotkey, hotkey.isConfigured else {
            abortStart("未设置", "请先在设置中录制快捷键")
            return
        }
        guard model.apiKey() != nil else {
            abortStart("无密钥", "请先在设置中保存豆包 API Key")
            return
        }
        model.refreshPermissions(prompt: true)
        guard model.microphoneGranted else {
            abortStart("无麦克风", "需要麦克风权限后才能录音")
            return
        }
        guard model.accessibilityGranted else {
            abortStart("无辅助功能", "需要辅助功能权限后才能定位输入框")
            return
        }
        guard model.listenGranted else {
            abortStart("无输入监控", "需要输入监控权限后才能接收快捷键松开")
            return
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != getpid() else {
            abortStart("无法输入", "请先点击目标应用中的输入框")
            return
        }
        let id = UUID()
        focusProbeID = id
        probeFocus(pid: pid, id: id, attempt: 0)
    }

    private func probeFocus(pid: pid_t, id: UUID, attempt: Int) {
        guard focusProbeID == id, gate.phase == .starting, gate.keyHeld else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            abortStart("无法输入", "焦点应用已切换，已取消启动")
            return
        }
        switch inserter.probe(targetPID: pid) {
        case .focusUnavailable(let reason):
            guard attempt < 3 else {
                abortStart("无法输入", reason)
                return
            }
            if attempt == 0 {
                FocusedElementReader.enableElectronAccessibility(for: pid)
            }
            let work = DispatchWorkItem { [weak self] in
                self?.probeFocus(pid: pid, id: id, attempt: attempt + 1)
            }
            focusProbeItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        case .blocked(let reason):
            abortStart("无法输入", reason)
        case .live(let element, let pid):
            cancelFocusProbe()
            startSession(element: element, pid: pid, route: .liveReplace, fallback: .none)
        case .sentence(let element, let pid):
            cancelFocusProbe()
            startSession(element: element, pid: pid, route: .sentenceInsert, fallback: .none)
        case .unicode(let element, let pid):
            cancelFocusProbe()
            startSession(element: element, pid: pid, route: .releaseInsert, fallback: .unicode)
        }
    }

    private func startSession(element: AXUIElement, pid: pid_t, route: WriteRoute, fallback: Fallback) {
        cleanupDone = false
        stoppedWriting = false
        writeFailed = false
        focusRestoreAttempts = 0
        handshakeReady = false
        lastPacketSent = false
        pendingSynthetic = nil
        logID = nil
        timeoutItem?.cancel()
        pumpItem?.cancel()
        cancelLocalDelivery()
        sessionID = UUID().uuidString
        acceptSessionID = sessionID
        callbacks.begin(sessionID)
        reducer = RecognitionReducer()
        writer = DictationWriteModel(route: route)
        self.element = element
        targetPID = pid
        self.fallback = fallback
        inserter.prepare(element)
        publish("启动", "正在打开麦克风和识别连接")

        let capture = AudioCapture()
        let eventID = sessionID
        capture.onOverflow = { [weak self] in
            self?.failIfCurrent(eventID, "缓冲已满", "连接前音频超过 3 秒，已结束本次会话")
        }
        capture.onStarted = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.callbacks.accepts(eventID) else { return }
                self.micReady()
            }
        }
        audio = capture
        do {
            try capture.start()
        } catch {
            abortStart("麦克风失败", "无法启动麦克风")
            return
        }
        guard let key = model.apiKey() else {
            abortStart("无密钥", "请先在设置中保存豆包 API Key")
            return
        }
        let client = DoubaoASRClient(sessionID: sessionID)
        client.onLogID = { [weak self] logID in
            guard let self, self.callbacks.accepts(eventID) else { return }
            self.logID = logID
        }
        client.onHandshake = { [weak self] in
            self?.handshakeArrived(eventID: eventID)
        }
        client.onMessage = { [weak self] message in
            self?.handle(message, eventSessionID: eventID)
        }
        client.onFailure = { [weak self] failure in
            guard let self else { return }
            if self.gate.keyHeld && !self.handshakeReady {
                self.publish("录音", "识别连接中断，仍在录音")
                return
            }
            self.failIfCurrent(eventID, "识别失败", failure.userMessage)
        }
        asr = client
        client.connect(apiKey: key, resourceID: model.resourceID, uid: model.uid)
        let work = DispatchWorkItem { [weak self] in
            self?.connectionTimedOut(eventID: eventID)
        }
        timeoutItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func micReady() {
        let action = gate.micReady()
        if action == .cancelStartAndFinish {
            beginFinish()
            return
        }
        if action == .enterRecording {
            publish("录音", "正在录音")
        }
    }

    private func handshakeArrived(eventID: String) {
        guard callbacks.handshake(eventID) else { return }
        timeoutItem?.cancel()
        handshakeReady = true
        if gate.phase == .recording {
            publish("录音", "识别已连接")
        }
        schedulePump(delay: 0.02, eventID: eventID)
    }

    private func connectionTimedOut(eventID: String) {
        guard acceptSessionID == eventID, !handshakeReady, !cleanupDone else { return }
        if gate.keyHeld {
            publish("录音", "识别连接较慢，仍在录音")
            let work = DispatchWorkItem { [weak self] in
                self?.connectionTimedOut(eventID: eventID)
            }
            timeoutItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
            return
        }
        guard callbacks.timeout(eventID) else { return }
        fail("连接超时", "识别连接未在时限内就绪")
    }

    private func failIfCurrent(_ eventID: String, _ short: String, _ detail: String) {
        guard callbacks.failure(eventID) else { return }
        fail(short, detail)
    }

    private func beginFinish() {
        if focusProbeID != nil {
            cancelFocusProbe()
            gate.finished()
            publish("空闲", "已取消启动")
            return
        }
        guard gate.phase == .finishing, !cleanupDone else { return }
        audio?.stopCapture()
        if !writeFailed {
            publish("收尾", "正在等待最终识别")
        }
        if handshakeReady {
            schedulePump(delay: AudioSendScheduler.backlogWait, eventID: acceptSessionID)
        } else {
            timeoutItem?.cancel()
            let eventID = acceptSessionID
            let work = DispatchWorkItem { [weak self] in
                self?.connectionTimedOut(eventID: eventID)
            }
            timeoutItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }
    }

    private func schedulePump(delay: Double, eventID: String) {
        pumpItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.callbacks.accepts(eventID) else { return }
            self.pump()
        }
        pumpItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func pump() {
        guard !cleanupDone, let audio, let asr else { return }
        let action = AudioSendScheduler.decide(
            phase: gate.phase,
            handshakeReady: handshakeReady,
            lastPacketSent: lastPacketSent,
            pendingBytes: audio.pendingBytes(),
            conversionPending: audio.conversionPending(),
            packetBytes: DoubaoEndpoint.packetBytes
        )
        switch action {
        case .stop:
            return
        case .wait(let delay):
            schedulePump(delay: delay, eventID: acceptSessionID)
        case .send(let isLast):
            let bytes = isLast ? audio.pendingBytes() : DoubaoEndpoint.packetBytes
            let chunk = audio.pop(maxBytes: max(bytes, 0))
            if isLast {
                lastPacketSent = true
            }
            asr.sendAudio(chunk, isLast: isLast)
            if isLast {
                armFinishTimeout()
            } else {
                schedulePump(delay: AudioSendScheduler.backlogWait, eventID: acceptSessionID)
            }
        }
    }

    private func armFinishTimeout() {
        timeoutItem?.cancel()
        let eventID = acceptSessionID
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.callbacks.accepts(eventID) else { return }
            self.finish(incomplete: true, detail: "收尾超时，未完成句末纠正")
        }
        timeoutItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DoubaoEndpoint.finishTimeoutSeconds, execute: work)
    }

    private func handle(_ message: ASRServerMessage, eventSessionID: String) {
        guard SessionCallbackFilter.shouldApply(
            activeSessionID: acceptSessionID,
            eventSessionID: eventSessionID,
            cleanedUp: cleanupDone
        ) else { return }
        if let failure = message.failure {
            fail("识别失败", failure.userMessage)
            return
        }
        let result = reducer.apply(
            activeSessionID: acceptSessionID,
            eventSessionID: eventSessionID,
            utterances: message.utterances,
            fullText: message.utterances.isEmpty ? message.text : nil,
            isFinalPacket: message.isLastPackage,
            forcedFinalize: false
        )
        guard case .updated(let snapshot) = result else { return }
        model.remember(snapshot.displayText)
        model.focusRect = inserter.focusRect()
        model.updateOverlay(snapshot.displayText)
        if !stoppedWriting {
            let allowed = inserter.insertionStillAllowed()
            if !allowed {
                invalidateWriting(reason: "光标或焦点已变化，已停止写入")
            } else {
                perform(writer.apply(snapshot: snapshot, focusValid: true))
            }
        }
        if message.isLastPackage && gate.phase == .finishing {
            finish(incomplete: snapshot.correctionIncomplete, detail: snapshot.correctionIncomplete ? "已输入，句末纠正未完成" : "已完成")
        }
    }

    private func finish(incomplete: Bool, detail: String) {
        guard !cleanupDone else { return }
        if !stoppedWriting {
            let snapshot = reducer.snapshot
            model.remember(snapshot.displayText)
            let allowed = inserter.insertionStillAllowed()
            if !allowed {
                invalidateWriting(reason: "光标或焦点已变化，已停止写入")
            } else {
                perform(writer.finish(snapshot: snapshot, focusValid: true))
            }
        }
        ensureCommitted(reducer.snapshot.displayText)
        releaseASRResources()
        gate.finished()
        if let status = FinishStatus.resolve(
            writeFailed: writeFailed || stoppedWriting,
            pendingDelivery: inserter.hasPendingDelivery,
            waitingModifiers: pendingSynthetic != nil && SyntheticInputPolicy.mustDefer(held: modifiers),
            incomplete: incomplete,
            successDetail: detail
        ) {
            publish(status.short, status.detail)
        }
    }

    private func perform(_ plan: WritePlan) {
        if plan.ops.contains(.stop) {
            stoppedWriting = true
            publish("已停止", "焦点变化或结果无法对齐，已停止写入")
            return
        }
        if fallback != .none {
            let text = plan.ops.compactMap { op -> String? in
                if case .insert(let value) = op { return value }
                return nil
            }.joined()
            guard !text.isEmpty else { return }
            pendingSynthetic = (pendingSynthetic ?? "") + text
            flushSyntheticIfPossible()
            return
        }
        for op in plan.ops {
            if stoppedWriting { return }
            switch op {
            case .replaceLive(let text):
                let outcome = inserter.replaceLive(text)
                if outcome != .applied, inserter.commit(text) {
                    break
                }
                apply(outcome)
            case .lockLive:
                inserter.lockLive()
            case .insert(let text):
                let outcome = inserter.insert(text)
                if outcome != .applied, inserter.commit(text) {
                    break
                }
                apply(outcome)
            case .replaceLastCommitted(let text):
                apply(inserter.replaceLastCommitted(text))
            case .stop:
                stoppedWriting = true
            }
        }
    }

    private func apply(_ outcome: WriteOutcome) {
        switch outcome {
        case .applied:
            break
        case .focusLost:
            markWriteFailed("焦点已变化，未把文字写入新位置")
        case .uncertain, .failedClear:
            markWriteFailed("写入结果不确定，已停止，可复制最近结果")
        }
    }

    private func flushSyntheticIfPossible() {
        guard !inserter.hasPendingDelivery else { return }
        guard let text = pendingSynthetic, !text.isEmpty else { return }
        guard !SyntheticInputPolicy.mustDefer(held: modifiers) else { return }
        if targetPID != 0,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID,
           focusRestoreAttempts < 3 {
            focusRestoreAttempts += 1
            NSRunningApplication(processIdentifier: targetPID)?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.flushSyntheticIfPossible()
            }
            return
        }
        focusRestoreAttempts = 0
        guard !stoppedWriting, inserter.acceptsTargetApp() else {
            pendingSynthetic = nil
            invalidateWriting(reason: "焦点已变化，未把文字写入新位置")
            return
        }
        guard model.postGranted else {
            publish("无法输入", "需要辅助功能中的事件投递权限")
            return
        }
        pendingSynthetic = nil
        // Never use the system clipboard for automatic dictation delivery.
        if inserter.beginUnicode(text) {
            scheduleDeliveryPoll()
        } else {
            invalidateWriting(reason: "无法直接输入文字，已保留最近结果")
        }
    }

    private func scheduleDeliveryPoll() {
        deliveryItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pollDelivery()
        }
        deliveryItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    private func pollDelivery() {
        guard inserter.hasPendingDelivery else { return }
        guard let observation = inserter.pollDelivery() else {
            scheduleDeliveryPoll()
            return
        }
        switch observation {
        case .success:
            publish(gate.phase == .idle ? "空闲" : model.statusShort, gate.phase == .idle ? "已输入" : model.statusDetail)
        case .unchanged, .uncertain, .focusLost, .editedByUser:
            // A slow field may have accepted the first event: do not post it again.
            invalidateWriting(reason: "无法确认直接输入，已停止；剪贴板未改动，可手动复制最近结果")
        }
    }

    private func markWriteFailed(_ reason: String) {
        writeFailed = true
        stoppedWriting = true
        publish("已停止", reason)
    }

    private func invalidateWriting(reason: String) {
        stoppedWriting = true
        inserter.invalidate()
        pendingSynthetic = nil
        if gate.keyHeld {
            publish("录音", "焦点变化，已暂停写入，松开快捷键后结束")
            return
        }
        markWriteFailed(reason)
        let action = gate.interrupt()
        if action == .beginFinish || action == .cancelStartAndFinish {
            beginFinish()
        }
    }

    private func noteFocusChange(_ notification: Notification) {
        guard sessionActive else { return }
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.processIdentifier == getpid() {
            return
        }
        if !inserter.insertionStillAllowed() {
            invalidateWriting(reason: "焦点已变化，已停止写入")
        }
    }

    private func deliverOverlayIfMissing() {
        let text = InsertedText.sanitized(model.overlayText)
        guard !text.isEmpty, !inserter.contains(text) else { return }
        if inserter.hasPendingDelivery || pendingSynthetic != nil { return }
        guard inserter.bindCurrentFocus() else { return }
        if inserter.commit(text) { return }
        stoppedWriting = false
        pendingSynthetic = text
        flushSyntheticIfPossible()
    }

    private func ensureCommitted(_ text: String) {
        let text = InsertedText.sanitized(text)
        guard !text.isEmpty, !inserter.contains(text) else { return }
        if inserter.hasPendingDelivery || pendingSynthetic != nil { return }
        if inserter.commit(text) { return }
        guard inserter.acceptsTargetApp() else { return }
        stoppedWriting = false
        if pendingSynthetic == nil {
            pendingSynthetic = text
        }
        flushSyntheticIfPossible()
    }

    private func abortStart(_ short: String, _ detail: String) {
        cancelFocusProbe()
        audio?.discard()
        audio = nil
        asr?.close()
        asr = nil
        gate.finished()
        publish(short, detail)
    }

    private func fail(_ short: String, _ detail: String) {
        let text = reducer.snapshot.displayText
        if !text.isEmpty {
            model.remember(text)
            _ = inserter.commit(text)
        }
        releaseResources()
        gate.finished()
        publish(short, detail)
    }

    private func releaseASRResources() {
        guard !cleanupDone else { return }
        cleanupDone = true
        callbacks.releaseASR()
        pumpItem?.cancel()
        timeoutItem?.cancel()
        acceptSessionID = ""
        audio?.discard()
        audio = nil
        asr?.close()
        asr = nil
        _ = logID
    }

    private func cancelLocalDelivery() {
        deliveryItem?.cancel()
        deliveryItem = nil
        pendingSynthetic = nil
        inserter.invalidate()
    }

    private func releaseResources() {
        cancelFocusProbe()
        releaseASRResources()
        cancelLocalDelivery()
        element = nil
    }

    private func cancelFocusProbe() {
        focusProbeID = nil
        focusProbeItem?.cancel()
        focusProbeItem = nil
    }

    private func publish(_ short: String, _ detail: String) {
        model.focusRect = inserter.focusRect()
        model.updateStatus(short: short, detail: detail)
        onStatus?(short, detail)
    }
}
