import XCTest

final class ReplayE2ETests: ReplayE2ETestCase {
    // MARK: - Recorded session

    func testColdStartPostsActiveRowThenSequencedBlobsWithDecodableVideo() throws {
        launch()
        let row = try activeRow()
        XCTAssertEqual(row.status, "active")
        XCTAssertEqual(row.recorded, "true")
        XCTAssertEqual(row.attributes["maple.session.replay_format"], "video")
        XCTAssertNil(row.attributes["maple.session.replay_trigger"])
        XCTAssertEqual(row.json["service_name"] as? String, "replay-demo-e2e")
        XCTAssertNil(row.json["end_time"], "an active row must not carry an end time")
        XCTAssertEqual(server.metaRows.first?.sessionId, row.sessionId, "the first meta row is the session's v1")

        let blobs = try waitForBlobs(row.sessionId, count: 3)
        XCTAssertLessThan(row.receivedAt, blobs[0].receivedAt, "the billed row must precede the first chunk")

        let seqs = blobs.map(\.chunkSeq)
        XCTAssertEqual(seqs.sorted(), Array(0..<seqs.count), "chunk seqs must be 0, 1, 2... with no gaps or reuse")

        let window = windowSize
        for blob in blobs {
            let headers = blob.request.headers
            XCTAssertEqual(blob.request.method, "POST")
            XCTAssertEqual(headers["authorization"], "Bearer \(Self.ingestKey)")
            XCTAssertEqual(headers["content-type"], "application/octet-stream")
            XCTAssertNil(headers["content-encoding"], "the gzip is the payload, not a transfer encoding")
            XCTAssertTrue(headers["x-maple-sdk"]?.hasPrefix("maple-swift/") == true, "x-maple-sdk: \(headers["x-maple-sdk"] ?? "nil")")
            XCTAssertEqual(headers["x-maple-is-checkpoint"], "1")
            XCTAssertEqual(headers["x-maple-event-count"], String(blob.events.count))

            let first = try XCTUnwrap(blob.events.first)
            XCTAssertEqual(first["type"] as? Int, 4, "chunk \(blob.chunkSeq) must open with an rrweb meta event")
            let metaData = try XCTUnwrap(first["data"] as? [String: Any])
            XCTAssertEqual(metaData["href"] as? String, "maple://replay/\(row.sessionId)")
            XCTAssertEqual(blob.videoEvents.count, 1, "chunk \(blob.chunkSeq) must carry exactly one video")

            let payload = try XCTUnwrap(blob.videoPayload)
            let width = try XCTUnwrap(payload["width"] as? Int)
            let height = try XCTUnwrap(payload["height"] as? Int)
            XCTAssertEqual(metaData["width"] as? Int, width)
            XCTAssertEqual(metaData["height"] as? Int, height)
            XCTAssertEqual(payload["segmentId"] as? Int, blob.chunkSeq)
            XCTAssertEqual(headers["x-maple-duration-ms"], (payload["duration"] as? Int).map(String.init))
            // Medium tier is one pixel per point, rounded to even for H.264.
            XCTAssertEqual(Double(width), window.width, accuracy: 2)
            XCTAssertEqual(Double(height), window.height, accuracy: 2)

            let video = try blob.decodeVideo()
            XCTAssertEqual(video.width, width)
            XCTAssertEqual(video.height, height)
            XCTAssertEqual(video.frames.count, payload["frameCount"] as? Int, "chunk \(blob.chunkSeq) frame count")
            XCTAssertEqual(payload["size"] as? Int, (payload["base64"] as? String).flatMap { Data(base64Encoded: $0)?.count })
            XCTAssertTrue(video.frames.allSatisfy { $0.width == width && $0.height == height })
            let declaredMs = try XCTUnwrap(payload["duration"] as? Int)
            XCTAssertEqual(video.duration * 1000, Double(declaredMs), accuracy: 100, "chunk \(blob.chunkSeq) declared vs real duration")
            let times = video.frames.map(\.time)
            XCTAssertEqual(times, times.sorted(), "presentation times must increase")
        }

        // Back to back on the session clock: a player stitches segments by start time, so an
        // overlap replays seconds twice and a gap freezes the picture.
        let ordered = blobs.sorted { $0.chunkSeq < $1.chunkSeq }
        for (previous, next) in zip(ordered, ordered.dropFirst()) {
            let previousEnd = previous.startMs + (previous.videoPayload?["duration"] as? Int ?? 0)
            XCTAssertGreaterThanOrEqual(next.startMs, previousEnd - 50, "chunk \(next.chunkSeq) overlaps chunk \(previous.chunkSeq)")
            XCTAssertLessThan(next.startMs - previousEnd, 1_000, "gap before chunk \(next.chunkSeq)")
        }
    }

