import XCTest
@testable import MapleTracing

/// `traceparent` is the entire contract with the backend: get it wrong and a mobile trace
/// and its server continuation are two unrelated traces, which looks exactly like the
/// feature working badly rather than being broken.
final class TraceContextTests: XCTestCase {
    func testRandomIdsAreWellFormed() {
        for _ in 0..<200 {
            let trace = TraceID.random()
            let span = SpanID.random()
            XCTAssertEqual(trace.hex.count, 32)
            XCTAssertEqual(span.hex.count, 16)
            XCTAssertNotEqual(trace.hex, TraceID.invalidHex)
            XCTAssertNotEqual(span.hex, SpanID.invalidHex)
            XCTAssertEqual(trace.hex, trace.hex.lowercased())
        }
    }

    func testAllZeroIdsAreRejected() {
        XCTAssertNil(TraceID(hex: String(repeating: "0", count: 32)))
        XCTAssertNil(SpanID(hex: String(repeating: "0", count: 16)))
    }

    func testUppercaseIsNormalisedNotRejected() {
        // The spec requires lowercase on the wire but a value read back from a header we
        // did not write may be uppercase. Normalising is what keeps a trace joined.
        XCTAssertEqual(TraceID(hex: "4BF92F3577B34DA6A3CE929D0E0E4736")?.hex,
                       "4bf92f3577b34da6a3ce929d0e0e4736")
    }

    func testHeaderRoundTrip() {
        let context = SpanContext(
            traceId: TraceID(hex: "4bf92f3577b34da6a3ce929d0e0e4736")!,
            spanId: SpanID(hex: "00f067aa0ba902b7")!,
            sampled: true
        )
        XCTAssertEqual(context.traceParentHeader, "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")

        let parsed = SpanContext.parse(traceParent: context.traceParentHeader)
        XCTAssertEqual(parsed?.traceId, context.traceId)
        XCTAssertEqual(parsed?.spanId, context.spanId)
        XCTAssertEqual(parsed?.sampled, true)
    }

    func testUnsampledFlag() {
        let context = SpanContext(
            traceId: TraceID.random(),
            spanId: SpanID.random(),
            sampled: false
        )
        XCTAssertTrue(context.traceParentHeader.hasSuffix("-00"))
        XCTAssertEqual(SpanContext.parse(traceParent: context.traceParentHeader)?.sampled, false)
    }

    func testMalformedHeadersAreRejected() {
        let bad = [
            "",
            "00",
            "00-4bf92f3577b34da6a3ce929d0e0e4736",
            // version ff is reserved and invalid
            "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
            // all-zero trace id
            "00-00000000000000000000000000000000-00f067aa0ba902b7-01",
            // all-zero span id
            "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01",
            // trace id too short
            "00-4bf92f3577b34da6a3ce929d0e473-00f067aa0ba902b7-01",
            // non-hex
            "00-4bf92f3577b34da6a3ce929d0e0e473g-00f067aa0ba902b7-01",
            // version 00 must have exactly four fields
            "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra",
        ]
        for header in bad {
            XCTAssertNil(SpanContext.parse(traceParent: header), "should reject \(header)")
        }
    }

    func testFutureVersionWithExtraFieldsIsAccepted() {
        // The spec's forward-compatibility rule: a higher version may carry fields we do
        // not know. Rejecting the header would orphan the trace rather than continue it.
        let parsed = SpanContext.parse(
            traceParent: "01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-whatever"
        )
        XCTAssertEqual(parsed?.traceId.hex, "4bf92f3577b34da6a3ce929d0e0e4736")
        XCTAssertEqual(parsed?.sampled, true)
    }
}
