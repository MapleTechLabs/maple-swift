import CoreMedia
import Foundation
import MapleCore
import XCTest
@testable import MapleReplay

// MARK: - Independent oracles

/// Bitwise CRC-32 (IEEE), deliberately not table-driven, so it shares no code with the
/// SDK's implementation it is checking.
private func referenceCRC32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
    }
    return ~crc
}

private func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
    let base = data.startIndex + offset
    return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[base + $1]) << (8 * UInt32($1)) }
}

/// Raw DEFLATE decode through Foundation, not the SDK's `Compression` call.
private func foundationInflate(_ deflate: Data) -> Data? {
    try? (deflate as NSData).decompressed(using: .zlib) as Data
}

private let dateTimePattern = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$"#)

private func matchesDateTime(_ value: String) -> Bool {
    dateTimePattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
}

/// Epoch milliseconds of a `yyyy-MM-dd HH:mm:ss.SSS` UTC literal via days-from-civil
/// arithmetic (proleptic Gregorian), independent of `DateFormatter`.
private func epochMilliseconds(ofDateTime value: String) -> Int64? {
    let parts = value.split(whereSeparator: { "- :.".contains($0) }).compactMap { Int64($0) }
    guard parts.count == 7 else { return nil }
    let (year, month, day) = (parts[0], parts[1], parts[2])
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let mp = (month + 9) % 12
    let doy = (153 * mp + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    let days = era * 146_097 + doe - 719_468
    return ((days * 24 + parts[3]) * 60 + parts[4]) * 60_000 + parts[5] * 1_000 + parts[6]
}

private func reference(coordinate value: CGFloat) -> Int {
    guard value.isFinite else { return 0 }
    if value > 100_000 { return 100_000 }
    if value < -100_000 { return -100_000 }
    return Int(value.rounded())
}

// MARK: - 1. Gzip

final class FuzzGzipTests: XCTestCase {
    private func payload(_ rng: inout FuzzRNG) -> Data {
        // Sizes cluster on the stored-block boundary, where an off-by-one splits or
        // merges a block.
        let size: Int
        switch rng.int(0...4) {
        case 0: size = rng.int(1...64)
        case 1: size = 65_535 + rng.int(-3...3)
        case 2: size = 2 * 65_535 + rng.int(-3...3)
        case 3: size = rng.int(1...300_000)
        default: size = rng.int(1...4_096)
        }
        var data: Data
        switch rng.int(0...2) {
        case 0:
            data = rng.bytes(size)  // incompressible: the stored-block path
        case 1:
            let pattern = rng.bytes(rng.int(1...16))
            data = Data((0..<size).map { pattern[$0 % pattern.count] })
        default:
            data = rng.bytes(size)
            for index in stride(from: 0, to: size, by: rng.int(2...50)) { data[index] = 0x41 }
        }
        // A slice with a non-zero startIndex, which index arithmetic gets wrong.
        if rng.chance(0.2), data.count > 2 {
            let cut = rng.int(1...(data.count - 1))
            return data[cut...]
        }
        return data
    }

    func testRoundTripAndContainerAgainstIndependentDecoders() {
        Fuzz.run("gzip.roundtrip", iterations: Fuzz.iterations(cost: 4)) { rng in
            let input = payload(&rng)
            let gz = Gzip.compress(input)
            guard let gz else { throw FuzzFailure(description: "compress returned nil for \(input.count) bytes") }

            try Fuzz.check(gz.count >= 18, "output shorter than a gzip container")
            try Fuzz.check(Array(gz.prefix(10)) == [0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0xFF], "header \(Array(gz.prefix(10)))")
            let crc = littleEndianUInt32(gz, at: gz.count - 8)
            let isize = littleEndianUInt32(gz, at: gz.count - 4)
            try Fuzz.check(crc == referenceCRC32(input), "CRC32 trailer \(crc) != \(referenceCRC32(input)) for \(input.count) bytes")
            try Fuzz.check(isize == UInt32(truncatingIfNeeded: input.count), "ISIZE \(isize) != \(input.count)")

            let deflate = gz.dropFirst(10).dropLast(8)
            let independent = foundationInflate(Data(deflate))
            try Fuzz.check(independent == Data(input), "Foundation inflate disagrees for \(input.count) bytes")
            try Fuzz.check(Gzip.decompress(gz) == Data(input), "decompress(compress(x)) != x for \(input.count) bytes")
        }
    }

    func testEmptyInputIsRefused() {
        // `compress` documents nil for empty input; the gateway has nothing to inflate.
        XCTAssertNil(Gzip.compress(Data()))
    }

    func testDecompressOnHostileInputIsBounded() {
        Fuzz.run("gzip.hostile", iterations: Fuzz.iterations(cost: 2)) { rng in
            let original = rng.bytes(rng.int(1...5_000))
            guard var data = Gzip.compress(original) else { throw FuzzFailure(description: "compress nil") }
            switch rng.int(0...4) {
            case 0:
                for _ in 0..<rng.int(1...8) {
                    let index = rng.int(0...(data.count - 1))
                    data[index] ^= UInt8(1 << rng.int(0...7))
                }
            case 1:
                data = data.prefix(rng.int(0...data.count))
            case 2:
                data.append(rng.bytes(rng.int(1...100)))
            case 3:
                // A trailer claiming gigabytes must not become a gigabyte allocation.
                let claim = UInt32.random(in: 0...UInt32.max, using: &rng)
                for byte in 0..<4 { data[data.count - 4 + byte] = UInt8(truncatingIfNeeded: claim >> (8 * UInt32(byte))) }
            default:
                data = Data([0x1F, 0x8B, 0x08, 0x00]) + rng.bytes(rng.int(0...2_000))
            }
            let result = Gzip.decompress(data)
            if let result {
                let claimed = data.count >= 4 ? Int(littleEndianUInt32(data, at: data.count - 4)) : 0
                try Fuzz.check(result.count <= max(1, min(claimed, 256 * 1024 * 1024)),
                               "decoded \(result.count) bytes, over the ISIZE bound \(claimed)")
                try Fuzz.check(!result.isEmpty, "non-nil empty result")
            }
        }
    }
}

// MARK: - 2. Frame names

final class FuzzFrameNameTests: XCTestCase {
    func testFrameNameRoundTrips() {
        Fuzz.run("frameName.roundtrip") { rng in
            let sequence = rng.chance(0.2) ? rng.pick([0, 1, 999_999_999, 1_000_000_000, Int.max]) : rng.int(0...10_000_000)
            let date = rng.hostileDate()
            let name = FrameSpool.frameName(sequence: sequence, timestamp: date)
            guard let parsed = FrameSpool.parseFrameName(name) else {
                throw FuzzFailure(description: "parseFrameName(\(name)) == nil for sequence \(sequence), t=\(date.timeIntervalSince1970)")
            }
            try Fuzz.check(parsed.sequence == sequence, "sequence \(parsed.sequence) != \(sequence) in \(name)")
            let expected = max(0, date.epochMilliseconds)
            try Fuzz.check(parsed.timestamp.epochMilliseconds == expected,
                           "timestamp \(parsed.timestamp.epochMilliseconds) != clamped \(expected) in \(name)")
            // Lexicographic order is capture order only while the padding holds.
            try Fuzz.check(sequence > 999_999_999 || name.hasPrefix(String(format: "%09ld-", sequence)), "padding lost in \(name)")
        }
    }

    func testLexicographicOrderIsSequenceOrder() {
        Fuzz.run("frameName.order") { rng in
            let a = rng.int(0...999_999_999), b = rng.int(0...999_999_999)
            let t = rng.hostileDate()
            let nameA = FrameSpool.frameName(sequence: a, timestamp: t)
            let nameB = FrameSpool.frameName(sequence: b, timestamp: t)
            try Fuzz.check((a < b) == (nameA < nameB), "\(nameA) vs \(nameB) disagrees with \(a) vs \(b)")
        }
    }

    func testParseFrameNameOnArbitraryStrings() {
        Fuzz.run("frameName.parse") { rng in
            var name: String
            switch rng.int(0...3) {
            case 0:
                name = rng.hostileString()
            case 1:
                // Near misses of the real shape.
                let digits = Array("0123456789")
                let part = { (rng: inout FuzzRNG) in String((0..<rng.int(0...25)).map { _ in rng.pick(digits) }) }
                name = part(&rng) + rng.pick(["-", "--", "", "+", "-+"]) + part(&rng) + rng.pick([".jpg", ".JPG", "jpg", ".jpg.jpg", ""])
            case 2:
                name = rng.pick(["١٢٣-٤٥٦.jpg", "+1-+2.jpg", "1-2-3.jpg", "-1-2.jpg", " 1-2.jpg", "9223372036854775808-1.jpg",
                                 "1-9223372036854775807.jpg", ".jpg", "-.jpg", "0-0.jpg"])
            default:
                name = FrameSpool.frameName(sequence: rng.int(0...1_000), timestamp: rng.hostileDate())
                var chars = Array(name)
                if !chars.isEmpty { chars[rng.int(0...(chars.count - 1))] = rng.pick(FuzzRNG.hostileFragments).first ?? "x" }
                name = String(chars)
            }
            guard let parsed = FrameSpool.parseFrameName(name) else { return }
            try Fuzz.check(parsed.sequence >= 0, "negative sequence \(parsed.sequence) from \(name.debugDescription)")
            try Fuzz.check(parsed.timestamp.timeIntervalSince1970 >= 0, "pre-epoch timestamp from \(name.debugDescription)")
            try Fuzz.check(name.hasSuffix(".jpg"), "accepted a name without the frame extension: \(name.debugDescription)")
        }
    }

    /// `frameName` claims to clamp out-of-range dates. Beyond ~2.9e5 years the
    /// millisecond conversion overflows `Int` and traps instead.
    func testFrameNameClampsDatesBeyondIntMilliseconds() throws {
        let date = Date(timeIntervalSince1970: 1e16)
        let name = FrameSpool.frameName(sequence: 0, timestamp: date)
        XCTAssertNotNil(FrameSpool.parseFrameName(name))
    }
}

// MARK: - 3. NDJSON rows

final class FuzzNDJSONTests: XCTestCase {
    private func checkSingleLine(_ data: Data, _ label: String) throws -> [String: Any] {
        try Fuzz.check(data.last == 0x0A, "\(label): not newline-terminated")
        try Fuzz.check(data.filter { $0 == 0x0A }.count == 1, "\(label): \(data.filter { $0 == 0x0A }.count) newlines")
        guard let object = try? JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any] else {
            throw FuzzFailure(description: "\(label): not a JSON object")
        }
        return object
    }

    /// Dates the warehouse column can hold get an exact check; the rest only need a
    /// well-formed literal.
    private func checkDateTime(_ value: Any?, _ date: Date, _ label: String) throws {
        guard let value = value as? String else { throw FuzzFailure(description: "\(label) missing") }
        try Fuzz.check(matchesDateTime(value), "\(label) \(value.debugDescription) is not yyyy-MM-dd HH:mm:ss.SSS for t=\(date.timeIntervalSince1970)")
        let t = date.timeIntervalSince1970
        if t >= -2_208_988_800, t < 10_413_792_000 {  // 1900-01-01 ..< 2300-01-01
            guard let ms = epochMilliseconds(ofDateTime: value) else { throw FuzzFailure(description: "\(label) unparsable") }
            let expected = (t * 1000).rounded(.down)
            try Fuzz.check(abs(Double(ms) - expected) <= 1, "\(label) \(value) is \(ms) ms, expected \(Int64(expected)) (t=\(t))")
        }
    }

    func testMetaRowIsOneLineOfFaithfulJSON() {
        Fuzz.run("meta.ndjson") { rng in
            let started = rng.hostileDate()
            let now = rng.chance(0.5) ? started.addingTimeInterval(rng.double(0..<100_000)) : rng.hostileDate()
            let status: SessionMetaRow.Status = rng.chance(0.5) ? .active : .ended
            let environment: String? = rng.chance(0.3) ? nil : rng.hostileString()
            let traceIds = (0..<rng.int(0...5)).map { _ in rng.hostileString(maxFragments: 4) }
            let row = SessionMetaRow(
                sessionId: rng.hostileString(), startedAt: started, status: status, version: rng.hostileInt(),
                serviceName: rng.hostileString(), environment: environment, userId: rng.hostileString(),
                recorded: rng.chance(0.5), traceIds: traceIds, clickCount: rng.hostileInt(),
                pageViews: rng.hostileInt(), errorCount: rng.hostileInt(),
                replayTrigger: rng.chance(0.5) ? rng.hostileString() : nil
            )
            let object = try checkSingleLine(try row.ndjson(now: now), "meta")
            try Fuzz.check(object["session_id"] as? String == row.sessionId.fuzzJSONReadBack, "session_id lost: \(row.sessionId.debugDescription)")
            try Fuzz.check(object["user_id"] as? String == row.userId.fuzzJSONReadBack, "user_id lost")
            try Fuzz.check(object["service_name"] as? String == row.serviceName.fuzzJSONReadBack, "service_name lost")
            try Fuzz.check((object["version"] as? NSNumber)?.int64Value == Int64(row.version), "version lost")
            try Fuzz.check(object["status"] as? String == status.rawValue, "status lost")
            try Fuzz.check((object["click_count"] as? NSNumber)?.int64Value == Int64(row.clickCount), "click_count lost")
            let attributes = object["resource_attributes"] as? [String: String] ?? [:]
            try Fuzz.check(attributes["maple.session.recorded"] == (row.recorded ? "true" : "false"), "recorded flag")
            try Fuzz.check(attributes["deployment.environment"] == environment?.fuzzJSONReadBack, "environment lost")
            try Fuzz.check(attributes["maple.session.replay_trigger"] == (row.recorded ? row.replayTrigger?.fuzzJSONReadBack : nil), "trigger gating")
            try checkDateTime(object["start_time"], started, "start_time")
            try checkDateTime(object["last_activity_at"], now, "last_activity_at")
            if status == .ended {
                try checkDateTime(object["end_time"], now, "end_time")
                try Fuzz.check(object["trace_ids"] as? [String] == traceIds.map(\.fuzzJSONReadBack), "trace_ids lost")
                try Fuzz.check(((object["duration_ms"] as? NSNumber)?.int64Value ?? -1) >= 0, "negative duration")
            } else {
                try Fuzz.check(object["end_time"] == nil && object["trace_ids"] == nil, "active row carries ended-only fields")
            }
        }
    }

    func testEventRowIsOneLineOfFaithfulJSON() {
        Fuzz.run("event.ndjson") { rng in
            var attributes: [String: String] = [:]
            for _ in 0..<rng.int(0...6) { attributes[rng.hostileString(maxFragments: 4)] = rng.hostileString(maxFragments: 8) }
            let kinds: [SessionEventRow.Kind] = [.navigation, .click, .input, .console, .network, .error, .custom]
            let date = rng.hostileDate()
            let row = SessionEventRow(
                sessionId: rng.hostileString(), seq: rng.hostileInt(), type: rng.pick(kinds), timestamp: date,
                message: rng.hostileString(), attributes: attributes, traceId: rng.hostileString(maxFragments: 4),
                url: rng.hostileString(), level: rng.hostileString(maxFragments: 3), netMethod: rng.hostileString(maxFragments: 2),
                netUrl: rng.hostileString(), netStatus: rng.hostileInt(), netDurationMs: rng.hostileInt(),
                errorStack: rng.hostileString()
            )
            let object = try checkSingleLine(try row.ndjson(), "event")
            for (key, expected) in [("session_id", row.sessionId), ("message", row.message), ("trace_id", row.traceId),
                                    ("url", row.url), ("level", row.level), ("net_method", row.netMethod),
                                    ("net_url", row.netUrl), ("error_stack", row.errorStack), ("type", row.type.rawValue)] {
                try Fuzz.check(object[key] as? String == expected.fuzzJSONReadBack, "\(key) lost: \(expected.debugDescription)")
            }
            try Fuzz.check((object["seq"] as? NSNumber)?.int64Value == Int64(row.seq), "seq lost")
            try Fuzz.check((object["net_status"] as? NSNumber)?.int64Value == Int64(row.netStatus), "net_status lost")
            // A BOM-only key and "" read back as the same key, so that pair is not comparable.
            let readBackKeys = attributes.keys.map(\.fuzzJSONReadBack)
            if Set(readBackKeys).count == readBackKeys.count {
                let readBack = Dictionary(uniqueKeysWithValues: attributes.map { ($0.key.fuzzJSONReadBack, $0.value.fuzzJSONReadBack) })
                try Fuzz.check(object["attributes"] as? [String: String] == readBack, "attributes lost: \(attributes)")
            }
            try checkDateTime(object["timestamp"], date, "timestamp")
        }
    }

    /// The literal must stay `yyyy-MM-dd HH:mm:ss.SSS` for any `Date`. A year past 9999
    /// prints five digits, which the warehouse cannot parse.
    func testDateTimeLiteralShapeBeyondYear9999() {
        let date = Date(timeIntervalSince1970: 400_000_000_000)  // year ~14645
        let value = SessionMetaRow.clickHouseDateTime(date)
        XCTAssertTrue(matchesDateTime(value), "clickHouseDateTime(\(date.timeIntervalSince1970)) = \(value.debugDescription)")
    }
}

