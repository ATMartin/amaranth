public import Foundation
public import Domain

/// Minimal Core Audio Format codec for float32 interleaved PCM segments.
///
/// Writing it directly (rather than through AVAudioFile) gives exact control over flush/close/rename ordering. Each
/// segment also carries an `info` chunk with its `AudioSegmentRecord` metadata (key `amaranth.segment`), so a committed
/// file is self-describing: recovery can index it even if the crash happened before its journal line or database row.
public enum CAFFile {
    public static let metadataKey = "amaranth.segment"
    /// Header size of a segment written without an info chunk (caff + desc + data chunk header).
    public static let headerSize = 68

    public static func encode(samples: UnsafeBufferPointer<Float>, format: AudioFormat, metadata: Data? = nil) -> Data {
        precondition(format.sampleFormat == .float32)
        let dataBytes = samples.count * 4
        var d = Data(capacity: 128 + (metadata?.count ?? 0) + dataBytes)
        func be32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        func be64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        func fourcc(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        fourcc("caff"); d.append(contentsOf: [0, 1, 0, 0])            // version 1, flags 0
        fourcc("desc"); be64(32)
        be64(Double(format.sampleRate).bitPattern)
        fourcc("lpcm")
        be32(1 | 2)                                                    // float | little-endian
        be32(UInt32(4 * format.channelCount))                          // bytes per packet
        be32(1)                                                        // frames per packet
        be32(UInt32(format.channelCount))
        be32(32)
        if let metadata {
            // CAF info chunk: UInt32 entry count, then NUL-terminated key/value pairs.
            var body = Data()
            withUnsafeBytes(of: UInt32(1).bigEndian) { body.append(contentsOf: $0) }
            body.append(contentsOf: Array(metadataKey.utf8)); body.append(0)
            body.append(metadata); body.append(0)
            fourcc("info"); be64(UInt64(body.count)); d.append(body)
        }
        fourcc("data"); be64(UInt64(dataBytes + 4)); be32(0)           // size includes edit count
        d.append(UnsafeBufferPointer(start: UnsafeRawPointer(samples.baseAddress)?.assumingMemoryBound(to: UInt8.self),
                                     count: dataBytes))
        return d
    }

    public struct Decoded: Sendable {
        public var format: AudioFormat
        public var samples: [Float]
        public var metadata: Data?
        /// Frames declared by the data chunk; larger than `frameCount` when the file was truncated (salvage mode).
        public var declaredFrames: Int
        public var frameCount: Int { samples.count / format.channelCount }
        public var isTruncated: Bool { frameCount < declaredFrames }
    }

    public enum DecodeError: Error, Equatable { case notCAF, unsupported, truncated(expected: Int, actual: Int) }

    /// Decodes a segment. A data chunk shorter than declared throws `.truncated`, unless `salvage` is set, in which case
    /// the whole frames that are present are returned (`isTruncated == true`).
    public static func decode(_ data: Data, salvage: Bool = false) throws -> Decoded {
        guard data.count >= 8, data.prefix(4) == Data("caff".utf8) else { throw DecodeError.notCAF }
        func be32(_ o: Int) -> UInt32 { data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) } }
        func be64(_ o: Int) -> UInt64 { data.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt64.self)) } }
        var format: AudioFormat?
        var metadata: Data?
        var offset = 8
        while offset + 12 <= data.count {
            let type = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = Int(Int64(bitPattern: be64(offset + 4)))
            let body = offset + 12
            switch type {
            case "desc":
                guard size == 32, body + 32 <= data.count, data[body + 8..<body + 12] == Data("lpcm".utf8),
                      be32(body + 12) == 3, be32(body + 28) == 32 else { throw DecodeError.unsupported }
                let rate = Double(bitPattern: be64(body))
                format = AudioFormat(sampleRate: Int(rate.rounded()), channelCount: Int(be32(body + 24)), sampleFormat: .float32)
            case "info":
                guard body + size <= data.count, size >= 4 else { break }
                // Parse key/value pairs; keep our key.
                let parts = data[(body + 4)..<(body + size)].split(separator: 0, omittingEmptySubsequences: false)
                var i = 0
                while i + 1 < parts.count {
                    if String(decoding: parts[i], as: UTF8.self) == metadataKey { metadata = Data(parts[i + 1]) }
                    i += 2
                }
            case "data":
                guard let format, format.channelCount > 0 else { throw DecodeError.unsupported }
                let bytesPerFrame = 4 * format.channelCount
                let declared = size - 4
                let available = data.count - (body + 4)
                guard declared >= 0, declared % bytesPerFrame == 0 else { throw DecodeError.unsupported }
                if available < declared && !salvage { throw DecodeError.truncated(expected: declared, actual: available) }
                let usable = min(declared, available) / bytesPerFrame * bytesPerFrame
                let samples: [Float] = data.withUnsafeBytes { raw in
                    (0..<usable / 4).map { raw.loadUnaligned(fromByteOffset: body + 4 + $0 * 4, as: Float.self) }
                }
                return Decoded(format: format, samples: samples, metadata: metadata, declaredFrames: declared / bytesPerFrame)
            default:
                break
            }
            offset = body + max(0, size)
        }
        throw format == nil ? DecodeError.notCAF : DecodeError.truncated(expected: -1, actual: 0)
    }

    /// Reads the embedded segment metadata (decodes the file; segments are small).
    public static func metadata(of data: Data) -> AudioSegmentRecord? {
        guard let d = try? decode(data, salvage: true), let m = d.metadata else { return nil }
        return try? ContractCoding.decode(AudioSegmentRecord.self, from: m)
    }
}
