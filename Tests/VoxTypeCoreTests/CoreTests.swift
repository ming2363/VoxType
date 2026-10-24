import XCTest
@testable import VoxTypeCore

final class ProtocolTests: XCTestCase {
    func testHandshakeMatchesOfficialSample() throws {
        let headers = DoubaoHandshake.headers(apiKey: "secret-value", resourceID: DoubaoEndpoint.resourceDuration, requestID: "req-1")
        XCTAssertEqual(Set(headers.keys), ["X-Api-Key", "X-Api-Resource-Id", "X-Api-Request-Id"])
        XCTAssertEqual(headers["X-Api-Resource-Id"], "volc.seedasr.sauc.duration")
        XCTAssertFalse(headers.keys.contains("X-Api-Sequence"))
        XCTAssertEqual(DoubaoHandshake.redact("secret-value failed", secrets: ["secret-value"]), "[redacted] failed")
    }

    func testRequestUsesDocumentedFields() throws {
        let object = DoubaoRequestBuilder.object(uid: "voxtype")
        let audio = object["audio"] as? [String: Any]
        let request = object["request"] as? [String: Any]
        XCTAssertEqual(audio?["format"] as? String, "pcm")
        XCTAssertEqual(audio?["codec"] as? String, "raw")
        XCTAssertEqual(audio?["rate"] as? Int, 16000)
        XCTAssertNil(audio?["language"])
        XCTAssertEqual(request?["model_name"] as? String, "bigmodel")
        XCTAssertEqual(request?["enable_nonstream"] as? Bool, true)
        XCTAssertEqual(request?["show_utterances"] as? Bool, true)
        XCTAssertEqual(request?["enable_punc"] as? Bool, true)
        XCTAssertEqual(request?["enable_itn"] as? Bool, true)
        XCTAssertEqual(request?["enable_ddc"] as? Bool, false)
        XCTAssertEqual(request?["result_type"] as? String, "full")
        XCTAssertEqual(request?["end_window_size"] as? Int, 800)
        XCTAssertNil(request?["enable_accelerate_text"])
    }

    func testFrameHeadersMatchOfficialProtocol() throws {
        let json = try DoubaoRequestBuilder.jsonData(uid: "u")
        let full = try XCTUnwrap(DoubaoFrameEncoder.fullClientRequest(sequence: 1, json: json))
        XCTAssertEqual(Array(full.prefix(8)), [0x11, 0x11, 0x11, 0x00, 0x00, 0x00, 0x00, 0x01])

        let audio = try XCTUnwrap(DoubaoFrameEncoder.audioPacket(sequence: 2, pcm: Data([1, 2, 3, 4]), isLast: false))
        XCTAssertEqual(Array(audio.prefix(8)), [0x11, 0x21, 0x11, 0x00, 0x00, 0x00, 0x00, 0x02])

        let last = try XCTUnwrap(DoubaoFrameEncoder.audioPacket(sequence: 3, pcm: Data([9]), isLast: true))
        XCTAssertEqual(Array(last.prefix(4)), [0x11, 0x23, 0x11, 0x00])
        XCTAssertEqual(Int32(bigEndian: last.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: Int32.self) }), -3)
    }

    func testSequenceFollowsOfficialClient() {
        var sequence = DoubaoSequence()
        XCTAssertEqual(sequence.nextFullRequest(), 1)
        XCTAssertEqual(sequence.nextAudio(isLast: false), 2)
        XCTAssertEqual(sequence.nextAudio(isLast: true), 3)
        XCTAssertEqual(sequence.next, 3)
    }

    func testDecodeFullSnapshotAndErrorFrame() throws {
        let payload: [String: Any] = [
            "result": [
                "text": "你好",
                "additions": ["log_id": "log-1"],
                "utterances": [[
                    "text": "你好",
                    "start_time": 0,
                    "end_time": 200,
                    "definite": false
                ]]
            ]
        ]
        let json = try JSONSerialization.data(withJSONObject: payload)
        let compressed = try XCTUnwrap(Gzip.compress(json))
        var frame = Data([0x11, 0x91, 0x11, 0x00, 0x00, 0x00, 0x00, 0x02])
        var size = UInt32(compressed.count).bigEndian
        frame.append(Data(bytes: &size, count: 4))
        frame.append(compressed)
        let message = try XCTUnwrap(DoubaoFrameDecoder.decode(frame))
        XCTAssertEqual(message.sequence, 2)
        XCTAssertFalse(message.isLastPackage)
        XCTAssertEqual(message.text, "你好")
        XCTAssertEqual(message.logID, "log-1")
        XCTAssertEqual(message.utterances.first?.definite, false)

        var lastFlag = frame
        lastFlag[1] = 0x93
        let last = try XCTUnwrap(DoubaoFrameDecoder.decode(lastFlag))
        XCTAssertTrue(last.isLastPackage)
        XCTAssertEqual(last.text, "你好")

        let errorJSON = try JSONSerialization.data(withJSONObject: ["message": "bad"])
        var error = Data([0x11, 0xF0, 0x10, 0x00])
        var code = Int32(45000001).bigEndian
        var errorSize = UInt32(errorJSON.count).bigEndian
        error.append(Data(bytes: &code, count: 4))
        error.append(Data(bytes: &errorSize, count: 4))
        error.append(errorJSON)
        let failed = try XCTUnwrap(DoubaoFrameDecoder.decode(error))
        XCTAssertEqual(failed.failure, .invalidParameter)
    }

    func testGzipRoundTrip() throws {
        let source = Data("你好 world".utf8)
        let compressed = try XCTUnwrap(Gzip.compress(source))
        XCTAssertEqual(Array(compressed.prefix(2)), [0x1F, 0x8B])
        XCTAssertEqual(Gzip.decompress(compressed), source)
        XCTAssertNotNil(Gzip.compress(Data()))
    }
}

