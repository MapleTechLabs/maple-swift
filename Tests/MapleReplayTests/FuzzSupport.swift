import Foundation
import UIKit
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

// MARK: - Shared fixtures

enum FuzzFixtures {
    /// A real JPEG, so recovery reads dimensions from a real header and AVAssetWriter
    /// decodes real pixels. Cached because rendering dominates the fuzz loop otherwise.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Data] = [:]

    static func jpeg(width: Int, height: Int, shade: Int = 0) -> Data {
        let key = "\(width)x\(height)/\(shade % 4)"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: width, height: height)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: CGFloat(shade % 4) / 4, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        }
        let data = image.jpegData(compressionQuality: 0.6)!
        lock.lock(); cache[key] = data; lock.unlock()
        return data
    }

    static func temporaryDirectory(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("maple-fuzz-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Stub transport

/// Records every request and answers from a script. Separate from the stub in
/// TransportTests (which is private) and owned by the fuzz files alone.
final class FuzzStubProtocol: URLProtocol {
    enum Response: Equatable, CustomStringConvertible {
        case status(Int)
        case transportError

        var description: String {
            switch self {
            case .status(let code): return "\(code)"
            case .transportError: return "transport-error"
            }
        }
    }

    struct Recorded {
        let index: Int
        /// Each run uses its own host, so a straggler from an earlier run is never
        /// attributed to a later one.
        let host: String
        let path: String
        let headers: [String: String]
        let body: Data
        let response: Response
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [Recorded] = []
    nonisolated(unsafe) private static var script: [Response] = []
    nonisolated(unsafe) private static var fallback: Response = .status(200)

    static func reset(fallback response: Response = .status(200)) {
        lock.lock(); defer { lock.unlock() }
        recorded = []
        script = []
        fallback = response
    }

    static func enqueue(_ response: Response) {
        lock.lock(); defer { lock.unlock() }
        script.append(response)
    }

    static var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FuzzStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(contentsOf: buffer[0..<read])
            }
            stream.close()
        }

        Self.lock.lock()
        let response = Self.script.isEmpty ? Self.fallback : Self.script.removeFirst()
        Self.recorded.append(
            Recorded(
                index: Self.recorded.count,
                host: request.url?.host ?? "",
                path: request.url?.path ?? "",
                headers: request.allHTTPHeaderFields ?? [:],
                body: body,
                response: response
            )
        )
        Self.lock.unlock()

        switch response {
        case .status(let code):
            let http = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .transportError:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
    }

    override func stopLoading() {}
}

// MARK: - NDJSON helpers

enum FuzzJSON {
    /// Parse a body of newline-terminated JSON objects. Nil if any line is not an object.
    static func ndjsonObjects(_ body: Data) -> [[String: Any]]? {
        var out: [[String: Any]] = []
        for line in body.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return nil }
            out.append(object)
        }
        return out
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