    // MARK: - Masking

    func testSecretTextAndSecureFieldAreBlackInTheVideoWhilePlainViewIsNot() throws {
        launch()
        let row = try activeRow()
        let secret = try frame(of: "e2e.secret")
        let textField = try frame(of: "e2e.textField")
        let secureField = try frame(of: "e2e.secureField")
        let plain = try frame(of: "e2e.plain")
        let window = windowSize
        let visibleSince = Date().epochMs

        let blob = try waitFor("a segment recorded after the screen was laid out") {
            try blobs(for: row.sessionId).first { $0.startMs > visibleSince }
        }
        let video = try blob.decodeVideo()
        let frame = try XCTUnwrap(video.frames.last)
        let scale = CGFloat(video.width) / window.width

        for (name, rect) in [("secret label", secret), ("text field", textField), ("secure field", secureField)] {
            let region = rect.scaled(by: scale).insetBy(dx: 3, dy: 3)
            let luma = frame.maxLuma(in: region)
            XCTAssertLessThan(luma, 60, "\(name) at \(region) is not masked: brightest pixel luma \(luma)")
        }

        let keypad = try (1...9).map { try self.frame(of: "e2e.key.\($0)") }.reduce(CGRect.null) { $0.union($1) }
        let keypadLuma = frame.maxLuma(in: keypad.scaled(by: scale).insetBy(dx: 3, dy: 3))
        XCTAssertLessThan(keypadLuma, 60, ".mapleReplayMask() keypad is not masked: brightest pixel luma \(keypadLuma)")

        let control = frame.meanColor(in: plain.scaled(by: scale).insetBy(dx: 6, dy: 6))
        XCTAssertGreaterThan(control.r, 170, "plain view should be unmasked magenta, got \(control)")
        XCTAssertGreaterThan(control.b, 170, "plain view should be unmasked magenta, got \(control)")
        XCTAssertLessThan(control.g, 90, "plain view should be unmasked magenta, got \(control)")
    }

    func testTypedTextStaysMaskedAndKeyboardTouchesAreNotRecorded() throws {
        launch()
        let row = try activeRow()
        element("e2e.textField").tap()
        element("e2e.textField").typeText("jane@example.com")
        element("e2e.secureField").tap()
        element("e2e.secureField").typeText("hunter2")
        let keyboard = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame : CGRect.null
        let textField = try frame(of: "e2e.textField")
        let secureField = try frame(of: "e2e.secureField")
        let window = windowSize
        let typedAt = Date().epochMs

        let blob = try waitFor("a segment recorded after typing") {
            try blobs(for: row.sessionId).first { $0.startMs > typedAt }
        }
        let video = try blob.decodeVideo()
        let frame = try XCTUnwrap(video.frames.last)
        let scale = CGFloat(video.width) / window.width
        for (name, rect) in [("text field", textField), ("secure field", secureField)] {
            let luma = frame.maxLuma(in: rect.scaled(by: scale).insetBy(dx: 3, dy: 3))
            XCTAssertLessThan(luma, 60, "\(name) with typed text is not masked: brightest pixel luma \(luma)")
        }

        // Keys spell what was typed, so a key's position is as sensitive as the field.
        let keyboardPixels = keyboard.scaled(by: scale)
        let onKeyboard = try blobs(for: row.sessionId).flatMap(\.touches)
            .filter { !keyboard.isNull && keyboardPixels.contains(CGPoint(x: $0.x, y: $0.y)) }
        XCTAssertTrue(onKeyboard.isEmpty, "touches recorded on the keyboard \(keyboardPixels): \(onKeyboard)")
        let inputPixels = [textField, secureField].map { $0.scaled(by: scale) }
        let onFields = try blobs(for: row.sessionId).flatMap(\.touches).filter { touch in
            inputPixels.contains { $0.contains(CGPoint(x: touch.x, y: touch.y)) }
        }
        XCTAssertTrue(onFields.isEmpty, "touches recorded on text inputs: \(onFields)")
    }

    // MARK: - Touches