final class RecognitionTests: XCTestCase {
    func testPartialRevisionsThenDefiniteDoNotDuplicate() {
        var reducer = RecognitionReducer()
        _ = reducer.apply(activeSessionID: "s", eventSessionID: "s", utterances: [utterance("你", 0, false)], fullText: nil, isFinalPacket: false, forcedFinalize: false)
        _ = reducer.apply(activeSessionID: "s", eventSessionID: "s", utterances: [utterance("你好", 0, false)], fullText: nil, isFinalPacket: false, forcedFinalize: false)
        let definite = reducer.apply(activeSessionID: "s", eventSessionID: "s", utterances: [utterance("你好。", 0, true)], fullText: nil, isFinalPacket: false, forcedFinalize: false)
        guard case .updated(let snapshot) = definite else { return XCTFail() }
        XCTAssertEqual(snapshot.committed.map(\.text), ["你好。"])
        XCTAssertEqual(snapshot.liveText, "")
        let resent = reducer.apply(activeSessionID: "s", eventSessionID: "s", utterances: [utterance("你好。", 0, true), utterance("世界", 900, false)], fullText: nil, isFinalPacket: false, forcedFinalize: false)
        guard case .updated(let again) = resent else { return XCTFail() }
        XCTAssertEqual(again.committed.map(\.text), ["你好。"])
        XCTAssertEqual(again.liveText, "世界")
        let second = reducer.apply(activeSessionID: "s", eventSessionID: "s", utterances: [utterance("你好。", 0, true), utterance("世界。", 900, true)], fullText: nil, isFinalPacket: false, forcedFinalize: false)
        guard case .updated(let done) = second else { return XCTFail() }
        XCTAssertEqual(done.committed.map(\.text), ["你好。", "世界。"])
        XCTAssertEqual(done.displayText, "你好。世界。")
    }

    func testOldSessionIgnoredAndTimeoutMarksIncomplete() {
        var reducer = RecognitionReducer()
        let ignored = reducer.apply(activeSessionID: "new", eventSessionID: "old", utterances: [utterance("迟到", 0, true)], fullText: nil, isFinalPacket: true, forcedFinalize: false)
        XCTAssertEqual(ignored, .ignoredOldSession)
        XCTAssertTrue(reducer.committed.isEmpty)
        _ = reducer.apply(activeSessionID: "new", eventSessionID: "new", utterances: [utterance("未定稿", 1, false)], fullText: nil, isFinalPacket: false, forcedFinalize: false)
        let forced = reducer.apply(activeSessionID: "new", eventSessionID: "new", utterances: [], fullText: nil, isFinalPacket: false, forcedFinalize: true)
        guard case .updated(let snapshot) = forced else { return XCTFail() }
        XCTAssertEqual(snapshot.committed.map(\.text), ["未定稿"])
        XCTAssertTrue(snapshot.correctionIncomplete)
    }