// MARK: - 4. Segment events

final class FuzzSegmentEventsTests: XCTestCase {
    func testCoordinateIsTotalAndBounded() {
        Fuzz.run("coordinate") { rng in
            let value = CGFloat(rng.hostileDouble())
            let result = RRWebEvent.coordinate(value)
            try Fuzz.check(result == reference(coordinate: value), "coordinate(\(value)) = \(result), expected \(reference(coordinate: value))")
        }
    }

    func testBuildOrdersClipsAndScales() {
        Fuzz.run("segmentEvents.build", iterations: Fuzz.iterations(cost: 2)) { rng in
            let width = rng.int(2...2_000), height = rng.int(2...2_000)
            let duration = rng.chance(0.1) ? 0 : rng.double(0..<60)
            let start = Date(timeIntervalSince1970: rng.double(1_000_000_000..<2_000_000_000))
            let video = EncodedVideo(
                url: URL(fileURLWithPath: "/nonexistent/maple-fuzz-\(rng.next()).mp4"),
                byteSize: rng.int(0...1_000_000), width: width, height: height,
                frameCount: rng.int(1...100), frameRate: rng.int(1...10), duration: duration, start: start
            )
            let pointSize: CGSize? = rng.chance(0.3) ? nil : rng.pick([
                CGSize(width: rng.double(1..<2_000), height: rng.double(1..<2_000)),
                CGSize.zero, CGSize(width: -10, height: 5),
            ])
            let interactions: [TouchInteraction] = [.touchStart, .touchMove, .touchEnd]
            let touches = (0..<rng.int(0...30)).map { _ in
                TouchSample(
                    timestamp: start.addingTimeInterval(rng.double(-10..<(duration + 10))),
                    interaction: rng.pick(interactions),
                    location: CGPoint(x: rng.chance(0.1) ? rng.hostileDouble() : rng.double(-50..<2_050),
                                      y: rng.chance(0.1) ? rng.hostileDouble() : rng.double(-50..<2_050))
                )
            }
            let extras = (0..<rng.int(0...5)).map { _ in
                RRWebEvent.breadcrumb(timestamp: start.addingTimeInterval(rng.double(-5..<(duration + 5))),
                                      category: rng.hostileString(maxFragments: 4), message: rng.hostileString(maxFragments: 6))
            }
            let events = SegmentEvents.build(
                sessionId: rng.asciiIdentifier(), chunkSeq: rng.int(0...1_000), video: video, start: start,
                reason: rng.hostileString(maxFragments: 4), pointSize: pointSize, touches: touches, extra: extras
            )

            try Fuzz.check(events.first?.type == .meta, "first event is \(String(describing: events.first?.type))")
            let metaTime = start.epochMilliseconds
            try Fuzz.check(events[0].timestamp == metaTime, "meta timestamp moved")
            for (previous, next) in zip(events.dropFirst(), events.dropFirst(2)) {
                try Fuzz.check(previous.timestamp <= next.timestamp, "timestamps decrease: \(previous.timestamp) > \(next.timestamp)")
            }
            try Fuzz.check(events.allSatisfy { $0.timestamp >= metaTime }, "an event precedes the meta event")

            let end = start.addingTimeInterval(duration)
            let inWindow = touches.filter { $0.timestamp >= start && $0.timestamp <= end }
            let touchEvents = events.filter { $0.type == .incrementalSnapshot }
            try Fuzz.check(touchEvents.count == inWindow.count, "\(touchEvents.count) touch events, \(inWindow.count) touches in window")
            let points = pointSize ?? CGSize(width: width, height: height)
            let scaleX = points.width > 0 ? CGFloat(width) / points.width : 1
            let scaleY = points.height > 0 ? CGFloat(height) / points.height : 1
            let expected = inWindow.map { (reference(coordinate: $0.location.x * scaleX), reference(coordinate: $0.location.y * scaleY)) }
            let actual = touchEvents.map { ($0.data["x"] as? Int ?? .min, $0.data["y"] as? Int ?? .min) }
            try Fuzz.check(Set(expected.map { "\($0.0),\($0.1)" }) == Set(actual.map { "\($0.0),\($0.1)" }),
                           "touch coordinates not in pixel space: \(actual) vs \(expected)")
            for event in touchEvents {
                try Fuzz.check(event.timestamp <= end.epochMilliseconds, "touch after the video window")
            }
            let keptExtras = extras.filter { $0.timestamp >= metaTime }.count
            let breadcrumbs = events.filter { ($0.data["tag"] as? String) == "breadcrumb" }.count
            try Fuzz.check(breadcrumbs == keptExtras + 1, "\(breadcrumbs) breadcrumbs, expected \(keptExtras + 1)")

            // The body that goes over the wire is exactly this array.
            let writer = SegmentWriter(directory: FileManager.default.temporaryDirectory, sessionId: "fuzz", persistToDisk: false)
            let prepared = try writer.prepare(video: video, events: events, chunkSeq: 0, isCheckpoint: true)
            let expectedJSON = try JSONSerialization.data(withJSONObject: events.map(\.json), options: [.sortedKeys])
            try Fuzz.check(Gzip.decompress(prepared.body) == expectedJSON, "blob body does not gunzip to the events")
            try Fuzz.check(foundationInflate(Data(prepared.body.dropFirst(10).dropLast(8))) == expectedJSON, "independent inflate disagrees")
            try Fuzz.check(prepared.artifacts.eventCount == events.count, "eventCount header disagrees")
        }
    }
}

