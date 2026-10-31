import Foundation
import MapleCore
import XCTest
@testable import MapleTracing

// MARK: - 11. traceparent

/// Reference parser for the documented rules, checking hex by Unicode scalar value. The
/// SDK checks `Character`s, and a `Character` range test is a collation test, not a
/// code-point test.
private func referenceTraceParent(_ header: String) -> (trace: String, span: String, sampled: Bool)? {
    func isHex(_ value: String, count: Int) -> Bool {
        value.unicodeScalars.count == count && value.unicodeScalars.allSatisfy {
            ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0)
        }
    }
    let fields = header.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false).map(String.init)
    guard fields.count >= 4, isHex(fields[0], count: 2) else { return nil }
    let version = fields[0].lowercased()
    guard version != "ff", version != "00" || fields.count == 4 else { return nil }
    guard isHex(fields[1], count: 32), fields[1].lowercased() != String(repeating: "0", count: 32),
          isHex(fields[2], count: 16), fields[2].lowercased() != String(repeating: "0", count: 16),
          isHex(fields[3], count: 2), let flags = UInt8(fields[3], radix: 16) else { return nil }
    return (fields[1].lowercased(), fields[2].lowercased(), flags & 1 == 1)
}

private func hex(_ rng: inout FuzzRNG, bytes: Int) -> String {
    let digits = Array("0123456789abcdef")
    var out = ""
    repeat {
        out = String((0..<(bytes * 2)).map { _ in digits[rng.int(0...15)] })
    } while out.allSatisfy { $0 == "0" }
    return out
}

final class FuzzTraceParentTests: XCTestCase {
    func testFormatParseRoundTrip() {
        Fuzz.run("traceparent.roundtrip") { rng in
            let trace = hex(&rng, bytes: 16), span = hex(&rng, bytes: 8)
            guard let traceId = TraceID(hex: trace), let spanId = SpanID(hex: span) else {
                throw FuzzFailure(description: "valid ids rejected: \(trace) \(span)")
            }
            let context = SpanContext(traceId: traceId, spanId: spanId, sampled: rng.chance(0.5))
            let header = context.traceParentHeader
            try Fuzz.check(header.utf8.count == 55, "header \(header) is not 55 bytes")
            var inbound = rng.chance(0.3) ? header.uppercased() : header
            if rng.chance(0.3) { inbound = rng.pick([" ", "\t", "  "]) + inbound + rng.pick([" ", "\t", ""]) }
            guard let parsed = SpanContext.parse(traceParent: inbound) else { throw FuzzFailure(description: "rejected \(inbound.debugDescription)") }
            try Fuzz.check(parsed.traceId == traceId && parsed.spanId == spanId && parsed.sampled == context.sampled,
                           "round trip changed \(header) into \(parsed.traceParentHeader)")
        }
    }

    func testParserMatchesReferenceOnMutatedHeaders() {
        Fuzz.run("traceparent.mutated") { rng in
            let flags = String(format: "%02x", rng.int(0...255))
            var header = "\(rng.pick(["00", "00", "01", "fe", "ff", "FF", "0A", "0g", "", "000"]))-\(hex(&rng, bytes: 16))-\(hex(&rng, bytes: 8))-\(flags)"
            if rng.chance(0.1) { header = "00-\(String(repeating: "0", count: 32))-\(hex(&rng, bytes: 8))-01" }
            var chars = Array(header)
            for _ in 0..<rng.int(0...3) {
                let replacements = ["0\u{301}", "a\u{301}", "A", "F", "G", "ａ", "\u{212A}", "İ", "٣", "-", "", " ", "\n", "\u{0}", "ff", "--"]
                switch rng.int(0...2) {
                case 0 where !chars.isEmpty:
                    chars[rng.int(0...(chars.count - 1))] = rng.pick(replacements).first ?? "x"
                case 1 where !chars.isEmpty:
                    chars.remove(at: rng.int(0...(chars.count - 1)))
                default:
                    chars.insert(contentsOf: Array(rng.pick(replacements)), at: rng.int(0...chars.count))
                }
            }
            header = String(chars)
            if rng.chance(0.2) { header += rng.pick(["-", "-extra", "-00-00", "\t"]) }

            let parsed = SpanContext.parse(traceParent: header)
            let expected = referenceTraceParent(header)
            if let parsed {
                // Whatever the parser accepts must be re-emittable as a valid header.
                try Fuzz.check(parsed.traceId.hex.utf8.count == 32 && parsed.spanId.hex.utf8.count == 16,
                               "accepted \(header.debugDescription) and stored non-ASCII ids \(parsed.traceId.hex.debugDescription)/\(parsed.spanId.hex.debugDescription)")
            }
            try Fuzz.check((parsed == nil) == (expected == nil),
                           "parse(\(header.debugDescription)) = \(parsed.map { $0.traceParentHeader } ?? "nil"), reference \(expected.map { "\($0)" } ?? "nil")")
            if let parsed, let expected {
                try Fuzz.check(parsed.traceId.hex == expected.trace && parsed.spanId.hex == expected.span && parsed.sampled == expected.sampled,
                               "fields differ for \(header.debugDescription)")
            }
        }
    }

