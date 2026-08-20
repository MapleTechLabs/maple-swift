import Foundation
import XCTest

@testable import MapleTracing

/// Captures ended spans and answers questions about the tree they form.
///
/// Four test files had grown their own `var recorded: [SpanData] = []`, which is
/// fine for "was this attribute set" and useless for the questions that actually
/// bite in production — how many requests one screen load made, and whether they
/// were children of it or thirteen unrelated roots. Those are properties of the
/// *tree*, and nothing was asserting them: a trace-parenting regression shipped
/// and was found by reading warehouse SQL, not by a test.
final class SpanRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var spans: [SpanData] = []

    /// Hand this to `Tracer(options:onSpanEnd:)`.
    var onSpanEnd: (SpanData) -> Void {
        { [weak self] data in
            guard let self else { return }
            self.lock.lock()
            self.spans.append(data)
            self.lock.unlock()
        }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        spans = []
    }

    var all: [SpanData] {
        lock.lock(); defer { lock.unlock() }
        return spans
    }

    func all(named name: String) -> [SpanData] {
        all.filter { $0.name == name }
    }

    func first(named name: String) -> SpanData? {
        all.first { $0.name == name }
    }

    /// Spans that began no trace of their own.
    func children(of parent: SpanData) -> [SpanData] {
        all.filter { $0.parentSpanId?.hex == parent.context.spanId.hex }
    }

    /// Spans with no parent — each one starts its own trace.
    var roots: [SpanData] {
        all.filter { $0.parentSpanId == nil }
    }

    // MARK: - Assertions

    /// Every span named `name` is a child of `parent`.
    ///
    /// The assertion that would have caught the orphaned-client-span regression:
    /// half of production's `GET` spans were roots despite the SDK carrying a
    /// mechanism whose entire job is preventing exactly that.
    func assertAllChildren(
        named name: String,
        of parent: SpanData,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let matches = all(named: name)
        XCTAssertFalse(matches.isEmpty, "no spans named \(name) were recorded", file: file, line: line)
        let orphans = matches.filter { $0.parentSpanId?.hex != parent.context.spanId.hex }
        XCTAssertTrue(
            orphans.isEmpty,
            "\(orphans.count) of \(matches.count) \(name) spans are not children of \(parent.name) — "
                + "they start their own traces",
            file: file,
            line: line
        )
    }

    /// Every span named `name` shares one trace id.
    func assertOneTrace(
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let traces = Set(all(named: name).map(\.context.traceId.hex))
        XCTAssertEqual(traces.count, 1, "\(name) spans span \(traces.count) traces", file: file, line: line)
    }

    func assertCount(
        _ expected: Int,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = all(named: name).count
        XCTAssertEqual(actual, expected, "expected \(expected) \(name) spans, recorded \(actual)", file: file, line: line)
    }
}

extension SpanData {
    var durationSeconds: TimeInterval { endTime.timeIntervalSince(startTime) }

    func attribute(_ key: String) -> AttributeValue? { attributes[key] }
}
