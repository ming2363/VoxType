import Foundation

var failures: [String] = []

func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures.append(message)
        fputs("FAIL \(message)\n", stderr)
    }
}

func runChecks() throws {
    for phase in [SessionPhase.starting, .recording, .finishing] {
        for status in ["空闲", "已停止", "无权限", "确认输入", "连接提示"] {
            let display = FloatingStatusDisplay(phase: phase, status: status)
            check(display.status != nil && !display.autoHides, "活动会话不因提示文字变化而隐藏")
        }
    }
    check(FloatingStatusDisplay(phase: .recording, status: "已停止") == .persistent("录音"), "文字写入停止不等于录音停止")
    check(FloatingStatusDisplay(phase: .idle, status: "空闲") == .hidden, "空闲隐藏")
    check(FloatingStatusDisplay(phase: .idle, status: "确认输入") == .persistent("确认输入"), "等待投递确认不自动隐藏")
    check(FloatingStatusDisplay(phase: .idle, status: "等待松开") == .persistent("等待松开"), "等待松开不自动隐藏")
    check(FloatingStatusDisplay(phase: .idle, status: "无法输入").autoHides, "空闲错误提示允许自动隐藏")

    let headers = DoubaoHandshake.headers(apiKey: "secret-value", resourceID: DoubaoEndpoint.resourceDuration, requestID: "req-1")
    check(Set(headers.keys) == ["X-Api-Key", "X-Api-Resource-Id", "X-Api-Request-Id"], "握手头")
    check(headers["X-Api-Sequence"] == nil, "不发送旧版序号头")
    check(DoubaoHandshake.redact("secret-value failed", secrets: ["secret-value"]) == "[redacted] failed", "密钥脱敏")

    let object = DoubaoRequestBuilder.object(uid: "voxtype")
    let audio = object["audio"] as? [String: Any]
    let request = object["request"] as? [String: Any]
    check(audio?["format"] as? String == "pcm", "pcm")
    check(audio?["language"] == nil, "不传 language")
    check(request?["model_name"] as? String == "bigmodel", "model")
    check(request?["enable_nonstream"] as? Bool == true, "二遍")
    check(request?["show_utterances"] as? Bool == true, "分句")
    check(request?["enable_punc"] as? Bool == true, "标点")
    check(request?["enable_itn"] as? Bool == true, "itn")
    check(request?["enable_ddc"] as? Bool == false, "关闭顺滑")
    check(request?["result_type"] as? String == "full", "全量")
    check(request?["enable_accelerate_text"] == nil, "不加速")

    let json = try DoubaoRequestBuilder.jsonData(uid: "u")
    let full = try unwrap(DoubaoFrameEncoder.fullClientRequest(sequence: 1, json: json))
    check(Array(full.prefix(8)) == [0x11, 0x11, 0x11, 0x00, 0x00, 0x00, 0x00, 0x01], "首包头")
    let audioFrame = try unwrap(DoubaoFrameEncoder.audioPacket(sequence: 2, pcm: Data([1, 2, 3, 4]), isLast: false))
    check(Array(audioFrame.prefix(8)) == [0x11, 0x21, 0x11, 0x00, 0x00, 0x00, 0x00, 0x02], "音频头与官方默认序列化标志一致")
    let last = try unwrap(DoubaoFrameEncoder.audioPacket(sequence: 3, pcm: Data([9]), isLast: true))
    check(Array(last.prefix(4)) == [0x11, 0x23, 0x11, 0x00], "结束包标志")
    check(Int32(bigEndian: last.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: Int32.self) }) == -3, "结束包负序号")

    var sequence = DoubaoSequence()
    check(sequence.nextFullRequest() == 1 && sequence.nextAudio(isLast: false) == 2 && sequence.nextAudio(isLast: true) == 3, "序号")

    let payload: [String: Any] = [
        "result": [
            "text": "你好",
            "additions": ["log_id": "log-1"],
            "utterances": [["text": "你好", "start_time": 0, "end_time": 200, "definite": false]]
        ]
    ]
    let body = try JSONSerialization.data(withJSONObject: payload)
    let compressed = try unwrap(Gzip.compress(body))
    var frame = Data([0x11, 0x91, 0x11, 0x00, 0x00, 0x00, 0x00, 0x02])
    var size = UInt32(compressed.count).bigEndian
    frame.append(Data(bytes: &size, count: 4))
    frame.append(compressed)
    let message = try unwrap(DoubaoFrameDecoder.decode(frame))
    check(message.text == "你好" && message.logID == "log-1" && message.utterances.first?.definite == false, "解码快照")
    var lastFlag = frame
    lastFlag[1] = 0x93
    check(try unwrap(DoubaoFrameDecoder.decode(lastFlag)).isLastPackage, "is_last_package")

    let errorJSON = try JSONSerialization.data(withJSONObject: ["message": "bad"])
    var error = Data([0x11, 0xF0, 0x10, 0x00])
    var code = Int32(45000001).bigEndian
    var errorSize = UInt32(errorJSON.count).bigEndian
    error.append(Data(bytes: &code, count: 4))
    error.append(Data(bytes: &errorSize, count: 4))
    error.append(errorJSON)
    check(try unwrap(DoubaoFrameDecoder.decode(error)).failure == .invalidParameter, "错误码")

    let source = Data("你好 world".utf8)
    let gzipped = try unwrap(Gzip.compress(source))
    check(Array(gzipped.prefix(2)) == [0x1F, 0x8B] && Gzip.decompress(gzipped) == source, "gzip")

    var reducer = RecognitionReducer()
    func utterance(_ text: String, _ start: Int, _ definite: Bool) -> UtteranceUpdate {
        UtteranceUpdate(text: text, startTime: start, endTime: start + 100, definite: definite)
    }
    _ = reducer.apply(activeSessionID: "s", eventSessionID: "s", utterances: [utterance("你", 0, false)], fullText: nil, isFinalPacket: false, forcedFinalize: false)
    _ = reducer.apply(activeSessionID: "s", eventSessionID: "s", utterances: [utterance("你好", 0, false)], fullText: nil, isFinalPacket: false, forcedFinalize: false)
    _ = reducer.apply(activeSessionID: "s", eventSessionID: "s", utterances: [utterance("你好。", 0, true)], fullText: nil, isFinalPacket: false, forcedFinalize: false)
    check(reducer.committed.map(\.text) == ["你好。"] && reducer.liveText.isEmpty, "定稿不重复")
    _ = reducer.apply(activeSessionID: "s", eventSessionID: "s", utterances: [utterance("你好。", 0, true), utterance("世界", 900, false)], fullText: nil, isFinalPacket: false, forcedFinalize: false)
    check(reducer.committed.map(\.text) == ["你好。"] && reducer.liveText == "世界", "重发不追加")
    _ = reducer.apply(activeSessionID: "s", eventSessionID: "s", utterances: [utterance("你好。", 0, true), utterance("世界。", 900, true)], fullText: nil, isFinalPacket: false, forcedFinalize: false)
    check(reducer.snapshot.displayText == "你好。世界。", "多句")
    _ = reducer.apply(activeSessionID: "s", eventSessionID: "s", utterances: [utterance("您好。", 0, true), utterance("世界。", 900, true)], fullText: nil, isFinalPacket: false, forcedFinalize: false)
    check(reducer.committed.map(\.text) == ["您好。", "世界。"], "二遍纠正替换原句")
    let ignored = reducer.apply(activeSessionID: "new", eventSessionID: "old", utterances: [utterance("迟到", 0, true)], fullText: nil, isFinalPacket: true, forcedFinalize: false)
    check(ignored == .ignoredOldSession, "旧会话")
    var timeout = RecognitionReducer()
    _ = timeout.apply(activeSessionID: "new", eventSessionID: "new", utterances: [utterance("未定稿", 1, false)], fullText: nil, isFinalPacket: false, forcedFinalize: false)
    _ = timeout.apply(activeSessionID: "new", eventSessionID: "new", utterances: [], fullText: nil, isFinalPacket: false, forcedFinalize: true)
    check(timeout.correctionIncomplete && timeout.committed.map(\.text) == ["未定稿"], "超时未完成纠正")

    var model = DictationWriteModel(route: .liveReplace)
    func snap(_ committed: [String], _ live: String) -> RecognitionSnapshot {
        RecognitionSnapshot(committed: committed.enumerated().map { CommittedSentence(id: "t:\($0.offset)", text: $0.element) }, liveText: live, correctionIncomplete: false, desynced: false)
    }
    check(model.apply(snapshot: snap([], "你"), focusValid: true).ops == [.replaceLive("你")], "实时插入建立替换范围")
    check(model.apply(snapshot: snap([], "你好"), focusValid: true).ops == [.replaceLive("你好")], "实时替换")
    check(model.apply(snapshot: snap(["你好。"], ""), focusValid: true).ops == [.replaceLive("你好。"), .lockLive], "句末锁定")
    check(model.apply(snapshot: snap(["你好。"], ""), focusValid: true).ops.isEmpty, "定稿不重写")
    var release = DictationWriteModel(route: .releaseInsert)
    check(release.apply(snapshot: snap(["你好。"], "世界"), focusValid: true).ops.isEmpty, "松开前不写")
    check(release.finish(snapshot: snap(["你好。"], "世界"), focusValid: true).ops == [.insert("你好。世界")], "松开写一次")
    check(release.finish(snapshot: snap(["你好。"], "世界"), focusValid: true).ops.isEmpty, "松开不重复")
    var stopped = DictationWriteModel(route: .sentenceInsert)
    check(stopped.apply(snapshot: snap([], "a"), focusValid: false).ops == [.stop], "焦点失效停止")
    check(stopped.finish(snapshot: snap(["a"], "b"), focusValid: true).ops.isEmpty, "停止后不再写")

    var gate = SessionGate()
    check(gate.keyDown(isRepeat: false) == .beginSession, "按下开始")
    check(gate.keyDown(isRepeat: true) == .ignoreRepeat, "重复按下忽略")
    check(gate.keyUp() == .cancelStartAndFinish, "启动中松开")
    check(gate.micReady() == .alreadyStopped, "松开后不再录音")
    gate.finished()
    _ = gate.keyDown(isRepeat: false)
    check(gate.micReady() == .enterRecording, "录音就绪")
    check(gate.keyUp() == .beginFinish, "松开收尾")
    check(gate.keyDown(isRepeat: false) == .ignoreBusy, "收尾忽略重入")

    var buffer = BoundedPCMBuffer(capacity: 4)
    check(buffer.append(Data([1, 2])) && !buffer.append(Data([3, 4, 5])) && buffer.count == 2 && buffer.overflowed, "缓冲超限不丢已接收数据")
    check(UTF16Text.length("你好") == 2 && UTF16Text.length("a\nb") == 3 && UTF16Text.length("😀") == 2, "utf16")
    check(UTF16Text.length("😀") != "😀".count, "emoji 不能用字符数")
    check(SyntheticInputPolicy.mustDefer(held: .command) && !SyntheticInputPolicy.mustDefer(held: []), "修饰键推迟模拟输入")
    check(InsertedText.sanitized("a\nb") == "a b", "去掉换行避免提交")

    check(AudioSendScheduler.decide(phase: .recording, handshakeReady: true, lastPacketSent: false, pendingBytes: 100, conversionPending: false, packetBytes: 6400) == .wait(0.05), "不足一包继续等待")
    check(AudioSendScheduler.decide(phase: .recording, handshakeReady: true, lastPacketSent: false, pendingBytes: 6400, conversionPending: false, packetBytes: 6400) == .send(isLast: false), "满包发送")
    check(AudioSendScheduler.decide(phase: .finishing, handshakeReady: true, lastPacketSent: false, pendingBytes: 80, conversionPending: true, packetBytes: 6400) == .wait(0.05), "收尾等待转换")
    check(AudioSendScheduler.decide(phase: .finishing, handshakeReady: true, lastPacketSent: false, pendingBytes: 80, conversionPending: false, packetBytes: 6400) == .send(isLast: true), "收尾发送结束包")
    check(AudioSendScheduler.decide(phase: .recording, handshakeReady: true, lastPacketSent: true, pendingBytes: 10, conversionPending: false, packetBytes: 6400) == .stop, "结束包后停止")
    check(AudioSendScheduler.idleWait > 0, "等待间隔不为零")

    var live = DictationWriteModel(route: .liveReplace)
    var doc = LiveTextDocument()
    for op in live.apply(snapshot: snap([], "你"), focusValid: true).ops { doc.apply(op) }
    for op in live.apply(snapshot: snap([], "你好"), focusValid: true).ops { doc.apply(op) }
    for op in live.apply(snapshot: snap(["你好。"], ""), focusValid: true).ops { doc.apply(op) }
    check(doc.text == "你好。" && doc.owned == nil, "你到你好。不重复")

    var caret = InsertionGuard()
    caret.noteLive(location: 0, text: "你好")
    check(caret.observe(focusMatches: true, selectionLocation: 2, selectionLength: 0, ownedActual: "你好"), "光标在句尾")
    check(!caret.observe(focusMatches: true, selectionLocation: 0, selectionLength: 0, ownedActual: "你好"), "同框移动光标失效")
    check(!caret.observe(focusMatches: true, selectionLocation: 2, selectionLength: 0, ownedActual: "你好"), "移回也不恢复")

    var delivery = DeliveryConfirmer(maxObservations: 3)
    check(delivery.observe(before: "a", after: "a", expected: "b", insertionIndex: 1, focusValid: true, userEdited: false) == nil, "一次未变化不算失败")
    _ = delivery.observe(before: "a", after: "a", expected: "b", insertionIndex: 1, focusValid: true, userEdited: false)
    let stalled = delivery.observe(before: "a", after: "a", expected: "b", insertionIndex: 1, focusValid: true, userEdited: false)
    check(stalled == .uncertain && !DeliveryRetry.mayPostAgain(stalled ?? .success), "未变化不得再投递")
    var uncertain = DeliveryConfirmer()
    check(uncertain.observe(before: "已有你好", after: "已有你好世界", expected: "你好", insertionIndex: 2, focusValid: true, userEdited: false) == .uncertain, "框内已有相同文字不算成功")
    var inserted = DeliveryConfirmer()
    check(inserted.observe(before: "前后", after: "前你好后", expected: "你好", insertionIndex: 1, focusValid: true, userEdited: false) == .success, "按插入位置确认")

    let queue = DispatchQueue(label: "close-test")
    let started = DispatchSemaphore(value: 0)
    let unblock = DispatchSemaphore(value: 0)
    queue.async {
        started.signal()
        unblock.wait()
    }
    started.wait()
    var ran = false
    var owner: NSObject? = NSObject()
    DeferredClose.enqueue(on: queue, owner: owner!) { ran = true }
    owner = nil
    unblock.signal()
    queue.sync {}
    check(ran, "关闭任务在对象释放前仍会执行")
    check(!SessionCallbackFilter.shouldApply(activeSessionID: "new", eventSessionID: "old", cleanedUp: false), "旧会话回调丢弃")
    check(!SessionCallbackFilter.shouldApply(activeSessionID: "s", eventSessionID: "s", cleanedUp: true), "清理后丢弃")
    check(SessionCallbackFilter.shouldApply(activeSessionID: "s", eventSessionID: "s", cleanedUp: false), "当前会话接受")

    var keys = HotkeyEventState()
    let chord = HotkeyChord(keyCode: 49, modifiers: 0x80000)
    let down = keys.handle(kind: .keyDown, keyCode: 49, modifiers: 0x80000, isRepeat: false, isSynthetic: false, chord: chord, sessionActive: false, recordingShortcut: false)
    check(down.action == .down(isRepeat: false) && down.swallow, "听写键按下被吞掉")
    let again = keys.handle(kind: .keyDown, keyCode: 49, modifiers: 0x80000, isRepeat: true, isSynthetic: false, chord: chord, sessionActive: true, recordingShortcut: false)
    check(again.action == .down(isRepeat: true) && again.swallow, "重复按键被吞掉")
    let modifierUp = keys.handle(kind: .flagsChanged, keyCode: 58, modifiers: 0, isRepeat: false, isSynthetic: false, chord: chord, sessionActive: true, recordingShortcut: false)
    check(modifierUp.action == .up && !modifierUp.swallow, "先松开修饰键结束会话")
    let repeated = keys.handle(kind: .keyDown, keyCode: 49, modifiers: 0, isRepeat: true, isSynthetic: false, chord: chord, sessionActive: true, recordingShortcut: false)
    check(repeated.swallow && repeated.action == .none, "修饰键松开后主键重复仍被吞掉")
    let keyUp = keys.handle(kind: .keyUp, keyCode: 49, modifiers: 0, isRepeat: false, isSynthetic: false, chord: chord, sessionActive: true, recordingShortcut: false)
    check(keyUp.swallow && keyUp.action == .none, "修饰键已松开后仍吞掉主键松开")
    var finishingKeys = HotkeyEventState()
    let typed = finishingKeys.handle(kind: .keyDown, keyCode: 0, modifiers: 0, isRepeat: false, isSynthetic: false, chord: chord, sessionActive: true, recordingShortcut: false)
    check(typed.action == .userKey && !typed.swallow, "收尾期间普通按键仍通知")
    let synthetic = finishingKeys.handle(kind: .keyDown, keyCode: 0, modifiers: 0, isRepeat: false, isSynthetic: true, chord: chord, sessionActive: true, recordingShortcut: false)
    check(synthetic.action == .none, "自身合成事件不取消")
    if case .rejected = HotkeySafety.assess(HotkeyChord(keyCode: 49, modifiers: 0x100000)) {
        check(true, "系统保留组合被拒绝")
    } else {
        check(false, "系统保留组合被拒绝")
    }
    var interrupted = SessionGate()
    _ = interrupted.keyDown(isRepeat: false)
    _ = interrupted.micReady()
    check(interrupted.interrupt() == .beginFinish && interrupted.phase == .finishing, "手动输入转入收尾")

    let callbacks = SessionCallbackGate()
    callbacks.begin("first")
    callbacks.releaseASR()
    callbacks.begin("second")
    check(!callbacks.failure("first"), "旧错误不关闭新会话")
    check(!callbacks.failed && callbacks.acceptID == "second", "第二次连接仍有效")
    check(!callbacks.handshake("first"), "旧握手被丢弃")
    check(callbacks.handshake("second"), "新握手生效")
    check(!callbacks.timeout("first"), "旧超时不生效")
    check(!callbacks.timeout("second"), "已握手后超时不再生效")

    check(FinishStatus.resolve(writeFailed: true, pendingDelivery: false, waitingModifiers: false, incomplete: false, successDetail: "已完成") == nil, "写入失败不被已完成覆盖")
    check(FinishStatus.resolve(writeFailed: false, pendingDelivery: false, waitingModifiers: false, incomplete: true, successDetail: "收尾超时")?.short == "未完成", "收尾超时保留未完成")

    let fake = FakeCredentialKeychain(stored: "old-key")
    fake.failUpdate = true
    check(!CredentialEditor.save("new-key", in: fake) && fake.stored == "old-key", "替换失败保留旧密钥")
    fake.failUpdate = false
    check(CredentialEditor.save("new-key", in: fake) && fake.stored == "new-key", "替换成功")
    fake.failDelete = true
    check(!CredentialEditor.save("   ", in: fake) && fake.stored == "new-key", "清除失败不报成功")
    fake.failDelete = false
    check(CredentialEditor.save("", in: fake) && fake.stored == nil, "清除成功")
    fake.failAdd = true
    check(!CredentialEditor.save("another", in: fake) && fake.stored == nil, "新增失败不假装已保存")

    var sentenceGuard = InsertionGuard()
    sentenceGuard.expectedCursor = 0
    let firstSentence = "第一句。"
    sentenceGuard.noteCommittedInsert(endCursor: UTF16Text.length(firstSentence))
    check(sentenceGuard.observe(focusMatches: true, selectionLocation: UTF16Text.length(firstSentence), selectionLength: 0, ownedActual: nil), "第一句后光标前移仍允许")
    let secondSentence = "第二句。"
    sentenceGuard.noteCommittedInsert(endCursor: UTF16Text.length(firstSentence + secondSentence))
    check(sentenceGuard.observe(focusMatches: true, selectionLocation: UTF16Text.length(firstSentence + secondSentence), selectionLength: 0, ownedActual: nil), "第二句可以继续写入")
    var moved = InsertionGuard()
    moved.noteCommittedInsert(endCursor: 4)
    check(!moved.observe(focusMatches: true, selectionLocation: 0, selectionLength: 0, ownedActual: nil), "插入后用户移开光标停止")
    check(!moved.observe(focusMatches: true, selectionLocation: 4, selectionLength: 0, ownedActual: nil), "移回也不恢复")

    var liveDefinite = DictationWriteModel(route: .liveReplace)
    let definite = liveDefinite.apply(snapshot: snap(["第一句。"], ""), focusValid: true)
    check(definite.ops == [.insert("第一句。")], "首次即定稿走提交插入")
    var afterDefinite = InsertionGuard()
    afterDefinite.noteCommittedInsert(endCursor: UTF16Text.length("第一句。"))
    check(afterDefinite.observe(focusMatches: true, selectionLocation: UTF16Text.length("第一句。"), selectionLength: 0, ownedActual: nil), "定稿插入后下一句不被当成光标移动")

    var handoff = ASRDeliveryHandoff()
    handoff.asrCompleted(startedDelivery: true, modifiersHeld: false)
    check(handoff.asrReleased && !handoff.deliveryPollCancelled && handoff.pendingDelivery && handoff.status == "确认输入", "识别结束保留本地确认")
    check(handoff.sessionStillLocal, "确认期间会话本地部分仍活跃")
    handoff.deliveryResolved()
    check(!handoff.sessionStillLocal && handoff.status == "空闲", "确认结束后收敛")
    var waiting = ASRDeliveryHandoff()
    waiting.asrCompleted(startedDelivery: false, modifiersHeld: true)
    check(waiting.status == "等待松开", "只有修饰键未松才提示松开")

    let emojiChunks = UTF16Chunker.chunks("a😀b", limit: 2)
    check(emojiChunks.joined() == "a😀b", "分包不切开代理对")
    check(emojiChunks.allSatisfy { chunk in
        guard let last = Array(chunk.utf16).last else { return false }
        return !(last >= 0xD800 && last <= 0xDBFF)
    }, "没有孤立高位代理")
}

final class FakeCredentialKeychain: CredentialKeychain {
    var stored: String?
    var failUpdate = false
    var failAdd = false
    var failDelete = false

    init(stored: String?) {
        self.stored = stored
    }

    func update(_ value: String) -> Int32 {
        if failUpdate { return -1 }
        stored = value
        return 0
    }

    func add(_ value: String) -> Int32 {
        if failAdd { return -1 }
        stored = value
        return 0
    }

    func delete() -> Int32 {
        if failDelete { return -50 }
        stored = nil
        return 0
    }
}

func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "check", code: 1) }
    return value
}

do {
    try runChecks()
} catch {
    failures.append("异常 \(error)")
}
if failures.isEmpty {
    print("核心检查通过")
    exit(0)
}
fputs("失败 \(failures.count) 项\n", stderr)
exit(1)