// MARK: - 5. Presentation times

final class FuzzPresentationTimesTests: XCTestCase {
    func testStrictlyIncreasingFromZero() {
        Fuzz.run("presentationTimes") { rng in
            var t = rng.double(0..<2_000_000_000)
            var timestamps: [Date] = []
            for _ in 0..<rng.int(0...60) {
                timestamps.append(Date(timeIntervalSince1970: t))
                switch rng.int(0...5) {
                case 0: t -= rng.double(0..<100)            // clock stepped backwards
                case 1: break                               // duplicate
                case 2: t += rng.double(0..<10_000_000)     // huge gap, past the 1-day clamp
                case 3: t += rng.double(0..<0.002)          // sub-millisecond
                default: t += rng.double(0..<2)
                }
            }
            let frameRate = rng.chance(0.2) ? rng.pick([Int.min, -1, 0]) : rng.int(1...10)
            let (frames, end) = VideoEncoder.presentationTimes(for: timestamps, frameRate: frameRate)
            try Fuzz.check(frames.count == timestamps.count, "\(frames.count) times for \(timestamps.count) frames")
            try Fuzz.check(frames.allSatisfy { $0.timescale == 1000 && $0.isValid }, "invalid CMTime")
            if let first = frames.first { try Fuzz.check(first.value == 0, "first time is \(first.value)") }
            for (a, b) in zip(frames, frames.dropFirst()) {
                try Fuzz.check(a.value < b.value, "not strictly increasing: \(a.value) then \(b.value)")
            }
            try Fuzz.check(end.value > (frames.last?.value ?? -1), "end \(end.value) does not follow last \(String(describing: frames.last?.value))")
            // Never earlier than the frame really happened (within the one-day clamp).
            if let origin = timestamps.first {
                for (date, time) in zip(timestamps, frames) {
                    let elapsed = date.timeIntervalSince(origin) * 1000
                    let raw = Int64(max(0, min(elapsed, 86_400_000)).rounded())
                    try Fuzz.check(time.value >= raw, "frame shown at \(time.value) ms before it was captured at \(raw) ms")
                }
            }
        }
    }
}

