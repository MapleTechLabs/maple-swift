import Compression
import Foundation

/// Minimal gzip encoder.
///
/// Maple's ingest gateway unconditionally gunzips replay chunk bodies — there is no
/// identity path (`handle_replay_blob_inner` in apps/ingest). So chunks must be gzip, and
/// the prototype writes gzip to disk for the same reason: the bytes on disk are meant to
/// be exactly the bytes a future POST sends.
///
/// Foundation has no gzip. `Compression.COMPRESSION_ZLIB` is raw DEFLATE (RFC 1951), not
/// the gzip container (RFC 1952), so we wrap it with the 10-byte header and the
/// CRC32 + ISIZE trailer ourselves. This avoids linking system zlib and keeps the package
/// dependency-free.
public enum Gzip {
    public static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        guard let deflated = deflate(data) else { return nil }

        var out = Data(capacity: deflated.count + 18)
        out.append(contentsOf: [
            0x1F, 0x8B,  // magic
            0x08,        // CM = deflate
            0x00,        // FLG = no extra fields
            0x00, 0x00, 0x00, 0x00,  // MTIME = 0; a timestamp would make output non-reproducible
            0x00,        // XFL
            0xFF,        // OS = unknown
        ])
        out.append(deflated)
        out.append(littleEndian: CRC32.checksum(data))
        out.append(littleEndian: UInt32(truncatingIfNeeded: data.count))
        return out
    }

    /// Inverse of `compress`. Test-only — nothing in the SDK reads a chunk back, but
    /// asserting on what was actually sent means being able to read it.
    public static func decompress(_ data: Data) -> Data? {
        // 10-byte fixed header, no optional fields (we never emit FLG != 0), and an
        // 8-byte CRC32 + ISIZE trailer.
        guard data.count > 18,
              data[data.startIndex] == 0x1F,
              data[data.startIndex + 1] == 0x8B,
              data[data.startIndex + 2] == 0x08,
              data[data.startIndex + 3] == 0x00 else { return nil }

        let deflated = data.dropFirst(10).dropLast(8)
        let isize = data.suffix(4).reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }

        // `compression_decode_buffer` needs the output size up front; ISIZE is exactly
        // that. Guard against a hostile length so a bad trailer can't ask for gigabytes.
        let capacity = max(1, min(Int(isize), 256 * 1024 * 1024))
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }

        let written = Data(deflated).withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(
                destination, capacity, base, raw.count, nil, COMPRESSION_ZLIB
            )
        }
        guard written > 0 else { return nil }
        return Data(bytes: destination, count: written)
    }

    private static func deflate(_ data: Data) -> Data? {
        let capacity = max(64, data.count)
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }

        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(
                destination, capacity, base, data.count, nil, COMPRESSION_ZLIB
            )
        }

        // A zero return means the compressed form would not fit in `capacity`, i.e. the
        // input is incompressible. Store it uncompressed in a DEFLATE stored block rather
        // than failing — the gateway only cares that the stream decodes.
        guard written > 0 else { return storedBlocks(data) }
        return Data(bytes: destination, count: written)
    }

    /// DEFLATE "stored" (uncompressed) blocks, max 65535 bytes each.
    private static func storedBlocks(_ data: Data) -> Data {
        var out = Data(capacity: data.count + 5 * (data.count / 65535 + 1))
        var offset = 0
        while offset < data.count {
            let length = min(65535, data.count - offset)
            let isFinal = (offset + length) >= data.count
            out.append(isFinal ? 0x01 : 0x00)
            out.append(littleEndian: UInt16(length))
            out.append(littleEndian: UInt16(~UInt16(length) & 0xFFFF))
            out.append(data[data.startIndex + offset ..< data.startIndex + offset + length])
            offset += length
        }
        return out
    }
}

public enum CRC32 {
    private static let table: [UInt32] = (0...255).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }

    mutating func append(littleEndian value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }
}