    /// Minimised from the fuzzer: a combining mark after a hex digit forms one
    /// `Character` that sorts inside `"0"..."9"`, so the id passes validation.
    func testCombiningMarkIsNotAHexDigit() {
        let header = "00-4bf92f3577b34da6a3ce929d0e0e473\u{0036}\u{0301}-00f067aa0ba902b7-01"
        let parsed = SpanContext.parse(traceParent: header)
        XCTAssertNil(parsed, "accepted trace id \(parsed?.traceId.hex.debugDescription ?? ""), re-emitted as \(parsed?.traceParentHeader.debugDescription ?? "")")
        XCTAssertNil(TraceID(hex: "4bf92f3577b34da6a3ce929d0e0e473a\u{0301}"))
    }
}

// MARK: - 12. Crash report parser

final class FuzzCrashReportParserTests: XCTestCase {
    private static let signalNames: Set<String> = ["SIGILL", "SIGTRAP", "SIGABRT", "SIGFPE", "SIGKILL", "SIGBUS", "SIGSEGV", "SIGPIPE", "SIGTERM"]

    /// The fixture shape from CrashReportTests, as a mutable tree.
    private func fixture(frames: Int = 3) -> [String: Any] {
        var leaf: [String: Any] = ["binaryUUID": "22222222-2222-2222-2222-222222222222", "binaryName": "MyApp",
                                   "address": 4_363_200_000, "offsetIntoBinaryTextSegment": 119_024]
        for depth in 1..<max(1, frames) {
            leaf = ["binaryUUID": "11111111-1111-1111-1111-11111111111\(depth % 10)", "binaryName": "lib\(depth).dylib",
                    "address": 7_000_000_000 + depth, "offsetIntoBinaryTextSegment": 4096 * depth, "subFrames": [leaf]]
        }
        return [
            "timeStampBegin": "2026-08-19 12:00:00 +0000",
            "timeStampEnd": "2026-08-20 09:30:00 +0000",
            "crashDiagnostics": [[
                "version": "1.0.0",
                "diagnosticMetaData": [
                    "appVersion": "1.4.2", "appBuildVersion": "318", "osVersion": "iPhone OS 18.0 (22A123)",
                    "deviceType": "iPhone17,1", "platformArchitecture": "arm64e", "exceptionType": 1,
                    "exceptionCode": 0, "signal": 11, "terminationReason": "Namespace SIGNAL, Code 0xb",
                    "virtualMemoryRegionInfo": "0x0000000000000010 is not in any region",
                ],
                "callStackTree": ["callStackPerThread": true, "callStacks": [["threadAttributed": true, "callStackRootFrames": [leaf]]]],
            ]],
        ]
    }