// MARK: - 6. Options and sampling

final class FuzzReplayOptionsTests: XCTestCase {
    func testNormalizedLandsInDocumentedRanges() {
        Fuzz.run("options.normalized") { rng in
            var options = ReplayOptions()
            options.frameRate = rng.hostileInt()
            options.sessionSampleRate = rng.hostileDouble()
            options.onErrorSampleRate = rng.hostileDouble()
            options.segmentDuration = rng.hostileDouble()
            options.errorBufferWindow = rng.hostileDouble()
            options.backgroundSessionTimeout = rng.hostileDouble()
            options.maxSpoolBytes = rng.hostileInt()
            options.maxTotalSpoolBytes = rng.hostileInt()
            let n = options.normalized()
            let label = "frameRate=\(options.frameRate) rates=\(options.sessionSampleRate),\(options.onErrorSampleRate) seg=\(options.segmentDuration) window=\(options.errorBufferWindow) timeout=\(options.backgroundSessionTimeout) spool=\(options.maxSpoolBytes),\(options.maxTotalSpoolBytes)"
            try Fuzz.check((1...10).contains(n.frameRate), "frameRate \(n.frameRate): \(label)")
            try Fuzz.check((0...1).contains(n.sessionSampleRate), "sessionSampleRate \(n.sessionSampleRate): \(label)")
            try Fuzz.check((0...1).contains(n.onErrorSampleRate), "onErrorSampleRate \(n.onErrorSampleRate): \(label)")
            try Fuzz.check((1...60).contains(n.segmentDuration), "segmentDuration \(n.segmentDuration): \(label)")
            try Fuzz.check((1...120).contains(n.errorBufferWindow), "errorBufferWindow \(n.errorBufferWindow): \(label)")
            try Fuzz.check((0...86_400).contains(n.backgroundSessionTimeout), "timeout \(n.backgroundSessionTimeout): \(label)")
            try Fuzz.check(n.maxSpoolBytes >= 1024 * 1024, "maxSpoolBytes \(n.maxSpoolBytes): \(label)")
            try Fuzz.check(n.maxTotalSpoolBytes >= n.maxSpoolBytes, "maxTotalSpoolBytes \(n.maxTotalSpoolBytes): \(label)")
            // In-range values pass through untouched.
            if (0...1).contains(options.sessionSampleRate) {
                try Fuzz.check(n.sessionSampleRate == options.sessionSampleRate, "in-range rate changed: \(label)")
            }
            if (1...60).contains(options.segmentDuration) {
                try Fuzz.check(n.segmentDuration == options.segmentDuration, "in-range duration changed: \(label)")
            }
            let twice = n.normalized()
            try Fuzz.check(twice.frameRate == n.frameRate && twice.segmentDuration == n.segmentDuration
                           && twice.errorBufferWindow == n.errorBufferWindow && twice.maxTotalSpoolBytes == n.maxTotalSpoolBytes
                           && twice.backgroundSessionTimeout == n.backgroundSessionTimeout, "normalized() is not idempotent: \(label)")
            // The ring buffer is sized from these; an infinite window would trap here.
            _ = FrameRingBuffer.capacity(forSeconds: n.errorBufferWindow, frameRate: n.frameRate)
        }
    }

