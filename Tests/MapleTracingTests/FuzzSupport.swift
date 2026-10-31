// Copy of the harness in MapleReplayTests/FuzzSupport.swift: test targets cannot share
// sources, and the two must agree on seeds so a printed seed means the same thing in both.
import Foundation

import XCTest

// MARK: - Deterministic PRNG

/// SplitMix64. Deterministic across runs and platforms, so a printed seed reproduces a
/// failure exactly; `SystemRandomNumberGenerator` would make every failure a one-off.
struct FuzzRNG: RandomNumberGenerator {
    private(set) var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    static func mix(_ value: UInt64) -> UInt64 {
        var rng = FuzzRNG(seed: value)
        return rng.next()
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }
    mutating func double(_ range: Range<Double>) -> Double { Double.random(in: range, using: &self) }
    mutating func chance(_ probability: Double) -> Bool { double(0..<1) < probability }
    mutating func pick<T>(_ values: [T]) -> T { values[int(0...(values.count - 1))] }
}

/// Thread-safe wrapper for handing a PRNG to SDK seams that may call from any thread.
final class FuzzRandomBox: @unchecked Sendable {
    private let lock = NSLock()
    private var rng: FuzzRNG
    init(seed: UInt64) { rng = FuzzRNG(seed: seed) }
    func unit() -> Double {
        lock.lock(); defer { lock.unlock() }
        return rng.double(0..<1)
    }
}

// MARK: - Configuration and runner

struct FuzzFailure: Error, CustomStringConvertible {
    let description: String
}

enum Fuzz {
    /// Iterations for the cheap properties. Expensive ones divide this down.
    static var iterations: Int {
        if let raw = ProcessInfo.processInfo.environment["MAPLE_FUZZ_ITERATIONS"], let value = Int(raw), value > 0 {
            return value
        }
        return 200
    }

    /// Iterations scaled for a property that costs `cost` cheap iterations each.
    static func iterations(cost: Int, minimum: Int = 1) -> Int {
        max(minimum, iterations / max(1, cost))
    }

    static let baseSeed: UInt64 = {
        if let raw = ProcessInfo.processInfo.environment["MAPLE_FUZZ_SEED"], let value = UInt64(raw) {
            return value
        }
        return UInt64.random(in: 0...UInt64.max)
    }()

    /// Set to rerun a single case from a failure message.
    static let caseSeedOverride: UInt64? = {
        guard let raw = ProcessInfo.processInfo.environment["MAPLE_FUZZ_CASE_SEED"] else { return nil }
        return UInt64(raw)
    }()


    static func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw FuzzFailure(description: message()) }
    }

    /// Runs `body` once per case with an independent seed and stops at the first failure,
    /// reporting both seeds so the case reruns alone.
    static func run(
        _ name: String,
        iterations count: Int = Fuzz.iterations,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: (inout FuzzRNG) throws -> Void
    ) {
        let seeds: [UInt64] = caseSeedOverride.map { [$0] }
            ?? (0..<count).map { FuzzRNG.mix(baseSeed &+ UInt64($0)) }
        for (index, caseSeed) in seeds.enumerated() {
            var rng = FuzzRNG(seed: caseSeed)
            do {
                try body(&rng)
            } catch {
                XCTFail(
                    "[fuzz \(name)] case \(index) failed. MAPLE_FUZZ_SEED=\(baseSeed) MAPLE_FUZZ_CASE_SEED=\(caseSeed): \(error)",
                    file: file,
                    line: line
                )
                return
            }
        }
    }

    /// Greedy delta-debugging: drop chunks while the input still fails. Cheap and good
    /// enough to turn a 4 KB random string into the handful of characters that matter.
    static func shrink<T>(_ input: [T], stillFails: ([T]) -> Bool) -> [T] {
        var current = input
        var chunk = max(1, current.count / 2)
        while chunk >= 1 {
            var index = 0
            var progressed = false
            while index < current.count {
                var candidate = current
                candidate.removeSubrange(index..<min(current.count, index + chunk))
                if stillFails(candidate) {
                    current = candidate
                    progressed = true
                } else {
                    index += chunk
                }
            }
            if !progressed { chunk /= 2 }
        }
        return current
    }

    static func shrink(_ input: String, stillFails: (String) -> Bool) -> String {
        String(shrink(Array(input)) { stillFails(String($0)) })
    }
}

// MARK: - Generators