    func testFullTextResendDoesNotAppendAndDesyncStopsAdoption() {
        var reducer = RecognitionReducer()
        _ = reducer.apply(activeSessionID: "s", eventSessionID: "s", utterances: [], fullText: "Hello", isFinalPacket: false, forcedFinalize: false)
        _ = reducer.apply(activeSessionID: "s", eventSessionID: "s", utterances: [], fullText: "Hello world", isFinalPacket: false, forcedFinalize: false)
        XCTAssertEqual(reducer.liveText, "Hello world")
        XCTAssertTrue(reducer.committed.isEmpty)
        _ = reducer.apply(activeSessionID: "s", eventSessionID: "s", utterances: [], fullText: "Hello world", isFinalPacket: true, forcedFinalize: false)
        XCTAssertEqual(reducer.committed.map(\.text), ["Hello world"])
        let desynced = reducer.apply(activeSessionID: "s", eventSessionID: "s", utterances: [], fullText: "完全不同", isFinalPacket: false, forcedFinalize: false)
        guard case .updated(let snapshot) = desynced else { return XCTFail() }
        XCTAssertTrue(snapshot.desynced)
        XCTAssertEqual(snapshot.committed.map(\.text), ["Hello world"])
    }

    private func utterance(_ text: String, _ start: Int, _ definite: Bool) -> UtteranceUpdate {
        UtteranceUpdate(text: text, startTime: start, endTime: start + 100, definite: definite)
    }
}

final class WriteModelTests: XCTestCase {
    func testLiveReplaceLocksSentenceAndDoesNotRewrite() {
        var model = DictationWriteModel(route: .liveReplace)
        let first = model.apply(snapshot: snap(committed: [], live: "你"), focusValid: true)
        XCTAssertEqual(first.ops, [.replaceLive("你")])
        let revised = model.apply(snapshot: snap(committed: [], live: "你好"), focusValid: true)
        XCTAssertEqual(revised.ops, [.replaceLive("你好")])
        let locked = model.apply(snapshot: snap(committed: ["你好。"], live: ""), focusValid: true)
        XCTAssertEqual(locked.ops, [.replaceLive("你好。"), .lockLive])
        let resent = model.apply(snapshot: snap(committed: ["你好。"], live: ""), focusValid: true)
        XCTAssertEqual(resent.ops, [])
        let next = model.apply(snapshot: snap(committed: ["你好。"], live: "世"), focusValid: true)
        XCTAssertEqual(next.ops, [.replaceLive("世")])
        let done = model.apply(snapshot: snap(committed: ["你好。", "世界。"], live: ""), focusValid: true)
        XCTAssertEqual(done.ops, [.replaceLive("世界。"), .lockLive])
    }

    func testReleaseInsertWritesOnceAndFocusStopPreventsLaterWrite() {
        var model = DictationWriteModel(route: .releaseInsert)
        XCTAssertEqual(model.apply(snapshot: snap(committed: ["你好。"], live: "世界"), focusValid: true).ops, [])
        let finish = model.finish(snapshot: snap(committed: ["你好。"], live: "世界"), focusValid: true)
        XCTAssertEqual(finish.ops, [.insert("你好。世界")])
        XCTAssertEqual(model.finish(snapshot: snap(committed: ["你好。"], live: "世界"), focusValid: true).ops, [])

        var stopped = DictationWriteModel(route: .sentenceInsert)
        XCTAssertEqual(stopped.apply(snapshot: snap(committed: [], live: "a"), focusValid: false).ops, [.stop])
        XCTAssertEqual(stopped.finish(snapshot: snap(committed: ["a"], live: "b"), focusValid: true).ops, [])
    }

    func testSentenceModeInsertsOnlyNewCommittedText() {
        var model = DictationWriteModel(route: .sentenceInsert)
        XCTAssertEqual(model.apply(snapshot: snap(committed: [], live: "临时"), focusValid: true).ops, [])
        XCTAssertEqual(model.apply(snapshot: snap(committed: ["第一句。"], live: "临时"), focusValid: true).ops, [.insert("第一句。")])
        XCTAssertEqual(model.apply(snapshot: snap(committed: ["第一句。"], live: "临时"), focusValid: true).ops, [])
        XCTAssertEqual(model.finish(snapshot: snap(committed: ["第一句。"], live: "尾巴"), focusValid: true).ops, [.insert("尾巴")])
    }

