import XCTest
@testable import MapleReplay

final class RRWebEventTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000.25)

    func testMetaEventShape() {
        let json = RRWebEvent.meta(
            timestamp: timestamp, width: 390, height: 844, href: "maple://replay/abc"
        ).json

        XCTAssertEqual(json["type"] as? Int, 4)
        // rrweb timestamps are integer milliseconds, not seconds.
        XCTAssertEqual(json["timestamp"] as? Int, 1_700_000_000_250)

        let data = json["data"] as? [String: Any]
        XCTAssertEqual(data?["width"] as? Int, 390)
        XCTAssertEqual(data?["height"] as? Int, 844)
        XCTAssertEqual(data?["href"] as? String, "maple://replay/abc")
    }

    /// The video event is the whole reason this format works: a player that understands
    /// rrweb custom events can carry a mobile segment with no schema change anywhere in
    /// the pipeline. The field names and units match Sentry's `SentryRRWebVideoEvent`.
    func testVideoEventMatchesTheDocumentedContract() {
        let json = RRWebEvent.video(
            timestamp: timestamp,
            segmentId: 3,
            size: 40_960,
            durationMs: 5_000,
            width: 390,
            height: 844,
            frameCount: 5,
            frameRate: 1,
            base64: "AAAA"
        ).json

        XCTAssertEqual(json["type"] as? Int, 5)

        let data = json["data"] as? [String: Any]
        XCTAssertEqual(data?["tag"] as? String, "video")

        let payload = data?["payload"] as? [String: Any]
        XCTAssertEqual(payload?["segmentId"] as? Int, 3)
        XCTAssertEqual(payload?["size"] as? Int, 40_960)
        XCTAssertEqual(payload?["duration"] as? Int, 5_000)
        XCTAssertEqual(payload?["encoding"] as? String, "h264")
        XCTAssertEqual(payload?["container"] as? String, "mp4")
        XCTAssertEqual(payload?["frameRateType"] as? String, "constant")
        XCTAssertEqual(payload?["frameRate"] as? Int, 1)
        XCTAssertEqual(payload?["frameCount"] as? Int, 5)
        XCTAssertEqual(payload?["left"] as? Int, 0)
        XCTAssertEqual(payload?["top"] as? Int, 0)
        XCTAssertEqual(payload?["base64"] as? String, "AAAA")
    }

    func testTouchEventUsesMouseInteractionSource() {
        let json = RRWebEvent.touch(
            timestamp: timestamp, interaction: .touchStart, x: 12.6, y: 40.2
        ).json

        XCTAssertEqual(json["type"] as? Int, 3)
        let data = json["data"] as? [String: Any]
        XCTAssertEqual(data?["source"] as? Int, 2)
        XCTAssertEqual(data?["type"] as? Int, 7)
        XCTAssertEqual(data?["pointerType"] as? Int, 2)
        XCTAssertEqual(data?["x"] as? Int, 13)
        XCTAssertEqual(data?["y"] as? Int, 40)
    }

    func testEveryEventSerialisesToJSON() throws {
        let events: [RRWebEvent] = [
            .meta(timestamp: timestamp, width: 10, height: 20, href: "x"),
            .video(timestamp: timestamp, segmentId: 0, size: 1, durationMs: 1,
                   width: 10, height: 20, frameCount: 1, frameRate: 1, base64: "AA"),
            .touch(timestamp: timestamp, interaction: .touchEnd, x: 1, y: 2),
            .breadcrumb(timestamp: timestamp, category: "replay.segment", message: "interval"),
        ]
        let data = try JSONSerialization.data(withJSONObject: events.map(\.json))
        let decoded = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertEqual(decoded?.count, 4)
    }
}

final class GzipTests: XCTestCase {
    /// Standard CRC-32 check vector. Gets the polynomial and bit order right, which is
    /// the part of a hand-rolled gzip most likely to be silently wrong — a bad CRC still
    /// produces a plausible-looking file that only fails at the far end of the pipeline.
    func testCRC32KnownVector() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }

    func testGzipHeaderAndTrailer() throws {
        let payload = Data(String(repeating: "maple replay ", count: 200).utf8)
        let gzipped = try XCTUnwrap(Gzip.compress(payload))

        XCTAssertEqual(Array(gzipped.prefix(3)), [0x1F, 0x8B, 0x08], "gzip magic + deflate method")

        // ISIZE trailer is the uncompressed length mod 2^32, little-endian.
        let isize = gzipped.suffix(4).reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        XCTAssertEqual(isize, UInt32(payload.count))

        // CRC32 trailer sits immediately before ISIZE.
        let crcBytes = gzipped.dropLast(4).suffix(4)
        let crc = crcBytes.reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        XCTAssertEqual(crc, CRC32.checksum(payload))

        XCTAssertLessThan(gzipped.count, payload.count, "repetitive input should compress")
    }

    func testEmptyInputIsRejected() {
        XCTAssertNil(Gzip.compress(Data()))
    }
}

final class SessionIdTests: XCTestCase {
    /// Mirrors `is_safe_replay_id` in the ingest gateway. Getting this wrong surfaces as
    /// a 400 at upload time, long after the id has been baked into filenames and rows.
    func testGatewaySafety() {
        XCTAssertTrue(SegmentWriter.isSafeSessionId(UUID().uuidString))
        XCTAssertTrue(SegmentWriter.isSafeSessionId("abc_123-DEF"))
        XCTAssertTrue(SegmentWriter.isSafeSessionId(String(repeating: "a", count: 128)))

        XCTAssertFalse(SegmentWriter.isSafeSessionId(""))
        XCTAssertFalse(SegmentWriter.isSafeSessionId(String(repeating: "a", count: 129)))
        XCTAssertFalse(SegmentWriter.isSafeSessionId("has spaces"))
        XCTAssertFalse(SegmentWriter.isSafeSessionId("{braced-uuid}"))
        XCTAssertFalse(SegmentWriter.isSafeSessionId("colon:separated"))
        XCTAssertFalse(SegmentWriter.isSafeSessionId("emoji-🎬"))
    }