extension FuzzRNG {
    /// Fragments chosen to break naive text handling: grapheme clusters that are many
    /// scalars, bidi overrides, NUL and C0 controls, JSON metacharacters, line separators.
    static let hostileFragments: [String] = [
        "a", "Z", "0", "9", " ", "-", "_", ".", "/", ":", "\"", "\\", "'", "{", "}", "[", "]",
        "\n", "\r\n", "\r", "\t", "\u{0}", "\u{1}", "\u{1B}", "\u{7F}", "\u{85}",
        "\u{2028}", "\u{2029}", "\u{FEFF}", "\u{200B}", "\u{200D}",
        "e\u{301}", "\u{301}", "a\u{301}\u{302}\u{303}", "Z\u{36F}\u{36E}\u{36D}",
        "\u{202E}", "\u{202D}", "مرحبا", "שלום", "日本語", "한국어",
        "👩‍👩‍👧‍👦", "🇯🇵", "🏳️‍🌈", "👍🏽", "\u{1F600}", "𝔘𝔫𝔦",
        "$(", ")", "${", "%@", "%n", "%s", "%d", "\u{FFFD}", "\u{10FFFF}",
    ]

    mutating func hostileString(maxFragments: Int = 24) -> String {
        if chance(0.05) { return "" }
        var out = ""
        let count = int(1...max(1, maxFragments))
        for _ in 0..<count {
            if chance(0.6) {
                out += pick(Self.hostileFragments)
            } else if let scalar = Unicode.Scalar(UInt32(int(0...0x2FFFF))) {
                out.unicodeScalars.append(scalar)
            }
        }
        // Occasionally very long, which is where O(n^2) and fixed buffers show up.
        if chance(0.03) { out = String(repeating: out.isEmpty ? "x" : out, count: int(100...2_000)) }
        return out
    }

    mutating func asciiIdentifier(maxLength: Int = 16) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<int(1...maxLength)).map { _ in pick(alphabet) })
    }

    mutating func hostileDouble() -> Double {
        switch int(0...9) {
        case 0: return pick([.nan, .infinity, -.infinity, -0.0, 0.0])
        case 1: return pick([.leastNonzeroMagnitude, -.leastNonzeroMagnitude, .leastNormalMagnitude,
                             .greatestFiniteMagnitude, -.greatestFiniteMagnitude, .ulpOfOne])
        case 2: return pick([1e300, -1e300, 1e18, -1e18, 9.2e18, 1.8e19, 4.3e9])
        case 3: return Double(hostileInt())
        case 4: return Double(bitPattern: next())
        default: return double(-1_000..<1_000)
        }
    }

    mutating func hostileInt() -> Int {
        switch int(0...5) {
        case 0: return pick([Int.min, Int.max, 0, -1, 1, Int.min + 1, Int.max - 1])
        case 1: return pick([Int(Int32.min), Int(Int32.max), Int(UInt32.max), Int(UInt16.max), 65_535, 65_536])
        case 2: return Int(truncatingIfNeeded: next())
        default: return int(-1_000...1_000)
        }
    }

    mutating func bytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < count {
                var word = next()
                for _ in 0..<8 where offset < count {
                    raw[offset] = UInt8(truncatingIfNeeded: word)
                    word >>= 8
                    offset += 1
                }
            }
        }
        return data
    }

    /// A date somewhere between year 1 and 4001, biased toward the epoch boundary.
    mutating func hostileDate() -> Date {
        switch int(0...5) {
        case 0: return pick([.distantPast, .distantFuture, Date(timeIntervalSince1970: 0),
                             Date(timeIntervalSince1970: -0.0005), Date(timeIntervalSince1970: -1)])
        case 1: return Date(timeIntervalSince1970: double(-1_000..<1_000))
        case 2: return Date(timeIntervalSince1970: double(Date.distantPast.timeIntervalSince1970..<Date.distantFuture.timeIntervalSince1970))
        default: return Date(timeIntervalSince1970: double(1_000_000_000..<2_500_000_000))
        }
    }

    /// A JSON-serialisable value. Never NaN: that is an input `JSONSerialization` rejects
    /// by raising, so producing it here would test Foundation rather than the SDK.
    mutating func jsonValue(depth: Int = 3) -> Any {
        switch int(0...(depth > 0 ? 7 : 4)) {
        case 0: return NSNull()
        case 1: return chance(0.5)
        case 2: return hostileInt()
        case 3:
            let value = hostileDouble()
            return value.isFinite ? value : 0.5
        case 4: return hostileString(maxFragments: 6)
        case 5: return (0..<int(0...4)).map { _ in jsonValue(depth: depth - 1) }
        default:
            var object: [String: Any] = [:]
            for _ in 0..<int(0...4) { object[hostileString(maxFragments: 3)] = jsonValue(depth: depth - 1) }
            return object
        }
    }
}


extension String {
    /// What `JSONSerialization` reads back for this string. Its reader drops a leading
    /// U+FEFF from string values even though the bytes on the wire carry it, so an
    /// equality oracle built on that reader has to expect the same loss.
    var fuzzJSONReadBack: String {
        guard unicodeScalars.first == "\u{FEFF}" else { return self }
        return String(String.UnicodeScalarView(unicodeScalars.dropFirst()))
    }
}