    func testTouchesLandInVideoPixelsAndNeverInsideMaskedKeypad() throws {
        launch()
        let row = try activeRow()
        let plain = try frame(of: "e2e.plain")
        let keypad = try (1...9).map { try frame(of: "e2e.key.\($0)") }.reduce(CGRect.null) { $0.union($1) }
        let window = windowSize
        // Let at least one capture run so the keypad's masked region is known.
        try waitForBlobs(row.sessionId, count: 1)

        let target = CGPoint(x: plain.midX.rounded(), y: plain.midY.rounded())
        let tappedAt = Date().epochMs
        tap(atWindowPoint: target)

        let (blob, touch) = try waitFor("a touch event for the tap on the plain view") { () -> (Blob, (type: Int, x: Int, y: Int, timestamp: Int))? in
            for blob in try blobs(for: row.sessionId) {
                if let touch = blob.touches.first(where: { [7, 9].contains($0.type) && $0.timestamp >= tappedAt - 500 }) {
                    return (blob, touch)
                }
            }
            return nil
        }
        let scale = CGFloat(try XCTUnwrap(blob.videoPayload?["width"] as? Int)) / window.width
        XCTAssertEqual(Double(touch.x), Double(target.x * scale), accuracy: 3, "touch x in video pixels")
        XCTAssertEqual(Double(touch.y), Double(target.y * scale), accuracy: 3, "touch y in video pixels")

        for digit in [1, 5, 9, 3] {
            element("e2e.key.\(digit)").tap()
        }
        XCTAssertTrue(
            app.staticTexts["e2e.status"].label.hasPrefix("keys 4"),
            "keypad taps did not reach the app: \(app.staticTexts["e2e.status"].label)"
        )
        // A positive control after the keypad taps, so the window is known to be recording.
        let controlAt = Date().epochMs
        tap(atWindowPoint: CGPoint(x: plain.minX + 20, y: plain.minY + 20))
        try waitFor("the control tap after the keypad taps") {
            try blobs(for: row.sessionId).flatMap(\.touches).contains { $0.timestamp >= controlAt - 500 } ? true : nil
        }

        let maskedPixels = keypad.scaled(by: scale)
        let leaked = try blobs(for: row.sessionId).flatMap(\.touches)
            .filter { maskedPixels.contains(CGPoint(x: $0.x, y: $0.y)) }
        XCTAssertTrue(leaked.isEmpty, "touches recorded inside the masked keypad \(maskedPixels): \(leaked)")
    }

    // MARK: - Background

    func testShortBackgroundEndsThenResumesSameSessionWithHigherVersion() throws {
        launch()
        let first = try activeRow()
        let before = try waitForBlobs(first.sessionId, count: 1)

        let backgroundedAt = Date()
        moveToBackground()
        let ended = try waitFor("the ended row") {
            rows(for: first.sessionId).first { $0.status == "ended" }
        }
        XCTAssertNotNil(ended.json["end_time"])
        XCTAssertGreaterThan(ended.json["duration_ms"] as? Int ?? 0, 0)
        XCTAssertGreaterThan(ended.version, first.version)
        let seqsBeforeResume = try blobs(for: first.sessionId).map(\.chunkSeq)
        XCTAssertGreaterThanOrEqual(seqsBeforeResume.count, before.count)

        hold(max(0, 2 - Date().timeIntervalSince(backgroundedAt)))
        app.activate()

        let resumed = try waitFor("an active row resuming the same session") {
            rows(for: first.sessionId).first { $0.status == "active" && $0.version > ended.version }
        }
        XCTAssertGreaterThan(resumed.receivedAt, ended.receivedAt)
        XCTAssertNotEqual(resumed.json["start_time"] as? String, nil)
        XCTAssertEqual(resumed.json["start_time"] as? String, first.json["start_time"] as? String, "a resumed session keeps its start")

        let versions = rows(for: first.sessionId).map(\.version)
        XCTAssertEqual(versions, versions.sorted(), "versions must increase in arrival order")
        XCTAssertEqual(Set(versions).count, versions.count, "versions must never repeat")

        let after = try waitFor("a blob after the resume") {
            try blobs(for: first.sessionId).first { $0.receivedAt > resumed.receivedAt }
        }
        XCTAssertGreaterThan(after.chunkSeq, seqsBeforeResume.max() ?? -1, "seqs continue after resume")
        let all = try blobs(for: first.sessionId).map(\.chunkSeq)
        XCTAssertEqual(Set(all).count, all.count, "no chunk seq is reused across the pause: \(all)")
    }

