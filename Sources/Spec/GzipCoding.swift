import Compression
import Foundation

// Minimal, deterministic gzip framing over Apple's raw-DEFLATE codec, so a multi-megabyte plan
// artifact commits as a few hundred kilobytes while staying inspectable (`gunzip -c plan.json.gz | jq`).
// Determinism is the point of hand-rolling the framing: MTIME is pinned to zero and no filename is
// embedded, so identical plan bytes always gzip to identical archive bytes — a re-record that changed
// nothing is byte-identical in git. Read-side parsing still honors the optional header fields
// (FEXTRA/FNAME/FCOMMENT/FHCRC) so a hand-re-gzipped plan replays fine.

enum Gzip {
    enum GzipError: Error, Equatable, CustomStringConvertible {
        case encodingFailed
        case truncatedArchive
        case corruptDeflateStream
        case checksumMismatch

        var description: String {
            switch self {
            case .encodingFailed:
                "gzip encoding failed (DEFLATE produced no output)"
            case .truncatedArchive:
                "gzip archive is truncated or not gzip at all"
            case .corruptDeflateStream:
                "gzip DEFLATE stream is corrupt or uses an unsupported method"
            case .checksumMismatch:
                "gzip CRC32 does not match the decompressed payload"
            }
        }
    }

    /// The two-byte gzip signature — how `SpecPlan.init(contentsOf:)` decides to decompress.
    static func isGzip(_ data: Data) -> Bool {
        data.prefix(2).elementsEqual([0x1F, 0x8B])
    }

    /// Wraps `data` in a deterministic gzip member: fixed header (MTIME=0, no name, OS=unknown),
    /// raw DEFLATE body, CRC32 + ISIZE trailer.
    static func compress(_ data: Data) throws -> Data {
        let deflated = try rawDeflate(data)
        var archive = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        archive.append(deflated)
        archive.append(littleEndianBytes(crc32(data)))
        archive.append(littleEndianBytes(UInt32(truncatingIfNeeded: data.count)))
        return archive
    }

    /// Unwraps one gzip member, verifying the CRC32 trailer against the decompressed payload.
    static func decompress(_ archive: Data) throws -> Data {
        let bytes = Data(archive) // rebase indices to zero regardless of the caller's slice
        guard bytes.count >= 18, isGzip(bytes) else {
            throw GzipError.truncatedArchive
        }
        guard bytes[2] == 0x08 else {
            throw GzipError.corruptDeflateStream // CM: DEFLATE is the only method gzip defines
        }

        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 { // FEXTRA: 2-byte little-endian length + payload
            guard bytes.count > offset + 2 else { throw GzipError.truncatedArchive }
            offset += 2 + (Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8))
        }
        if flags & 0x08 != 0 { // FNAME
            offset = try skipNulTerminated(bytes, from: offset)
        }
        if flags & 0x10 != 0 { // FCOMMENT
            offset = try skipNulTerminated(bytes, from: offset)
        }
        if flags & 0x02 != 0 { // FHCRC
            offset += 2
        }
        guard bytes.count >= offset + 8 else {
            throw GzipError.truncatedArchive
        }

        let stream = bytes.subdata(in: offset ..< bytes.count - 8)
        let trailer = bytes.suffix(8)
        let storedChecksum = littleEndianUInt32(trailer.prefix(4))
        let storedSize = Int(littleEndianUInt32(trailer.suffix(4)))

        let payload = try rawInflate(stream, expectedSize: storedSize)
        guard crc32(payload) == storedChecksum else {
            throw GzipError.checksumMismatch
        }
        return payload
    }

    // MARK: - Raw DEFLATE via Compression

    private static func rawDeflate(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            throw GzipError.encodingFailed
        }
        let capacity = data.count + 65536
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!,
                    capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else {
            throw GzipError.encodingFailed
        }
        return output.prefix(written)
    }

    private static func rawInflate(_ stream: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else {
            // ISIZE 0 is a legally empty payload; anything else with no room to decode is corrupt.
            guard stream.isEmpty || crc32(Data()) == 0 else { throw GzipError.corruptDeflateStream }
            return Data()
        }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            stream.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!,
                    expectedSize,
                    src.bindMemory(to: UInt8.self).baseAddress!,
                    stream.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else {
            throw GzipError.corruptDeflateStream
        }
        return output
    }

    // MARK: - Framing helpers

    private static func skipNulTerminated(_ bytes: Data, from offset: Int) throws -> Int {
        var cursor = offset
        while cursor < bytes.count, bytes[cursor] != 0 {
            cursor += 1
        }
        guard cursor < bytes.count else {
            throw GzipError.truncatedArchive
        }
        return cursor + 1
    }

    private static func littleEndianBytes(_ value: UInt32) -> Data {
        Data([
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24)
        ])
    }

    private static func littleEndianUInt32(_ bytes: Data) -> UInt32 {
        Data(bytes).enumerated().reduce(UInt32(0)) { value, pair in
            value | (UInt32(pair.element) << (8 * UInt32(pair.offset)))
        }
    }

    // MARK: - CRC32 (the gzip polynomial)

    private static let crcTable: [UInt32] = (0 ..< 256).map { seed in
        var crc = UInt32(seed)
        for _ in 0 ..< 8 {
            crc = (crc & 1) == 1 ? (0xEDB8_8320 ^ (crc >> 1)) : (crc >> 1)
        }
        return crc
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