    func testDesyncStopsWriting() {
        var model = DictationWriteModel(route: .liveReplace)
        let plan = model.apply(snapshot: RecognitionSnapshot(committed: [], liveText: "x", correctionIncomplete: false, desynced: true), focusValid: true)
        XCTAssertEqual(plan.ops, [.stop])
    }

    private func snap(committed: [String], live: String) -> RecognitionSnapshot {
        RecognitionSnapshot(
            committed: committed.enumerated().map { CommittedSentence(id: "t:\($0.offset)", text: $0.element) },
            liveText: live,
            correctionIncomplete: false,
            desynced: false
        )
    }
}

final class SupportTests: XCTestCase {
    func testSessionGateRepeatReleaseAndBusy() {
        var gate = SessionGate()
        XCTAssertEqual(gate.keyDown(isRepeat: false), .beginSession)
        XCTAssertEqual(gate.keyDown(isRepeat: true), .ignoreRepeat)
        XCTAssertEqual(gate.keyUp(), .cancelStartAndFinish)
        XCTAssertEqual(gate.micReady(), .alreadyStopped)
        gate.finished()
        XCTAssertEqual(gate.keyDown(isRepeat: false), .beginSession)
        XCTAssertEqual(gate.micReady(), .enterRecording)
        XCTAssertEqual(gate.keyUp(), .beginFinish)
        XCTAssertEqual(gate.keyDown(isRepeat: false), .ignoreBusy)
    }

    func testBufferRejectsOverflowWithoutDroppingAcceptedAudio() {
        var buffer = BoundedPCMBuffer(capacity: 4)
        XCTAssertTrue(buffer.append(Data([1, 2])))
        XCTAssertFalse(buffer.append(Data([3, 4, 5])))
        XCTAssertEqual(buffer.count, 2)
        XCTAssertTrue(buffer.overflowed)
        XCTAssertEqual(Array(buffer.pop(maxBytes: 2)), [1, 2])
    }

    func testUTF16RangesForCJKNewlineAndEmoji() {
        XCTAssertEqual(UTF16Text.length("你好"), 2)
        XCTAssertEqual(UTF16Text.length("a\nb"), 3)
        XCTAssertEqual(UTF16Text.length("😀"), 2)
        XCTAssertGreaterThan(UTF16Text.length("👨‍👩‍👧‍👦"), "👨‍👩‍👧‍👦".count)
        XCTAssertEqual(AXRangeMath.previousLength("😀"), 2)
        XCTAssertNotEqual(AXRangeMath.previousLength("😀"), "😀".count)
        let owned = AXRangeMath.replacement(location: 4, previousText: "😀", newText: "你好")
        XCTAssertEqual(owned.location, 4)
        XCTAssertEqual(owned.length, 2)
        XCTAssertEqual(InsertedText.sanitized("a\nb\r\nc"), "a b c")
    }

    func testModifierAndClipboardPolicies() {
        XCTAssertTrue(SyntheticInputPolicy.mustDefer(held: .command))
        XCTAssertFalse(SyntheticInputPolicy.mustDefer(held: []))
        XCTAssertFalse(ClipboardRestore.shouldRestore(pasteConfirmed: false, changeCountAfterWrite: 2, currentChangeCount: 2))
        XCTAssertFalse(ClipboardRestore.shouldRestore(pasteConfirmed: true, changeCountAfterWrite: 2, currentChangeCount: 3))
        XCTAssertTrue(ClipboardRestore.shouldRestore(pasteConfirmed: true, changeCountAfterWrite: 2, currentChangeCount: 2))
    }

    func testHotkeyMatcherIgnoresUnrelatedModifiers() {
        let chord = HotkeyChord(keyCode: 49, modifiers: HotkeyMatcher.relevantMask & 0x100000)
        XCTAssertTrue(HotkeyMatcher.matches(chord: chord, keyCode: 49, modifiers: 0x100000))
        XCTAssertFalse(HotkeyMatcher.matches(chord: chord, keyCode: 49, modifiers: 0))
        XCTAssertFalse(HotkeyMatcher.matches(chord: chord, keyCode: 36, modifiers: 0x100000))
    }
}

