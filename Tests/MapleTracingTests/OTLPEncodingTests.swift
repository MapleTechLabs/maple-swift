import XCTest
@testable import MapleTracing

/// The gateway parses OTLP/JSON with stricter serde derives than the spec requires of a
/// receiver, so a wrong encoding here is not a warning — it is the whole request refused,
/// silently, from the sender's point of view.
final class OTLPEncodingTests: XCTestCase {
    private func encode(_ spans: [SpanData], resource: [String: AttributeValue] = [:]) throws -> [String: Any] {
        let data = try OTLPEncoder.encode(spans: spans, resource: resource)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func onlySpan(_ payload: [String: Any]) throws -> [String: Any] {
        let resourceSpans = try XCTUnwrap(payload["resourceSpans"] as? [[String: Any]])
        let scopeSpans = try XCTUnwrap(resourceSpans[0]["scopeSpans"] as? [[String: Any]])
        let spans = try XCTUnwrap(scopeSpans[0]["spans"] as? [[String: Any]])
        return spans[0]
    }

    private func makeSpan(
        status: SpanStatus = .unset,
        attributes: [String: AttributeValue] = [:],
        parent: SpanID? = SpanID.random(),
        events: [SpanEvent] = [],
        resourceOverrides: [String: AttributeValue] = [:]
    ) -> SpanData {
        let start = Date(timeIntervalSince1970: 1_755_000_000.123456)
        return SpanData(
            context: SpanContext(traceId: TraceID.random(), spanId: SpanID.random(), sampled: true),
            parentSpanId: parent,
            name: "GET",
            kind: .client,
            startTime: start,
            endTime: start.addingTimeInterval(0.25),
            attributes: attributes,
            status: status,
            events: events,
            resourceOverrides: resourceOverrides
        )
    }

    private func resourceGroups(_ payload: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(payload["resourceSpans"] as? [[String: Any]])
    }

    private func resourceAttributes(_ group: [String: Any]) throws -> [String: Any] {
        let resource = try XCTUnwrap(group["resource"] as? [String: Any])
        let attributes = try XCTUnwrap(resource["attributes"] as? [[String: Any]])
        return Dictionary(uniqueKeysWithValues: attributes.map { entry in
            let value = entry["value"] as? [String: Any]
            return (entry["key"] as! String, value?["stringValue"] ?? value as Any)
        })
    }

    func testTimestampsAreDecimalStrings() throws {
        let span = try onlySpan(try encode([makeSpan()]))
        let start = try XCTUnwrap(span["startTimeUnixNano"] as? String)
        let end = try XCTUnwrap(span["endTimeUnixNano"] as? String)
        XCTAssertTrue(start.allSatisfy(\.isNumber))
        XCTAssertEqual(start.count, 19)
        // 250ms apart, and not rounded away by a Double round trip.
        XCTAssertEqual(UInt64(end)! - UInt64(start)!, 250_000_000)
    }

    func testNanosecondsAddNoErrorBeyondDateItself() {
        // `Date` is a `Double` of seconds, so ~240ns of resolution at a 2026 epoch is the
        // ceiling and no encoder can beat it. What is being asserted is that the encoder
        // does not make it worse: the naive `interval * 1e9` lands past 2^53, where the
        // spacing is 256ns, and rounds a second time on top of Date's own rounding.
        let base = Date(timeIntervalSince1970: 1_755_000_000)
        let plusOneMs = base.addingTimeInterval(0.001)
        let delta = UInt64(OTLPEncoder.nanoseconds(plusOneMs))! - UInt64(OTLPEncoder.nanoseconds(base))!
        XCTAssertEqual(Double(delta), 1_000_000, accuracy: 500)

        // Ordering is exact even at sub-microsecond separations, which is what a span
        // waterfall actually depends on.
        var previous = UInt64(0)
        for step in 0..<50 {
            let value = UInt64(OTLPEncoder.nanoseconds(base.addingTimeInterval(Double(step) * 0.000_001)))!
            XCTAssertGreaterThan(value, previous)
            previous = value
        }
    }

    func testIntAttributesAreStrings() throws {
        let span = try onlySpan(try encode([makeSpan(attributes: [
            "http.response.status_code": .int(200),
        ])]))
        let attributes = try XCTUnwrap(span["attributes"] as? [[String: Any]])
        let value = try XCTUnwrap(attributes.first?["value"] as? [String: Any])
        XCTAssertEqual(value["intValue"] as? String, "200")
    }

    func testEveryAttributeKindEncodes() throws {
        let span = try onlySpan(try encode([makeSpan(attributes: [
            "s": .string("x"),
            "i": .int(-1),
            "d": .double(1.5),
            "b": .bool(true),
            "a": .stringArray(["one", "two"]),
        ])]))
        let attributes = try XCTUnwrap(span["attributes"] as? [[String: Any]])
        // Sorted by key, which is what makes this assertable at all.
        XCTAssertEqual(attributes.map { $0["key"] as? String }, ["a", "b", "d", "i", "s"])
        let array = try XCTUnwrap(attributes[0]["value"] as? [String: Any])
        let arrayValue = try XCTUnwrap(array["arrayValue"] as? [String: Any])
        XCTAssertEqual((arrayValue["values"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((attributes[1]["value"] as? [String: Any])?["boolValue"] as? Bool, true)
        XCTAssertEqual((attributes[2]["value"] as? [String: Any])?["doubleValue"] as? Double, 1.5)
        XCTAssertEqual((attributes[3]["value"] as? [String: Any])?["intValue"] as? String, "-1")
        XCTAssertEqual((attributes[4]["value"] as? [String: Any])?["stringValue"] as? String, "x")
    }

    func testStatusCodes() throws {
        XCTAssertEqual(
            (try onlySpan(try encode([makeSpan(status: .unset)]))["status"] as? [String: Any])?["code"] as? Int, 0)
        XCTAssertEqual(
            (try onlySpan(try encode([makeSpan(status: .ok)]))["status"] as? [String: Any])?["code"] as? Int, 1)
        let error = try XCTUnwrap(try onlySpan(try encode([makeSpan(status: .error("HTTP 500"))]))["status"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, 2)
        XCTAssertEqual(error["message"] as? String, "HTTP 500")
    }

    func testRootSpanOmitsParent() throws {
        let span = try onlySpan(try encode([makeSpan(parent: nil)]))
        XCTAssertNil(span["parentSpanId"])
    }

    func testResourceDualEmitsEnvironment() throws {
        var options = TracingOptions()
        options.serviceName = "acme-ios"
        options.environment = "production"
        let resource = ResourceAttributes.build(options: options)

        // The legacy key is pre-extracted by the Tinybird MVs; the canonical one is OTel
        // semconv. Dropping either silently loses environment filtering somewhere.
        XCTAssertEqual(resource["deployment.environment"], .string("production"))
        XCTAssertEqual(resource["deployment.environment.name"], .string("production"))
        XCTAssertEqual(resource["service.name"], .string("acme-ios"))
        XCTAssertEqual(resource["maple.sdk.type"], .string("ios"))
        // Never a resource attribute: sessions rotate under a fixed resource.
        XCTAssertNil(resource["session.id"])
    }

    // MARK: - Events

    func testSpanWithoutEventsOmitsTheKey() throws {
        let span = try onlySpan(try encode([makeSpan()]))
        XCTAssertNil(span["events"])
    }

    func testExceptionEventEncoding() throws {
        let at = Date(timeIntervalSince1970: 1_755_000_000.5)
        let span = try onlySpan(try encode([makeSpan(
            status: .error("EXC_BAD_ACCESS (SIGSEGV)"),
            events: [ExceptionSemantics.event(
                type: "EXC_BAD_ACCESS",
                message: "EXC_BAD_ACCESS (SIGSEGV)",
                stacktrace: "0   MyApp   0x104a2c1f0",
                timestamp: at
            )]
        )]))

        let events = try XCTUnwrap(span["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["name"] as? String, "exception")
        // Same 64-bit rule as the span's own timestamps: a decimal string, not a number.
        let time = try XCTUnwrap(events[0]["timeUnixNano"] as? String)
        XCTAssertEqual(time, OTLPEncoder.nanoseconds(at))

        let attributes = try XCTUnwrap(events[0]["attributes"] as? [[String: Any]])
        let byKey = Dictionary(uniqueKeysWithValues: attributes.map {
            ($0["key"] as! String, ($0["value"] as! [String: Any])["stringValue"] as! String)
        })
        XCTAssertEqual(byKey["exception.type"], "EXC_BAD_ACCESS")
        XCTAssertEqual(byKey["exception.message"], "EXC_BAD_ACCESS (SIGSEGV)")
        XCTAssertEqual(byKey["exception.stacktrace"], "0   MyApp   0x104a2c1f0")

        // The MV keys on Error status AND the event; encoding one without the other
        // produces no error row at all.
        let status = try XCTUnwrap(span["status"] as? [String: Any])
        XCTAssertEqual(status["code"] as? Int, 2)
    }

    func testExceptionEventOmitsEmptyStacktrace() throws {
        let event = ExceptionSemantics.event(
            type: "T", message: "m", stacktrace: nil, timestamp: Date()
        )
        XCTAssertNil(event.attributes["exception.stacktrace"])
    }

    // MARK: - Resource overrides

    func testSpansWithoutOverridesStayInOneGroup() throws {
        let payload = try encode([makeSpan(), makeSpan()], resource: ["service.name": .string("app")])
        let groups = try resourceGroups(payload)
        XCTAssertEqual(groups.count, 1)
    }

    func testOverrideSplitsGroupsAndMergesOntoTheBaseResource() throws {
        let base: [String: AttributeValue] = [
            "service.name": .string("ios-app"),
            "service.version": .string("2.0.0"),
            "deployment.environment": .string("production"),
        ]
        let payload = try encode(
            [makeSpan(), makeSpan(resourceOverrides: ["service.version": .string("1.4.2")])],
            resource: base
        )

        let groups = try resourceGroups(payload)
        XCTAssertEqual(groups.count, 2)

        let live = try resourceAttributes(groups[0])
        XCTAssertEqual(live["service.version"] as? String, "2.0.0")

        let crash = try resourceAttributes(groups[1])
        XCTAssertEqual(crash["service.version"] as? String, "1.4.2")
        // The merged resource, not the diff — a group restating only the override would
        // lose the environment and the service name the warehouse reads off it.
        XCTAssertEqual(crash["service.name"] as? String, "ios-app")
        XCTAssertEqual(crash["deployment.environment"] as? String, "production")
    }

    func testSpansSharingAnOverrideShareAGroup() throws {
        let override: [String: AttributeValue] = ["service.version": .string("1.4.2")]
        let payload = try encode(
            [makeSpan(resourceOverrides: override), makeSpan(resourceOverrides: override)],
            resource: ["service.name": .string("app")]
        )
        let groups = try resourceGroups(payload)
        XCTAssertEqual(groups.count, 1)
        let scopeSpans = try XCTUnwrap(groups[0]["scopeSpans"] as? [[String: Any]])
        XCTAssertEqual((scopeSpans[0]["spans"] as? [[String: Any]])?.count, 2)
    }
}