    func testLongBackgroundStartsNewSession() throws {
        launch(["MAPLE_BACKGROUND_TIMEOUT": "1"])
        let first = try activeRow()
        try waitForBlobs(first.sessionId, count: 1)

        let backgroundedAt = Date()
        moveToBackground()
        try waitFor("the ended row") { rows(for: first.sessionId).first { $0.status == "ended" } }
        hold(max(0, 4 - Date().timeIntervalSince(backgroundedAt)))
        app.activate()

        let next = try waitFor("an active row for a new session") {
            server.metaRows.first { $0.status == "active" && $0.sessionId != first.sessionId }
        }
        XCTAssertEqual(next.version, 1, "a new session starts at version 1")
        XCTAssertEqual(next.recorded, "true")
        XCTAssertFalse(rows(for: first.sessionId).contains { $0.receivedAt > next.receivedAt && $0.status == "active" },
                       "the expired session must not be resumed")
        let blob = try waitForBlobs(next.sessionId, count: 1)[0]
        XCTAssertEqual(blob.chunkSeq, 0, "a new session's chunks start at 0")
    }

    // MARK: - Sampling

    func testErrorBufferUploadsBufferedWindowOnTriggerThenRecordsContinuously() throws {
        launch(["MAPLE_SESSION_SAMPLE_RATE": "0", "MAPLE_ON_ERROR_SAMPLE_RATE": "1"])
        let first = try activeRow()
        XCTAssertEqual(first.recorded, "false")
        XCTAssertNil(first.attributes["maple.session.replay_trigger"])

        let plain = try frame(of: "e2e.plain")
        hold(3)
        // A tap inside the buffered window belongs to the recording the flush uploads.
        let bufferedTap = CGPoint(x: plain.midX.rounded(), y: plain.midY.rounded())
        let bufferedTapAt = Date().epochMs
        tap(atWindowPoint: bufferedTap)
        hold(2)
        XCTAssertEqual(server.blobRequests.count, 0, "an error-buffered session uploads nothing before a flush")

        let tappedAt = Date().epochMs
        element("e2e.triggerError").tap()

        let promoted = try activeRow(version: 2)
        XCTAssertEqual(promoted.sessionId, first.sessionId)
        XCTAssertEqual(promoted.recorded, "true")
        XCTAssertEqual(promoted.attributes["maple.session.replay_trigger"], "error")

        let blobs = try waitForBlobs(first.sessionId, count: 3)
        let buffered = try XCTUnwrap(blobs.first { $0.chunkSeq == 0 })
        XCTAssertLessThanOrEqual(promoted.receivedAt, buffered.receivedAt, "the row must say recorded before the first chunk lands")
        XCTAssertLessThan(buffered.startMs, tappedAt - 3_000, "the flushed segment must cover the buffered seconds before the tap")
        let video = try buffered.decodeVideo()
        XCTAssertGreaterThanOrEqual(video.duration, 3, "buffered window video is only \(video.duration) s")
        XCTAssertEqual(video.frames.count, buffered.videoPayload?["frameCount"] as? Int)
        XCTAssertEqual(blobs.map(\.chunkSeq).sorted().prefix(3), [0, 1, 2], "recording continues after the flush")
        let scale = CGFloat(video.width) / windowSize.width
        let replayedTap = buffered.touches.first { $0.timestamp >= bufferedTapAt - 500 && $0.timestamp < tappedAt - 500 }
        let touch = try XCTUnwrap(replayedTap, "the tap made while buffering is missing from the flushed segment: \(buffered.touches)")
        XCTAssertEqual(Double(touch.x), Double(bufferedTap.x * scale), accuracy: 3)
        XCTAssertEqual(Double(touch.y), Double(bufferedTap.y * scale), accuracy: 3)
    }

    func testOffSessionPostsUnrecordedRowAndNoBlobs() throws {
        launch(["MAPLE_SESSION_SAMPLE_RATE": "0", "MAPLE_ON_ERROR_SAMPLE_RATE": "0"])
        let row = try activeRow()
        XCTAssertEqual(row.recorded, "false")
        hold(6)
        XCTAssertEqual(server.blobRequests.count, 0)
        XCTAssertTrue(server.metaRows.allSatisfy { $0.recorded == "false" })
        // Even an explicit flush must not produce video for a session that was not sampled.
        element("e2e.triggerError").tap()
        hold(3)
        XCTAssertEqual(server.blobRequests.count, 0)
    }

    // MARK: - Crash recovery

