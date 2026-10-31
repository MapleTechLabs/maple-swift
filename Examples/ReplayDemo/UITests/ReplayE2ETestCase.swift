import XCTest

/// Shared harness: a fresh mock ingest server and a fresh app launch per test.
class ReplayE2ETestCase: XCTestCase {
    var server: MockIngestServer!
    var app: XCUIApplication!

    static let ingestKey = "maple_pk_e2e"

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = MockIngestServer()
        try server.start()
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        app?.terminate()
        server?.stop()
        XCUIDevice.shared.orientation = .portrait
    }

    /// Launch the demo in e2e mode, recording every session at 2 fps in 2 s segments
    /// unless `overrides` says otherwise.
    func launch(_ overrides: [String: String] = [:], reset: Bool = true) {
        var environment = [
            "MAPLE_E2E": "1",
            "MAPLE_ENDPOINT": server.endpoint,
            "MAPLE_INGEST_KEY": Self.ingestKey,
            "MAPLE_FRAME_RATE": "2",
            "MAPLE_SEGMENT_DURATION": "2",
            "MAPLE_SESSION_SAMPLE_RATE": "1",
            "MAPLE_ON_ERROR_SAMPLE_RATE": "0",
            "MAPLE_BACKGROUND_TIMEOUT": "30",
        ]
        if reset { environment["MAPLE_E2E_RESET"] = "1" }
        environment.merge(overrides) { $1 }
        app.launchEnvironment = environment
        app.launch()
    }

    // MARK: - Waiting

    /// Poll until `probe` returns a value. Event-driven against the server's recording,
    /// so a fast machine does not pay for a slow one's worst case.
    @discardableResult
    func waitFor<T>(
        _ what: String,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ probe: () throws -> T?
    ) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = try probe() { return value }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        XCTFail("timed out after \(Int(timeout)) s waiting for \(what)", file: file, line: line)
        throw E2EError.timedOut(what)
    }

    /// A fixed wait, only for asserting that something does NOT happen.
    func hold(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Session queries

    func activeRow(version: Int = 1, timeout: TimeInterval = 20) throws -> MetaRow {
        try waitFor("an active meta row with version \(version)", timeout: timeout) {
            server.metaRows.first { $0.status == "active" && $0.version == version }
        }
    }

    func rows(for sessionId: String) -> [MetaRow] {
        server.metaRows.filter { $0.sessionId == sessionId }
    }

    func blobs(for sessionId: String) throws -> [Blob] {
        try server.blobs().filter { $0.sessionId == sessionId }
    }

    @discardableResult
    func waitForBlobs(_ sessionId: String, count: Int, timeout: TimeInterval = 30) throws -> [Blob] {
        try waitFor("\(count) blobs for session \(sessionId)", timeout: timeout) {
            let found = try blobs(for: sessionId)
            return found.count >= count ? found : nil
        }
    }

    // MARK: - Geometry

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Frame of `identifier` in window points, waiting for it to appear.
    func frame(of identifier: String) throws -> CGRect {
        let element = element(identifier)
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(identifier) never appeared")
        return element.frame
    }

    var windowSize: CGSize { app.windows.firstMatch.frame.size }

    func tap(atWindowPoint point: CGPoint) {
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x, dy: point.y))
            .tap()
    }

    func moveToBackground() {
        XCUIDevice.shared.press(.home)
    }
}

enum E2EError: Error {
    case timedOut(String)
}

extension CGRect {
    func scaled(by scale: CGFloat) -> CGRect {
        CGRect(x: minX * scale, y: minY * scale, width: width * scale, height: height * scale)
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

extension Date {
    var epochMs: Int { Int((timeIntervalSince1970 * 1000).rounded()) }
}
