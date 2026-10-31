import Foundation
import MapleCore
import XCTest
@testable import MapleReplay

/// Random request sequences against `ReplayTransport` with scripted responses.
///
/// Calls are serialised (each completion is awaited before the next call) so the oracle
/// can be a plain state machine: 402 stops everything, 413 stops blobs only, and every
/// other answer changes nothing.
final class FuzzTransportTests: XCTestCase {
    private enum Op: String { case meta, blob, events, emptyEvents }

    override func setUp() {
        super.setUp()
        FuzzStubProtocol.reset()
    }

    private func segment(_ rng: inout FuzzRNG, seq: Int) -> PreparedSegment {
        let body = Gzip.compress(rng.bytes(rng.int(1...2_000)))!
        let artifacts = SegmentArtifacts(
            chunkSeq: seq, isCheckpoint: rng.chance(0.5), gzippedBytes: body.count, rawJSONBytes: 0,
            videoBytes: 0, frameCount: 1, eventCount: rng.int(0...20), durationMs: rng.int(0...60_000),
            chunkURL: nil, videoURL: nil
        )
        return PreparedSegment(artifacts: artifacts, body: body)
    }

    private func waitFor(_ label: String, _ start: (@escaping () -> Void) -> Void) throws {
        let done = DispatchSemaphore(value: 0)
        start { done.signal() }
        if done.wait(timeout: .now() + 10) == .timedOut { throw FuzzFailure(description: "\(label) never completed") }
    }

    func testKillSwitches() {
        Fuzz.run("transport", iterations: Fuzz.iterations(cost: 4, minimum: 10)) { rng in
            FuzzStubProtocol.reset()
            let sessionId = rng.asciiIdentifier(maxLength: 36)
            let transport = ReplayTransport(
                endpoint: URL(string: rng.pick(["https://fuzz.invalid", "https://fuzz.invalid/", "https://fuzz.invalid///"]))!,
                ingestKey: "maple_pk_fuzz", sessionId: sessionId, urlSession: FuzzStubProtocol.session()
            )
            var allStopped = false
            var blobsStopped = false
            var history: [String] = []
            let responses: [FuzzStubProtocol.Response] = [.status(200), .status(202), .status(402), .status(413),
                                                          .status(429), .status(500), .status(401), .transportError]

            for step in 0..<rng.int(1...30) {
                let op = rng.pick([Op.meta, .blob, .blob, .events, .emptyEvents])
                // Weighted so a run usually sees traffic before the first kill switch.
                let response = rng.chance(0.6) ? FuzzStubProtocol.Response.status(200) : rng.pick(responses)
                FuzzStubProtocol.reset(fallback: response)
                let before = FuzzStubProtocol.requests.count

                switch op {
                case .meta:
                    let row = SessionMetaRow(sessionId: sessionId, startedAt: Date(), status: rng.chance(0.5) ? .active : .ended,
                                             version: step + 1, serviceName: rng.hostileString(maxFragments: 4),
                                             environment: nil, userId: rng.hostileString(maxFragments: 4), recorded: true)
                    try waitFor("meta") { transport.postMeta(row, completion: $0) }
                case .blob:
                    let segment = segment(&rng, seq: step)
                    try waitFor("blob") { transport.postBlob(segment, completion: $0) }
                    if let request = FuzzStubProtocol.requests.last, FuzzStubProtocol.requests.count > before {
                        try Fuzz.check(request.body == segment.body, "blob body altered")
                        try Fuzz.check(request.headers["x-maple-session-id"] == sessionId, "blob session header")
                        try Fuzz.check(request.headers["x-maple-chunk-seq"] == String(step), "blob seq header")
                        try Fuzz.check(request.headers["Content-Encoding"] == nil, "blob declared a content encoding")
                    }
                case .events, .emptyEvents:
                    let rows = op == .emptyEvents ? [] : (0..<rng.int(1...5)).map { index in
                        SessionEventRow(sessionId: sessionId, seq: step * 10 + index, type: .custom,
                                        message: rng.hostileString(maxFragments: 5), traceId: "")
                    }
                    try waitFor("events") { transport.postEvents(rows, completion: $0) }
                }

                let sends = !allStopped && op != .emptyEvents && !(op == .blob && blobsStopped)
                let path: String? = sends ? (op == .meta ? "/v1/sessionReplays/meta" : op == .blob ? "/v1/sessionReplays/blob" : "/v1/sessionEvents") : nil
                history.append("\(op.rawValue)->\(sends ? response.description : "suppressed")")

                let requests = FuzzStubProtocol.requests
                try Fuzz.check(requests.count - before == (sends ? 1 : 0),
                               "step \(step): \(requests.count - before) requests, expected \(sends ? 1 : 0). history: \(history)")
                if let path, let last = requests.last {
                    try Fuzz.check(last.path == path, "step \(step): sent to \(last.path), expected \(path)")
                    try Fuzz.check(last.headers["Authorization"] == "Bearer maple_pk_fuzz", "auth header")
                }
                if sends {
                    if response == .status(402) { allStopped = true }
                    if response == .status(413) { blobsStopped = true }
                }
            }
        }
    }
}