    func testCrashedBufferedSessionIsRecoveredOnNextLaunch() throws {
        let environment = ["MAPLE_SESSION_SAMPLE_RATE": "0", "MAPLE_ON_ERROR_SAMPLE_RATE": "1"]
        launch(environment)
        let crashed = try activeRow()
        hold(4)
        let versionsBeforeCrash = rows(for: crashed.sessionId).map(\.version)
        XCTAssertEqual(server.blobRequests.count, 0)

        // XCTest reports the app crashing as an issue; here it is the scenario. The matcher
        // only absorbs that one issue, so any other failure still fails the test.
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = { $0.compactDescription.contains("crashed") }
        XCTExpectFailure("the crash button aborts the app on purpose", options: options)
        element("e2e.crash").tap()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "the app did not die")

        launch(environment, reset: false)
        let recovered = try waitFor("a recovered blob for the crashed session", timeout: 30) {
            try blobs(for: crashed.sessionId).first { !$0.breadcrumbs(category: "replay.crash_recovery").isEmpty }
        }
        XCTAssertEqual(recovered.chunkSeq, 0, "nothing was emitted before the crash, so recovery takes seq 0")
        let video = try recovered.decodeVideo()
        XCTAssertGreaterThanOrEqual(video.frames.count, 4, "recovered video holds the spooled window")
        XCTAssertEqual(video.frames.count, recovered.videoPayload?["frameCount"] as? Int)

        let ended = try waitFor("the ended row for the crashed session") {
            rows(for: crashed.sessionId).first { $0.status == "ended" }
        }
        XCTAssertGreaterThan(ended.version, versionsBeforeCrash.max() ?? 0)
        XCTAssertNotNil(ended.json["end_time"])
        XCTAssertEqual(ended.attributes["maple.session.recorded"], "true")