    func testRollRespectsRates() {
        Fuzz.run("mode.roll", iterations: Fuzz.iterations(cost: 20, minimum: 5)) { rng in
            var options = ReplayOptions()
            options.sessionSampleRate = rng.chance(0.2) ? rng.pick([0, 1]) : rng.double(0..<1)
            options.onErrorSampleRate = rng.chance(0.2) ? rng.pick([0, 1]) : rng.double(0..<1)
            options = options.normalized()
            let trials = 4_000
            var counts: [ReplayMode: Int] = [:]
            for _ in 0..<trials {
                counts[ReplayMode.roll(options, random: { rng.double(0..<1) }), default: 0] += 1
            }
            let s = options.sessionSampleRate, e = options.onErrorSampleRate
            let expected: [ReplayMode: Double] = [.record: s, .buffer: (1 - s) * e, .off: (1 - s) * (1 - e)]
            for (mode, p) in expected {
                let observed = Double(counts[mode, default: 0]) / Double(trials)
                let sigma = (p * (1 - p) / Double(trials)).squareRoot()
                try Fuzz.check(abs(observed - p) <= 5 * sigma + 1e-9,
                               "\(mode) observed \(observed), expected \(p) for s=\(s) e=\(e)")
            }
            if s == 0, e == 0 { try Fuzz.check(counts[.off] == trials, "both rates 0 must be .off") }
        }
    }
}

