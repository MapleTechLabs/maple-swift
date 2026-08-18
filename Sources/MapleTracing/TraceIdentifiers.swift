import Foundation

/// A 16-byte trace id, as 32 lowercase hex characters.
///
/// Held as a string rather than bytes because every consumer wants the hex: OTLP/JSON
/// encodes ids as hex, `traceparent` carries hex, and `session_replays.TraceIds` stores
/// hex. Converting to bytes and back at each boundary would buy nothing.
public struct TraceID: Hashable, Sendable, CustomStringConvertible {
    public let hex: String

    /// All-zero is the OTel "invalid" id and must never be emitted or accepted.
    public static let invalidHex = String(repeating: "0", count: 32)

    public init?(hex: String) {
        let lowered = hex.lowercased()
        guard lowered.count == 32, lowered.allSatisfy(\.isLowercaseHexDigit), lowered != Self.invalidHex else {
            return nil
        }
        self.hex = lowered
    }

    public static func random() -> TraceID {
        // A retry loop rather than an assertion: the all-zero draw is astronomically
        // unlikely, but it is *invalid*, and emitting an invalid id is worse than
        // drawing twice.
        while true {
            let candidate = randomHex(bytes: 16)
            if let id = TraceID(hex: candidate) { return id }
        }
    }

    public var description: String { hex }
}

/// An 8-byte span id, as 16 lowercase hex characters.
public struct SpanID: Hashable, Sendable, CustomStringConvertible {
    public let hex: String

    public static let invalidHex = String(repeating: "0", count: 16)

    public init?(hex: String) {
        let lowered = hex.lowercased()
        guard lowered.count == 16, lowered.allSatisfy(\.isLowercaseHexDigit), lowered != Self.invalidHex else {
            return nil
        }
        self.hex = lowered
    }

    public static func random() -> SpanID {
        while true {
            let candidate = randomHex(bytes: 8)
            if let id = SpanID(hex: candidate) { return id }
        }
    }

    public var description: String { hex }
}

/// Identity and sampling decision for one span, and the thing `traceparent` carries.
public struct SpanContext: Hashable, Sendable {
    public let traceId: TraceID
    public let spanId: SpanID
    public let sampled: Bool
    /// Opaque vendor state, forwarded verbatim when present. We never write to it.
    public let traceState: String?

    public init(traceId: TraceID, spanId: SpanID, sampled: Bool, traceState: String? = nil) {
        self.traceId = traceId
        self.spanId = spanId
        self.sampled = sampled
        self.traceState = traceState
    }

    /// `traceparent` value for this context: `00-{trace}-{span}-{flags}`.
    public var traceParentHeader: String {
        "00-\(traceId.hex)-\(spanId.hex)-\(sampled ? "01" : "00")"
    }

    /// Parse an inbound `traceparent`.
    ///
    /// Strict where the spec is strict, lenient where it says to be: version `ff` is
    /// invalid, version `00` must have exactly four fields, and a *higher* version may
    /// carry extra fields we ignore rather than reject — that is the forward-compatibility
    /// rule, and rejecting the whole header would orphan a trace rather than continue it.
    public static func parse(traceParent: String, traceState: String? = nil) -> SpanContext? {
        let fields = traceParent.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count >= 4 else { return nil }

        let version = String(fields[0]).lowercased()
        guard version.count == 2, version.allSatisfy(\.isLowercaseHexDigit), version != "ff" else { return nil }
        if version == "00" && fields.count != 4 { return nil }

        guard let traceId = TraceID(hex: String(fields[1])),
              let spanId = SpanID(hex: String(fields[2])) else { return nil }

        let flags = String(fields[3]).lowercased()
        guard flags.count == 2, flags.allSatisfy(\.isLowercaseHexDigit), let bits = UInt8(flags, radix: 16) else {
            return nil
        }

        return SpanContext(
            traceId: traceId,
            spanId: spanId,
            sampled: bits & 0x01 == 0x01,
            traceState: traceState
        )
    }
}

/// Cryptographically-seeded random hex. `SystemRandomNumberGenerator` is the platform CSPRNG,
/// so there is no need to link Security for this.
private func randomHex(bytes count: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    var out = ""
    out.reserveCapacity(count * 2)
    for _ in 0..<count {
        let byte = UInt8.random(in: 0...255, using: &generator)
        out.append(hexDigits[Int(byte >> 4)])
        out.append(hexDigits[Int(byte & 0x0F)])
    }
    return out
}

private let hexDigits = Array("0123456789abcdef")

private extension Character {
    var isLowercaseHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self)
    }
}
