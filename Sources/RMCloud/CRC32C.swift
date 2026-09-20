// Copyright 2026 ALTESSA SOLUTIONS INC.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import Foundation

/// CRC32C (Castagnoli) — the checksum the blob storage demands on every
/// upload.
///
/// On a real account, `PUT /sync/v3/files/{hash}` without it is answered
/// `400 {"message":"missing checksum"}`, however correct the hash,
/// the token and `rm-filename` are. The storage behind sync v3 is Google
/// Cloud Storage — hence the `x-goog-hash` header, and hence CRC32C rather
/// than the SHA-256 the rest of the protocol runs on. rmapi sends the same
/// thing from `PutStream`.
///
/// Written out by hand because CryptoKit has no CRC of any kind. Not to be
/// confused with zip's ordinary CRC-32 on
/// polynomial 0xEDB88320, a different algorithm that produces a
/// plausible-looking wrong answer here. The check vectors in the tests are
/// what keep the two apart.
public enum CRC32C {
    /// The reflected Castagnoli polynomial.
    private static let polynomial: UInt32 = 0x82F6_3B78

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 != 0 ? polynomial ^ (value >> 1) : value >> 1
        }
        return value
    }

    public static func checksum(_ data: Data) -> UInt32 {
        finish(update(seed, with: data))
    }

    /// The value for the `x-goog-hash` header: the four bytes big-endian,
    /// base64-encoded, prefixed with the algorithm's name.
    public static func googHash(_ data: Data) -> String {
        header(for: checksum(data))
    }

    /// The same checksum over a file, in chunks.
    ///
    /// An uploaded original runs to hundreds of megabytes, and the point of
    /// keeping it on disk is lost if taking its checksum reads it into memory.
    /// CRC is a running value, so chunking costs nothing but the loop — and
    /// the loop, with its cancellation check, is `FileChunks`'s.
    public static func checksum(contentsOf file: URL) throws -> UInt32 {
        var crc = seed
        try FileChunks.forEach(in: file, ofSize: chunkSize) { chunk in
            crc = update(crc, with: chunk)
        }
        return finish(crc)
    }

    /// The header value for a file on disk.
    public static func googHash(contentsOf file: URL) throws -> String {
        header(for: try checksum(contentsOf: file))
    }

    /// The running value before any byte, and the mask that turns the last
    /// running value into the checksum.
    private static let seed: UInt32 = 0xFFFF_FFFF

    private static func finish(_ crc: UInt32) -> UInt32 {
        crc ^ seed
    }

    /// The running value carried forward over `data`.
    ///
    /// Over the raw buffer rather than `for byte in data`: this loop touches
    /// every byte of an upload in Swift, and `Data`'s own iterator is a
    /// bounds-checked accessor per byte. Measured on 256 MiB with `-O`, the
    /// same table and the same answer: 0.66 s through the iterator, 0.46 s
    /// through the buffer — a third off a pass an upload makes once.
    private static func update(_ crc: UInt32, with data: Data) -> UInt32 {
        data.withUnsafeBytes { buffer in
            buffer.reduce(crc) { crc, byte in
                table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
    }

    private static func header(for crc: UInt32) -> String {
        let bytes = withUnsafeBytes(of: crc.bigEndian) { Data($0) }
        return "crc32c=\(bytes.base64EncodedString())"
    }

    /// The read chunk.
    ///
    /// Smaller than the four megabytes `ContentHash.blob(contentsOf:)` reads
    /// in, and the two need not agree: each is a separate pass over the file,
    /// and both sums are running values that care about the order of the bytes
    /// rather than about where the reads are cut. A megabyte is the smaller
    /// buffer because this loop touches every byte in Swift, while hashing
    /// hands whole chunks to CryptoKit.
    private static let chunkSize = 1 << 20

    public static let header = "x-goog-hash"
}