    /// Apply one structural mutation at a random depth.
    private func mutate(_ value: Any, _ rng: inout FuzzRNG, depth: Int = 0) -> Any {
        if depth > 0, rng.chance(0.15) { return rng.jsonValue(depth: 2) }
        if var object = value as? [String: Any], !object.isEmpty {
            let key = rng.pick(Array(object.keys))
            switch rng.int(0...5) {
            case 0: object.removeValue(forKey: key)
            case 1: object[key] = rng.pick([NSNull(), "string", -1, UInt64.max, Int.min, 1e300, true, [] as [Any], [:] as [String: Any]] as [Any])
            case 2: object[rng.hostileString(maxFragments: 3)] = rng.jsonValue(depth: 2)
            default: object[key] = mutate(object[key]!, &rng, depth: depth + 1)
            }
            return object
        }
        if var array = value as? [Any], !array.isEmpty {
            let index = rng.int(0...(array.count - 1))
            switch rng.int(0...3) {
            case 0: array.remove(at: index)
            case 1: array = Array(repeating: array[index], count: rng.int(2...2_000))  // huge arrays
            default: array[index] = mutate(array[index], &rng, depth: depth + 1)
            }
            return array
        }
        return rng.jsonValue(depth: 1)
    }

    private func checkReports(_ reports: [CrashReport], maxCount: Int, label: String) throws {
        try Fuzz.check(reports.count <= maxCount, "\(reports.count) reports from \(maxCount) diagnostics: \(label)")
        for report in reports {
            try Fuzz.check(report.frames.count <= CrashReportParser.maxFrames, "\(report.frames.count) frames: \(label)")
            try Fuzz.check(!report.exceptionType.isEmpty && report.message.hasPrefix(report.exceptionType), "message \(report.message.debugDescription): \(label)")
            try Fuzz.check(report.signal.map { Self.signalNames.contains($0) } ?? true, "signal \(String(describing: report.signal))")
            if !report.frames.isEmpty { try Fuzz.check(report.stacktrace.hasPrefix("0   "), "stacktrace not indexed: \(label)") }
            // The report becomes a span; anything here that the encoder cannot serialise
            // is a crash at export time, not a dropped report.
            let span = CrashSpanBuilder.span(for: report, sessionId: "fuzz")
            try Fuzz.check(JSONSerialization.isValidJSONObject(OTLPEncoder.payload(spans: [span], resource: [:])), "crash span not encodable: \(label)")
        }
    }

    func testParserOnMutatedPayloads() {
        Fuzz.run("crashParser.mutated", iterations: Fuzz.iterations(cost: 2)) { rng in
            var tree: Any = fixture(frames: rng.int(1...(rng.chance(0.1) ? 300 : 8)))
            var log: [String] = []
            for _ in 0..<rng.int(1...6) { tree = mutate(tree, &rng); log.append("mutate") }
            guard JSONSerialization.isValidJSONObject(tree), let data = try? JSONSerialization.data(withJSONObject: tree) else { return }
            let reports = CrashReportParser.reports(fromPayload: data)
            let diagnostics = ((tree as? [String: Any])?["crashDiagnostics"] as? [Any])?.count ?? 0
            try checkReports(reports, maxCount: diagnostics, label: String(decoding: data.prefix(300), as: UTF8.self))
        }
    }