    /// Generated ids must be lowercase.
    ///
    /// Regression: `UUID().uuidString` is uppercase on Apple platforms, JavaScript's
    /// `crypto.randomUUID()` is lowercase, and the backend's `srep_…` public-id codec
    /// decodes through lowercase hex — so an uppercase id is written to the warehouse
    /// verbatim and then looked up in lowercase, matching nothing. Verified against
    /// production: 10 chunks stored under the uppercase id, 0 found under the lowercase
    /// one the API asked for. Nothing rejected it anywhere along the way.
    func testGeneratedSessionIdIsLowercase() {
        for _ in 0..<32 {
            let id = SegmentWriter.newSessionId()
            XCTAssertEqual(id, id.lowercased(), "session ids must be lowercase to survive the public-id round trip")
            XCTAssertTrue(SegmentWriter.isSafeSessionId(id))
        }
    }

    /// The validator deliberately accepts uppercase — it mirrors the gateway, which
    /// does too. This documents that validation is not what protects the round trip.
    func testValidatorStillAcceptsUppercase() {
        XCTAssertTrue(SegmentWriter.isSafeSessionId("3F6C4A43-FB6E-445F-B5FD-94B16604D416"))
    }

    func testBlobHeadersMatchTheGatewayContract() {
        let headers = SegmentWriter.headers(
            sessionId: "abc", chunkSeq: 7, isCheckpoint: true, eventCount: 4, durationMs: 5_000
        )
        XCTAssertEqual(headers["x-maple-session-id"], "abc")
        XCTAssertEqual(headers["x-maple-chunk-seq"], "7")
        XCTAssertEqual(headers["x-maple-is-checkpoint"], "1")
        XCTAssertEqual(headers["x-maple-event-count"], "4")
        XCTAssertEqual(headers["x-maple-duration-ms"], "5000")
    }
}

final class SessionMetaRowTests: XCTestCase {
    private func row(status: SessionMetaRow.Status) -> SessionMetaRow {
        SessionMetaRow(
            sessionId: "session-1",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: status,
            version: status == .active ? 1 : 2,
            serviceName: "demo-ios",
            environment: "development",
            userId: "",
            recorded: true
        )
    }

    func testClickHouseDateTimeIsUTCWithMilliseconds() {
        let formatted = SessionMetaRow.clickHouseDateTime(Date(timeIntervalSince1970: 1_700_000_000.25))
        XCTAssertEqual(formatted, "2023-11-14 22:13:20.250")
    }

    /// The backing table replaces whole rows rather than merging fields, so anything
    /// present only on the `ended` row is lost for every session that dies without a
    /// clean shutdown — on mobile, most of them.
    func testAnalyticsFieldsArePresentOnTheActiveRow() {
        let json = row(status: .active).json()
        for key in ["visitor_id", "user_email", "click_count", "page_views", "error_count", "language"] {
            XCTAssertNotNil(json[key], "\(key) must be on the base row, not only on `ended`")
        }
        XCTAssertNil(json["end_time"])
        XCTAssertNil(json["duration_ms"])
    }

    func testEndedRowAddsTerminalFields() {
        let json = row(status: .ended).json(now: Date(timeIntervalSince1970: 1_700_000_030))
        XCTAssertEqual(json["status"] as? String, "ended")
        XCTAssertEqual(json["version"] as? Int, 2)
        XCTAssertEqual(json["duration_ms"] as? Int, 30_000)
    }

    func testResourceAttributesDualEmitEnvironment() {
        let json = row(status: .active).json()
        let attributes = json["resource_attributes"] as? [String: String]
        XCTAssertEqual(attributes?["maple.session.recorded"], "true")
        // Legacy key is pre-extracted by the Tinybird MVs; canonical is OTel semconv.
        XCTAssertEqual(attributes?["deployment.environment"], "development")
        XCTAssertEqual(attributes?["deployment.environment.name"], "development")
    }

    /// The marker that tells the web player to use its video engine.
    ///
    /// This must be present on BOTH the active and ended rows. The backing table is a
    /// ReplacingMergeTree that replaces whole rows, so a marker on only one of them is
    /// lost the moment the other wins.
    ///
    /// Regression: without this key the player defaulted to rrweb — the documented
    /// meaning of an absent marker — and rendered nothing, because rrweb needs a
    /// FullSnapshot that a video recording never produces. Nothing failed; the surface
    /// was simply blank, which is why it needs a test rather than vigilance.
    func testReplayFormatMarkerIsAlwaysVideo() {
        for status in [SessionMetaRow.Status.active, .ended] {
            let attributes = row(status: status).json()["resource_attributes"] as? [String: String]
            XCTAssertEqual(
                attributes?["maple.session.replay_format"], "video",
                "\(status.rawValue) row must carry the video marker"
            )
        }
    }

    func testGatewayDerivedFieldsAreNotSent() {
        let json = row(status: .active).json()
        // One normalisation at the gateway covers every SDK version in the wild.
        XCTAssertNil(json["referrer_host"])
        XCTAssertNil(json["country"])
    }

    func testNDJSONIsNewlineTerminated() throws {
        let data = try row(status: .active).ndjson()
        XCTAssertEqual(data.last, 0x0A)
        let line = data.dropLast()
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: line))
    }
}