final class RecheckTests: XCTestCase {
    func testSecondSentenceIsNotTreatedAsCursorMove() {
        var guardState = InsertionGuard()
        guardState.noteCommittedInsert(endCursor: UTF16Text.length("第一句。"))
        XCTAssertTrue(guardState.observe(focusMatches: true, selectionLocation: UTF16Text.length("第一句。"), selectionLength: 0, ownedActual: nil))
        guardState.noteCommittedInsert(endCursor: UTF16Text.length("第一句。第二句。"))
        XCTAssertTrue(guardState.observe(focusMatches: true, selectionLocation: UTF16Text.length("第一句。第二句。"), selectionLength: 0, ownedActual: nil))
    }

    func testASRFinishKeepsLocalConfirmation() {
        var handoff = ASRDeliveryHandoff()
        handoff.asrCompleted(startedDelivery: true, modifiersHeld: false)
        XCTAssertFalse(handoff.deliveryPollCancelled)
        XCTAssertEqual(handoff.status, "确认输入")
        handoff.deliveryResolved()
        XCTAssertFalse(handoff.sessionStillLocal)
    }

    func testRepeatAfterModifierReleaseIsSwallowed() {
        var keys = HotkeyEventState()
        let chord = HotkeyChord(keyCode: 36, modifiers: 0x80000)
        _ = keys.handle(kind: .keyDown, keyCode: 36, modifiers: 0x80000, isRepeat: false, isSynthetic: false, chord: chord, sessionActive: false, recordingShortcut: false)
        _ = keys.handle(kind: .flagsChanged, keyCode: 58, modifiers: 0, isRepeat: false, isSynthetic: false, chord: chord, sessionActive: true, recordingShortcut: false)
        let repeated = keys.handle(kind: .keyDown, keyCode: 36, modifiers: 0, isRepeat: true, isSynthetic: false, chord: chord, sessionActive: true, recordingShortcut: false)
        XCTAssertTrue(repeated.swallow)
        XCTAssertEqual(repeated.action, .none)
    }

    func testUnchangedDeliveryDoesNotAuthorizeRetry() {
        var confirmer = DeliveryConfirmer(maxObservations: 1)
        let observation = confirmer.observe(before: "已有你好", after: "已有你好", expected: "你好", insertionIndex: 4, focusValid: true, userEdited: false)
        XCTAssertEqual(observation, .uncertain)
        XCTAssertFalse(DeliveryRetry.mayPostAgain(.uncertain))
        XCTAssertFalse(InsertionProof.confirmed(before: "已有你好", after: "已有你好世界", expected: "你好", insertionIndex: 4))
        XCTAssertTrue(InsertionProof.confirmed(before: "前", after: "前你好", expected: "你好", insertionIndex: 1))
    }

    func testLateFailureDoesNotCloseNextSession() {
        let callbacks = SessionCallbackGate()
        callbacks.begin("first")
        callbacks.releaseASR()
        callbacks.begin("second")
        XCTAssertFalse(callbacks.failure("first"))
        XCTAssertFalse(callbacks.handshake("first"))
        XCTAssertFalse(callbacks.timeout("first"))
        XCTAssertFalse(callbacks.failed)
        XCTAssertTrue(callbacks.handshake("second"))
    }

    func testUnicodeChannelResetsEachSession() {
        var delivery = SessionDeliveryState()
        for _ in 0..<3 {
            delivery.reset(fallbackIsUnicode: true)
            XCTAssertEqual(delivery.nextChannel(), "unicode")
        }
    }

    func testFinishKeepsWriteFailure() {
        XCTAssertNil(FinishStatus.resolve(writeFailed: true, pendingDelivery: false, waitingModifiers: false, incomplete: false, successDetail: "已完成"))
    }

    func testKeychainReplaceFailureKeepsOldSecret() {
        let fake = FakeCredentialKeychain(stored: "old-key")
        fake.failUpdate = true
        XCTAssertFalse(CredentialEditor.save("new-key", in: fake))
        XCTAssertEqual(fake.stored, "old-key")
        fake.failDelete = true
        XCTAssertFalse(CredentialEditor.save("", in: fake))
        XCTAssertEqual(fake.stored, "old-key")
    }
}

final class FakeCredentialKeychain: CredentialKeychain {
    var stored: String?
    var failUpdate = false
    var failAdd = false
    var failDelete = false

    init(stored: String?) { self.stored = stored }

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