    func testParserOnHostileBytes() {
        Fuzz.run("crashParser.bytes") { rng in
            let data: Data
            switch rng.int(0...3) {
            case 0: data = rng.bytes(rng.int(0...2_000))
            case 1:
                // Deep nesting written as text, past what a recursive walker survives.
                let depth = rng.int(100...5_000)
                let open = String(repeating: #"{"subFrames":["#, count: depth)
                let close = String(repeating: "]}", count: depth)
                data = Data(#"{"crashDiagnostics":[{"callStackTree":{"callStacks":[{"callStackRootFrames":["#.utf8)
                    + Data((open + #"{"binaryName":"x"}"# + close).utf8) + Data("]}]}}]}".utf8)
            case 2:
                let valid = try JSONSerialization.data(withJSONObject: fixture())
                data = valid.prefix(rng.int(0...valid.count))
            default:
                var valid = try JSONSerialization.data(withJSONObject: fixture())
                for _ in 0..<rng.int(1...10) { valid[rng.int(0...(valid.count - 1))] = UInt8(rng.int(0...255)) }
                data = valid
            }
            let reports = CrashReportParser.reports(fromPayload: data)
            try checkReports(reports, maxCount: Int.max, label: "\(data.count) bytes")
        }
    }

    /// The crash timestamp comes straight from the payload, so any year can reach the OTLP
    /// encoder, which must clamp it into a UInt64 of nanoseconds rather than trap or wrap.
    func testCrashTimestampsAreExportable() {
        Fuzz.run("crashParser.timestamp") { rng in
            let year = rng.chance(0.5) ? rng.int(1...9999) : rng.int(1960...2100)
            let stamp = String(format: "%04d-%02d-%02d %02d:%02d:%02d %@", year, rng.int(1...12), rng.int(1...28),
                               rng.int(0...23), rng.int(0...59), rng.int(0...59), rng.pick(["+0000", "-1200", "+1400"]))
            var payload = fixture()
            payload["timeStampEnd"] = stamp
            let reports = CrashReportParser.reports(fromPayload: try JSONSerialization.data(withJSONObject: payload))
            for report in reports {
                let seconds = report.timestamp.timeIntervalSince1970
                let encoded = OTLPEncoder.nanoseconds(report.timestamp)
                guard let nanos = UInt64(encoded) else {
                    throw FuzzFailure(description: "timeStampEnd \(stamp.debugDescription) encoded as \(encoded)")
                }
                let expected = min(max(0, seconds), 18_446_744_072) * 1e9
                try Fuzz.check(abs(Double(nanos) - expected) <= max(1e6, expected * 1e-12), "timeStampEnd \(stamp.debugDescription) t=\(seconds) encoded \(nanos), expected about \(expected)")
            }
        }
    }
}

// MARK: - 13. OTLP encoding

final class FuzzOTLPEncoderTests: XCTestCase {
    private func value(_ rng: inout FuzzRNG, finite: Bool) -> AttributeValue {
        switch rng.int(0...4) {
        case 0: return .string(rng.hostileString())
        case 1: return .int(Int64(truncatingIfNeeded: rng.hostileInt()))
        case 2:
            let double = rng.hostileDouble()
            return .double(finite && !double.isFinite ? 1.5 : double)
        case 3: return .bool(rng.chance(0.5))
        default: return .stringArray((0..<rng.int(0...4)).map { _ in rng.hostileString(maxFragments: 4) })
        }
    }

    private func attributes(_ rng: inout FuzzRNG, finite: Bool) -> [String: AttributeValue] {
        var out: [String: AttributeValue] = [:]
        for _ in 0..<rng.int(0...8) { out[rng.hostileString(maxFragments: 4)] = value(&rng, finite: finite) }
        return out
    }

    private func span(_ rng: inout FuzzRNG, finite: Bool) -> SpanData {
        let start = Date(timeIntervalSince1970: rng.double(0..<4_000_000_000))
        return SpanData(
            context: SpanContext(traceId: .random(), spanId: .random(), sampled: rng.chance(0.8),
                                 traceState: rng.chance(0.3) ? rng.hostileString(maxFragments: 3) : nil),
            parentSpanId: rng.chance(0.5) ? .random() : nil,
            name: rng.hostileString(),
            kind: rng.pick([.unspecified, .internal, .server, .client, .producer, .consumer]),
            startTime: start,
            endTime: start.addingTimeInterval(rng.double(0..<100)),
            attributes: attributes(&rng, finite: finite),
            status: rng.pick([.unset, .ok, .error(rng.hostileString(maxFragments: 4))]),
            events: (0..<rng.int(0...3)).map { _ in
                SpanEvent(name: rng.hostileString(maxFragments: 4), timestamp: start, attributes: attributes(&rng, finite: finite))
            },
            resourceOverrides: rng.chance(0.3) ? attributes(&rng, finite: finite) : [:]
        )
    }

    private func matches(_ encoded: [String: Any]?, _ value: AttributeValue) -> Bool {
        guard let encoded else { return false }
        switch value {
        case .string(let s): return encoded["stringValue"] as? String == s.fuzzJSONReadBack
        case .int(let i): return encoded["intValue"] as? String == String(i)
        case .double(let d):
            // The writer emits a round-trippable literal; Apple's reader can land 1 ulp off.
            guard let read = (encoded["doubleValue"] as? NSNumber)?.doubleValue else { return false }
            return read == d || abs(read - d) <= 2 * d.ulp
        case .bool(let b): return encoded["boolValue"] as? Bool == b
        case .stringArray(let values):
            let items = ((encoded["arrayValue"] as? [String: Any])?["values"] as? [[String: Any]]) ?? []
            return items.compactMap { $0["stringValue"] as? String } == values.map(\.fuzzJSONReadBack) && items.count == values.count
        }
    }

    func testFiniteSpansEncodeFaithfully() {
        Fuzz.run("otlp.finite") { rng in
            let spans = (0..<rng.int(1...4)).map { _ in span(&rng, finite: true) }
            let resource = attributes(&rng, finite: true)
            let payload = OTLPEncoder.payload(spans: spans, resource: resource)
            try Fuzz.check(JSONSerialization.isValidJSONObject(payload), "finite payload not serialisable")
            let data = try OTLPEncoder.encode(spans: spans, resource: resource)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let groups = root["resourceSpans"] as? [[String: Any]] else { throw FuzzFailure(description: "not OTLP JSON") }
            let encoded = groups.flatMap { (($0["scopeSpans"] as? [[String: Any]])?.first?["spans"] as? [[String: Any]]) ?? [] }
            try Fuzz.check(encoded.count == spans.count, "\(encoded.count) spans encoded of \(spans.count)")
            for original in spans {
                guard let out = encoded.first(where: { $0["spanId"] as? String == original.context.spanId.hex }) else {
                    throw FuzzFailure(description: "span \(original.context.spanId.hex) missing")
                }
                try Fuzz.check(out["name"] as? String == original.name.fuzzJSONReadBack, "name lost: \(original.name.debugDescription)")
                let attrs = Dictionary((out["attributes"] as? [[String: Any]] ?? []).map { ($0["key"] as? String ?? "", $0["value"] as? [String: Any]) },
                                       uniquingKeysWith: { a, _ in a })
                // Keys that read back identically (a BOM-only key and "") are ambiguous here.
                let readBackCounts = Dictionary(original.attributes.keys.map { ($0.fuzzJSONReadBack, 1) }, uniquingKeysWith: +)
                for (key, value) in original.attributes where readBackCounts[key.fuzzJSONReadBack] == 1 {
                    try Fuzz.check(matches(attrs[key.fuzzJSONReadBack] ?? nil, value), "attribute \(key.debugDescription)=\(value) lost")
                }
                let start = UInt64(out["startTimeUnixNano"] as? String ?? "") ?? 0
                try Fuzz.check(abs(Double(start) / 1e9 - original.startTime.timeIntervalSince1970) < 1e-5, "start time drifted")
            }
        }
    }

    /// `JSONSerialization` raises an uncatchable Objective-C exception on NaN or
    /// infinity, so a non-serialisable payload is a crash in `SpanExporter.export`.
    func testAnyAttributeValueIsSerialisable() {
        Fuzz.run("otlp.any") { rng in
            let spans = (0..<rng.int(1...3)).map { _ in span(&rng, finite: false) }
            guard !JSONSerialization.isValidJSONObject(OTLPEncoder.payload(spans: spans, resource: [:])) else { return }
            let all = spans.flatMap { span in span.attributes.map { ($0.key, $0.value) } + span.events.flatMap { $0.attributes.map { ($0.key, $0.value) } } }
                + spans.flatMap { $0.resourceOverrides.map { ($0.key, $0.value) } }
            let minimal = Fuzz.shrink(all) { subset in
                let probe = SpanData(context: spans[0].context, parentSpanId: nil, name: "x", kind: .internal, startTime: spans[0].startTime,
                                     endTime: spans[0].endTime, attributes: Dictionary(subset, uniquingKeysWith: { a, _ in a }), status: .unset)
                return !JSONSerialization.isValidJSONObject(OTLPEncoder.payload(spans: [probe], resource: [:]))
            }
            throw FuzzFailure(description: "payload not serialisable; minimal attributes: \(minimal.map { "\($0.0.debugDescription): \($0.1)" }). Span.setAttribute(_, .double(.nan)) then export raises NSInvalidArgumentException (OTLPEncoder.encode, SpanExporter.swift:44)")
        }
    }

    func testEncodeWithNaNDoesNotRaise() throws {
        var rng = FuzzRNG(seed: Fuzz.baseSeed)
        let base = span(&rng, finite: true)
        let poisoned = SpanData(context: base.context, parentSpanId: nil, name: "x", kind: .internal, startTime: base.startTime,
                                endTime: base.endTime, attributes: ["v": .double(.nan)], status: .unset)
        // Proto3 JSON spells non-finite doubles as strings, which keeps the export valid.
        let json = try JSONSerialization.jsonObject(with: try OTLPEncoder.encode(spans: [poisoned], resource: [:]))
        XCTAssertTrue("\(json)".contains("NaN"))
    }

    func testPreEpochTimestampDoesNotTrap() throws {
        XCTAssertEqual(OTLPEncoder.nanoseconds(Date(timeIntervalSince1970: -1)), "0")
    }
}

// MARK: - 14. Bundle configuration

final class FuzzBundleConfigurationTests: XCTestCase {
    private static let fields = ["IngestKey", "Endpoint", "Environment", "ServiceName", "ServiceVersion", "TracesSampleRate"]

    private func plistValue(_ rng: inout FuzzRNG) -> Any {
        switch rng.int(0...11) {
        case 0: return "$(MAPLE_\(rng.asciiIdentifier()))"
        case 1: return rng.pick(["${MAPLE_X}", "prefix $(X) suffix", "x${Y}", "$X", "$("])
        case 2: return rng.pick([" ", "", "\n\t", "  maple_pk_abc\n"])
        case 3: return rng.pick(["https://ingest.example.com", "http://localhost:4318", "not a url", "ftp://x", "://x", "https://exa mple.com", "mailto:a@b"])
        case 4: return rng.pick(["0.5", "1", "nan", "-nan", "inf", "-inf", "1e400", "0x1p-2", " 0.25 ", "1,5"])
        case 5: return NSNumber(value: rng.hostileDouble())
        case 6: return NSNumber(value: rng.chance(0.5))
        case 7: return Date(timeIntervalSince1970: rng.double(0..<2_000_000_000))
        case 8: return rng.bytes(rng.int(0...16))
        case 9: return [rng.hostileString(maxFragments: 3)]
        case 10: return ["nested": rng.hostileString(maxFragments: 3)]
        default: return rng.hostileString()
        }
    }

    /// Restatement of the documented reading rules.
    private func expectedString(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.contains("$(") || raw.hasPrefix("${") { return nil }
        return raw
    }

    /// Whether a grapheme straddles the `$(`/`${` markers (`"$(" + U+200D`), where a
    /// Character-based and a scalar-based search legitimately disagree.
    private func isAmbiguous(_ value: Any?) -> Bool {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        let u = Array(raw.unicodeScalars)
        let scalarContains = zip(u, u.dropFirst()).contains { $0 == "$" && $1 == "(" }
        let scalarPrefix = u.count >= 2 && u[0] == "$" && u[1] == "{"
        return scalarContains != raw.contains("$(") || scalarPrefix != raw.hasPrefix("${")
    }

    private func makeBundle(_ info: [String: Any]) throws -> Bundle? {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0) else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("maple-fuzz-bundle-\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("Info.plist"))
        return Bundle(path: directory.path)
    }

    private func randomInfo(_ rng: inout FuzzRNG) -> (info: [String: Any], effective: [String: Any]) {
        var info: [String: Any] = ["CFBundleIdentifier": "dev.maple.fuzz.\(rng.asciiIdentifier())"]
        var nested: [String: Any] = [:]
        var effective: [String: Any] = [:]
        for field in Self.fields {
            switch rng.int(0...3) {
            case 0: break
            case 1:
                let value = plistValue(&rng); info["Maple\(field)"] = value; effective[field] = value
            case 2:
                let value = plistValue(&rng); nested[field] = value; effective[field] = value
            default:
                info["Maple\(field)"] = plistValue(&rng)
                let value = plistValue(&rng); nested[field] = value; effective[field] = value  // nested wins
            }
        }
        if !nested.isEmpty {
            if rng.chance(0.1) {
                info["Maple"] = rng.pick(["not a dictionary", [1, 2]] as [Any])
                effective = effective.filter { info["Maple\($0.key)"] != nil }.reduce(into: [:]) { $0[$1.key] = info["Maple\($1.key)"] }
            } else {
                info["Maple"] = nested
            }
        }
        return (info, effective)
    }

    func testReadMatchesDocumentedRules() {
        Fuzz.run("bundleConfiguration", iterations: Fuzz.iterations(cost: 2)) { rng in
            let (info, effective) = randomInfo(&rng)
            guard let bundle = try makeBundle(info) else { return }
            defer { try? FileManager.default.removeItem(atPath: bundle.bundlePath) }
            let configuration = MapleBundleConfiguration.read(from: bundle)
            let label = "\(effective)"

            for (name, actual) in [("IngestKey", configuration.ingestKey), ("Environment", configuration.environment),
                                   ("ServiceName", configuration.serviceName), ("ServiceVersion", configuration.serviceVersion)] {
                if isAmbiguous(effective[name]) { continue }
                try Fuzz.check(actual == expectedString(effective[name]), "\(name) = \(String(describing: actual)), expected \(String(describing: expectedString(effective[name]))): \(label)")
                if let actual { try Fuzz.check(!actual.contains("$(") && !actual.hasPrefix("${"), "unsubstituted \(name) leaked: \(actual)") }
            }
            if isAmbiguous(effective["Endpoint"]) || isAmbiguous(effective["TracesSampleRate"]) { return }
            let expectedEndpoint = expectedString(effective["Endpoint"]).flatMap { URL(string: $0) }.flatMap { $0.scheme == nil ? nil : $0 }
            try Fuzz.check(configuration.endpoint == expectedEndpoint, "Endpoint \(String(describing: configuration.endpoint)): \(label)")

            let rawRate = effective["TracesSampleRate"]
            // Non-finite rates are rejected as unset: the sampler cannot use them.
            let numberRate = (rawRate as? NSNumber)?.doubleValue
            let expectedRate: Double? = (numberRate ?? expectedString(rawRate).flatMap(Double.init)).flatMap { $0.isFinite ? $0 : nil }
            let sameRate = configuration.tracesSampleRate == expectedRate
            try Fuzz.check(sameRate, "TracesSampleRate \(String(describing: configuration.tracesSampleRate)), expected \(String(describing: expectedRate)): \(label)")
        }
    }

    /// A non-finite rate reaches `Tracer.shouldSample`, where `UInt64(rate * Double(UInt64.max))`
    /// traps on NaN. Reading must not hand one out.
    func testSampleRateIsFinite() {
        Fuzz.run("bundleConfiguration.rate", iterations: Fuzz.iterations(cost: 4, minimum: 10)) { rng in
            let raw: Any = rng.chance(0.5) ? rng.pick(["nan", "-nan", "NaN", "0.5", "1"]) : NSNumber(value: rng.hostileDouble())
            guard let bundle = try makeBundle(["CFBundleIdentifier": "dev.maple.fuzz.rate", "MapleTracesSampleRate": raw]) else { return }
            defer { try? FileManager.default.removeItem(atPath: bundle.bundlePath) }
            let rate = MapleBundleConfiguration.read(from: bundle).tracesSampleRate
            try Fuzz.check(rate.map { !$0.isNaN } ?? true, "MapleTracesSampleRate \(raw) read as \(String(describing: rate)); Tracer.shouldSample traps on it (Tracer.swift:117)")
        }
    }
}