// MARK: - 7. Touch tracker and chunk sequencer

final class FuzzTouchTrackerTests: XCTestCase {
    /// Executable restatement of the documented contract, checked op by op.
    private struct Model {
        let capacity: Int
        var samples: [TouchSample] = []
        var lastMove = Date.distantPast

        mutating func record(_ interaction: TouchInteraction, _ point: CGPoint, _ now: Date) {
            guard point.x.isFinite, point.y.isFinite else { return }
            if interaction == .touchMove {
                guard now.timeIntervalSince(lastMove) >= TouchTracker.moveInterval else { return }
                lastMove = now
            }
            samples.append(TouchSample(timestamp: now, interaction: interaction, location: point))
            if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        }
    }

    func testMatchesModel() {
        Fuzz.run("touchTracker.model") { rng in
            let capacity = rng.int(1...40)
            let tracker = TouchTracker(maxSamples: capacity)
            var model = Model(capacity: capacity)
            var clock = Date(timeIntervalSince1970: 1_700_000_000)
            let interactions: [TouchInteraction] = [.touchStart, .touchMove, .touchMove, .touchMove, .touchEnd]
            var log: [String] = []
            for _ in 0..<rng.int(1...120) {
                clock = clock.addingTimeInterval(rng.chance(0.05) ? -rng.double(0..<1) : rng.double(0..<0.2))
                switch rng.int(0...9) {
                case 0...6:
                    let interaction = rng.pick(interactions)
                    let point = CGPoint(x: rng.chance(0.05) ? rng.hostileDouble() : rng.double(0..<500),
                                        y: rng.chance(0.05) ? rng.hostileDouble() : rng.double(0..<900))
                    tracker.record(interaction: interaction, at: point, now: clock)
                    model.record(interaction, point, clock)
                    log.append("record(\(interaction.rawValue))")
                case 7, 8:
                    let end = clock.addingTimeInterval(-rng.double(0..<3))
                    let start = rng.chance(0.5) ? Date.distantPast : end.addingTimeInterval(-rng.double(0..<3))
                    let drained = tracker.drain(until: end, notBefore: start)
                    let expected = model.samples.filter { $0.timestamp <= end && $0.timestamp >= start }
                    model.samples.removeAll { $0.timestamp <= end }
                    log.append("drain")
                    try Fuzz.check(drained == expected, "drain returned \(drained.count), expected \(expected.count) after \(log.suffix(8))")
                default:
                    let cutoff = clock.addingTimeInterval(-rng.double(0..<3))
                    tracker.discard(olderThan: cutoff)
                    model.samples.removeAll { $0.timestamp < cutoff }
                    log.append("discard")
                }
                try Fuzz.check(tracker.count == model.samples.count, "count \(tracker.count) != model \(model.samples.count) after \(log.suffix(8))")
                try Fuzz.check(tracker.count <= capacity, "over capacity")
            }
            let rest = tracker.drain(until: .distantFuture)
            try Fuzz.check(rest == model.samples, "final contents diverge from the model")
            let moves = rest.filter { $0.interaction == .touchMove }
            for (a, b) in zip(moves, moves.dropFirst()) {
                try Fuzz.check(b.timestamp.timeIntervalSince(a.timestamp) >= TouchTracker.moveInterval, "moves closer than the throttle")
            }
        }
    }

