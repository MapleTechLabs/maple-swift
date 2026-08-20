import MapleCore
import UIKit
import XCTest

@testable import MapleTracing

/// `ui.screen` must not outlive the foreground.
///
/// The span runs from appearance to disappearance, and neither end fires when the
/// app is backgrounded — nor, in SwiftUI, when a tab's root view stops being the
/// visible tab. Production carried the consequence: `ui.screen` spans up to
/// eleven hours long, which are indistinguishable from an eleven-hour request and
/// took the service's reported p95 from under three seconds to nearly nine.
final class ScreenSpanBoundingTests: XCTestCase {
    private var recorder: SpanRecorder!

    override func setUp() {
        super.setUp()
        recorder = SpanRecorder()
        SessionSink.shared.resetForTesting()
        ViewControllerInstrumentation.install(tracer: Tracer(options: TracingOptions(), onSpanEnd: recorder.onSpanEnd))
    }

    override func tearDown() {
        ViewControllerInstrumentation.uninstall()
        SessionSink.shared.resetForTesting()
        recorder = nil
        super.tearDown()
    }

    private func background() {
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    func testBackgroundingEndsAnOpenScreenSpan() throws {
        let span = try XCTUnwrap(ViewControllerInstrumentation.screenAppeared("Home"))
        XCTAssertFalse(span.hasEnded)

        background()

        XCTAssertTrue(span.hasEnded, "the screen span survived backgrounding — this is the 11-hour span")
        let recorded = try XCTUnwrap(recorder.first(named: "ui.screen"))
        XCTAssertEqual(recorded.attribute("screen.name"), .string("Home"))
        XCTAssertEqual(recorded.attribute("maple.screen.end_reason"), .string("background"))
    }

    func testEveryOpenScreenIsEnded() throws {
        // A tab bar leaves each tab's root "appeared"; all of them are open at once.
        let home = try XCTUnwrap(ViewControllerInstrumentation.screenAppeared("Home"))
        let services = try XCTUnwrap(ViewControllerInstrumentation.screenAppeared("Services"))
        let issues = try XCTUnwrap(ViewControllerInstrumentation.screenAppeared("Issues"))

        background()

        XCTAssertTrue([home, services, issues].allSatisfy(\.hasEnded))
        recorder.assertCount(3, named: "ui.screen")
        XCTAssertEqual(ViewControllerInstrumentation.openScreenCount, 0)
    }

    /// The host still holds the span and will end it on `onDisappear`. That must
    /// not export it twice under the same id, and must not overwrite the reason.
    func testASpanEndedByBackgroundingIsNotEndedAgain() throws {
        let span = try XCTUnwrap(ViewControllerInstrumentation.screenAppeared("Home"))
        background()
        span.end()

        recorder.assertCount(1, named: "ui.screen")
        XCTAssertEqual(recorder.first(named: "ui.screen")?.attribute("maple.screen.end_reason"), .string("background"))
    }

    /// A screen closed normally carries no reason — the attribute's absence is
    /// what distinguishes a real dwell from a truncated one.
    func testANormallyClosedScreenCarriesNoEndReason() throws {
        let span = try XCTUnwrap(ViewControllerInstrumentation.screenAppeared("Home"))
        span.end()

        let recorded = try XCTUnwrap(recorder.first(named: "ui.screen"))
        XCTAssertNil(recorded.attribute("maple.screen.end_reason"))
    }

    /// Backgrounding twice must not re-end screens from the first round, and the
    /// registry must not grow across a long session.
    func testTheRegistryDoesNotAccumulate() throws {
        for index in 0 ..< 20 {
            let span = try XCTUnwrap(ViewControllerInstrumentation.screenAppeared("Screen\(index)"))
            span.end()
        }
        XCTAssertEqual(ViewControllerInstrumentation.openScreenCount, 0)

        background()
        recorder.assertCount(20, named: "ui.screen")
        XCTAssertTrue(
            recorder.all(named: "ui.screen").allSatisfy { $0.attribute("maple.screen.end_reason") == nil },
            "already-closed screens were re-tagged by a later backgrounding"
        )
    }

    /// Backgrounding with nothing open is a no-op, not a crash.
    func testBackgroundingWithNoOpenScreens() {
        background()
        recorder.assertCount(0, named: "ui.screen")
    }

    /// The span must still be a real screen span: named, attributed, and bounded.
    func testTheBoundedSpanIsStillWellFormed() throws {
        let span = try XCTUnwrap(ViewControllerInstrumentation.screenAppeared("Home"))
        background()

        let recorded = try XCTUnwrap(recorder.first(named: "ui.screen"))
        XCTAssertEqual(recorded.name, "ui.screen")
        XCTAssertEqual(recorded.context.traceId.hex, span.traceId)
        XCTAssertGreaterThanOrEqual(recorded.durationSeconds, 0)
        XCTAssertLessThan(recorded.durationSeconds, 60, "a unit-test screen span should be near-instant")
    }
}
