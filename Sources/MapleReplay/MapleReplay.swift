import Foundation
import UIKit

/// Session replay capture for iOS.
///
/// Milestone 1 is capture-only: segments are written to disk in exactly the form they
/// would be transmitted (gzipped rrweb-shaped JSON chunks plus an inspectable MP4).
/// There is deliberately no networking yet.
///
/// ```swift
/// var options = ReplayOptions()
/// options.flushPolicy = .buffered(window: 30)
/// MapleReplay.shared.start(options: options)
/// // ... later, on an error:
/// MapleReplay.shared.flush(trigger: "error")
/// ```
public final class MapleReplay {
    public static let shared = MapleReplay()

    private var recorder: ReplayRecorder?
    private var metaRow: SessionMetaRow?
    private(set) public var sessionId: String?

    /// Called on the main thread each time a segment is written.
    public var onSegment: ((SegmentArtifacts) -> Void)?

    private init() {}

    public var isRecording: Bool { recorder != nil }

    /// Directory the current session's segments are written to.
    public var outputDirectory: URL? { recorder?.outputDirectory }

    /// Segments written so far this session.
    public var segments: [SegmentArtifacts] { recorder?.artifacts ?? [] }

    @MainActor
    public func start(
        options: ReplayOptions = ReplayOptions(),
        serviceName: String = "ios-app",
        environment: String? = nil,
        userId: String = ""
    ) {
        guard recorder == nil else { return }

        // The gateway rejects ids outside `[A-Za-z0-9_-]{1,128}`. A bare uuidString
        // qualifies; anything with braces or colons would 400 at upload time, which is a
        // miserable thing to discover in milestone 2.
        let id = UUID().uuidString
        precondition(SegmentWriter.isSafeSessionId(id), "generated session id is not gateway-safe")
        sessionId = id

        let recorder = ReplayRecorder(sessionId: id, options: options)
        recorder.onSegment = { [weak self] artifact in
            DispatchQueue.main.async { self?.onSegment?(artifact) }
        }
        self.recorder = recorder

        let meta = SessionMetaRow(
            sessionId: id,
            startedAt: Date(),
            status: .active,
            version: 1,
            serviceName: serviceName,
            environment: environment,
            userId: userId,
            recorded: true
        )
        metaRow = meta
        writeMeta(meta)

        recorder.start()
    }

    @MainActor
    public func stop() {
        guard let recorder else { return }
        // Flush before tearing down, or the tail of the session — usually the part
        // someone actually wants — is discarded.
        recorder.flush(trigger: "stop")
        recorder.stop()

        if let meta = metaRow {
            writeMeta(
                SessionMetaRow(
                    sessionId: meta.sessionId,
                    startedAt: meta.startedAt,
                    status: .ended,
                    version: 2,
                    serviceName: meta.serviceName,
                    environment: meta.environment,
                    userId: meta.userId,
                    recorded: true
                )
            )
        }

        self.recorder = nil
        metaRow = nil
    }

    /// Emit whatever is currently buffered.
    ///
    /// In `.buffered` mode this is the only thing that produces a segment — wire it to
    /// your error handler. In `.continuous` mode it forces an early segment boundary.
    public func flush(trigger: String = "manual") {
        recorder?.flush(trigger: trigger)
    }

    private func writeMeta(_ meta: SessionMetaRow) {
        guard let directory = recorder?.outputDirectory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("meta.ndjson")
            let line = try meta.ndjson()
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
            }
        } catch {
            NSLog("[MapleReplay] failed to write meta row: \(error)")
        }
    }
}