        let current = try waitFor("the relaunch's own session") {
            server.metaRows.first { $0.status == "active" && $0.sessionId != crashed.sessionId }
        }
        XCTAssertEqual(current.version, 1)
    }

    func testCrashedRecordedSessionRecoversTailUnderAFreshChunkSeq() throws {
        launch()
        let crashed = try activeRow()
        try waitForBlobs(crashed.sessionId, count: 2)
        hold(1.2)
        let uploaded = try blobs(for: crashed.sessionId).map(\.chunkSeq)
        let versionsBeforeCrash = rows(for: crashed.sessionId).map(\.version)

        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = { $0.compactDescription.contains("crashed") }
        XCTExpectFailure("the crash button aborts the app on purpose", options: options)
        element("e2e.crash").tap()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "the app did not die")
        let uploadedBeforeDeath = try blobs(for: crashed.sessionId).map(\.chunkSeq)

        launch(reset: false)
        let recovered = try waitFor("a recovered blob for the crashed session", timeout: 30) {
            try blobs(for: crashed.sessionId).first { !$0.breadcrumbs(category: "replay.crash_recovery").isEmpty }
        }
        XCTAssertFalse(uploadedBeforeDeath.contains(recovered.chunkSeq),
                       "recovered chunk reuses seq \(recovered.chunkSeq); live run uploaded \(uploadedBeforeDeath)")
        XCTAssertGreaterThan(recovered.chunkSeq, uploaded.max() ?? -1)
        let ended = try waitFor("the ended row for the crashed session") {
            rows(for: crashed.sessionId).first { $0.status == "ended" }
        }
        XCTAssertGreaterThan(ended.version, versionsBeforeCrash.max() ?? 0)
        XCTAssertNil(ended.attributes["maple.session.replay_trigger"], "a session recorded from the start has no trigger")
    }

    // MARK: - Kill switches

    func testBlob413StopsChunksButNotMetadata() throws {
        server.respond { $0 == WirePath.blob ? 413 : 200 }
        launch()
        let row = try activeRow()
        try waitForBlobs(row.sessionId, count: 1)
        hold(5)
        XCTAssertEqual(try blobs(for: row.sessionId).count, 1, "no chunk may follow a 413")

        moveToBackground()
        let ended = try waitFor("the ended row after a 413") {
            rows(for: row.sessionId).first { $0.status == "ended" }
        }
        XCTAssertGreaterThan(ended.version, row.version)
        hold(1)
        app.activate()
        try waitFor("the resumed active row after a 413") {
            rows(for: row.sessionId).first { $0.status == "active" && $0.version > ended.version }
        }
        hold(4)
        XCTAssertEqual(try blobs(for: row.sessionId).count, 1, "a resumed session keeps the 413 kill switch")
    }

    func testEntitlement402StopsEverythingForTheSession() throws {
        server.respond { _ in 402 }
        launch()
        let row = try activeRow()
        hold(5)
        moveToBackground()
        hold(2)
        app.activate()
        hold(4)
        let sent = server.replayRequests(for: row.sessionId)
        XCTAssertEqual(sent.map(\.path), [WirePath.meta], "only the request that earned the 402 may be sent")
    }

    // MARK: - Identity and events

    func testSetUserIdPostsNewActiveRowWithUserId() throws {
        launch()
        let row = try activeRow()
        XCTAssertEqual(row.userId, "")
        element("e2e.setUser").tap()
        let identified = try waitFor("an active row carrying the user id") {
            rows(for: row.sessionId).first { $0.userId == "user-42" }
        }
        XCTAssertEqual(identified.status, "active")
        XCTAssertGreaterThan(identified.version, row.version)

        moveToBackground()
        let ended = try waitFor("the ended row") { rows(for: row.sessionId).first { $0.status == "ended" } }
        XCTAssertEqual(ended.userId, "user-42", "the id carries onto later rows")
    }

    func testTrackSendsCustomSessionEvent() throws {
        launch()
        let row = try activeRow()
        element("e2e.track").tap()
        let event = try waitFor("the custom session event") {
            server.eventRows.first { $0["type"] as? String == "custom" }
        }
        XCTAssertEqual(event["message"] as? String, "e2e_button_tapped")
        XCTAssertEqual(event["session_id"] as? String, row.sessionId)
        XCTAssertEqual(event["attributes"] as? [String: String], ["source": "e2e"])
        let request = try XCTUnwrap(server.requests.first { $0.path == WirePath.events })
        XCTAssertEqual(request.headers["content-type"], "application/x-ndjson")
    }

    // MARK: - Rotation

    func testRotationStartsNewSegmentWithSwappedDimensions() throws {
        launch(["MAPLE_E2E_ROTATION": "1"])
        let row = try activeRow()
        let portrait = try waitForBlobs(row.sessionId, count: 2)[1]
        let portraitVideo = try portrait.decodeVideo()
        XCTAssertLessThan(portraitVideo.width, portraitVideo.height)

        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = try waitFor("a landscape segment") {
            try blobs(for: row.sessionId).first { ($0.videoPayload?["width"] as? Int ?? 0) > ($0.videoPayload?["height"] as? Int ?? 0) }
        }
        let landscapeVideo = try landscape.decodeVideo()
        XCTAssertGreaterThan(landscape.chunkSeq, portrait.chunkSeq)
        XCTAssertEqual(landscapeVideo.width, portraitVideo.height)
        XCTAssertEqual(landscapeVideo.height, portraitVideo.width)
        XCTAssertTrue(landscapeVideo.frames.allSatisfy { $0.width == landscapeVideo.width && $0.height == landscapeVideo.height },
                      "every frame of a segment shares the track's size, so none is stretched")
        let meta = try XCTUnwrap(landscape.events.first?["data"] as? [String: Any])
        XCTAssertEqual(meta["width"] as? Int, landscapeVideo.width)
        XCTAssertEqual(meta["height"] as? Int, landscapeVideo.height)

        // Touches follow the rotated geometry: window points in landscape, scaled to the
        // landscape video.
        let plain = try frame(of: "e2e.plain")
        let window = windowSize
        XCTAssertGreaterThan(window.width, window.height, "the app did not rotate")
        let target = CGPoint(x: plain.midX.rounded(), y: plain.midY.rounded())
        let tappedAt = Date().epochMs
        tap(atWindowPoint: target)
        let (blob, touch) = try waitFor("a touch in a landscape segment") { () -> (Blob, (type: Int, x: Int, y: Int, timestamp: Int))? in
            for blob in try blobs(for: row.sessionId) {
                if let touch = blob.touches.first(where: { $0.timestamp >= tappedAt - 500 }) { return (blob, touch) }
            }
            return nil
        }
        let scale = CGFloat(try XCTUnwrap(blob.videoPayload?["width"] as? Int)) / window.width
        XCTAssertEqual(Double(touch.x), Double(target.x * scale), accuracy: 3, "landscape touch x")
        XCTAssertEqual(Double(touch.y), Double(target.y * scale), accuracy: 3, "landscape touch y")
    }
}