    func testChunkSequencerIsUniqueAndGapFreeUnderContention() {
        Fuzz.run("chunkSequencer", iterations: Fuzz.iterations(cost: 20, minimum: 3)) { rng in
            let start = rng.int(0...1_000)
            let sequencer = ChunkSequencer(next: start)
            let threads = rng.int(2...16)
            let perThread = rng.int(50...400)
            let counts = (0..<threads).map { _ in (0..<perThread).map { _ in rng.int(1...4) } }
            let lock = NSLock()
            var ranges: [(Int, Int)] = []
            DispatchQueue.concurrentPerform(iterations: threads) { thread in
                var local: [(Int, Int)] = []
                for count in counts[thread] { local.append((sequencer.take(count), count)) }
                lock.lock(); ranges += local; lock.unlock()
            }
            let total = counts.joined().reduce(0, +)
            var covered = [Bool](repeating: false, count: total)
            for (first, count) in ranges {
                for value in first..<(first + count) {
                    let index = value - start
                    try Fuzz.check(index >= 0 && index < total, "number \(value) outside \(start)..<\(start + total)")
                    try Fuzz.check(!covered[index], "number \(value) handed out twice")
                    covered[index] = true
                }
            }
            try Fuzz.check(covered.allSatisfy { $0 }, "gap in handed-out numbers")
            try Fuzz.check(sequencer.peek == start + total, "peek \(sequencer.peek) != \(start + total)")
        }
    }
}
