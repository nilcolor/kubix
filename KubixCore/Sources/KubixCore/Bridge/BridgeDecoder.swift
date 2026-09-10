import Foundation

/// Buffers at most a five-byte header or one validated, bounded payload. Never appends an
/// entire incoming read before inspecting its header. The caller owns read/output queue bounds.
/// Any error poisons this decoder; a new connection needs a new instance. append returns
/// complete frames in wire order; if a read is malformed, none from that call are delivered.
public struct BridgeDecoder: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private var header = Data()
    private var payload = Data()
    private var kind: BridgeFrame.Kind?
    private var expectedLength = 0
    private var closed = false

    public init() {}

    public var bufferedByteCount: Int { header.count + payload.count }

    public mutating func append(_ bytes: Data) throws -> [BridgeFrame] {
        guard !closed else { throw BridgeProtocolError.decoderClosed }
        do {
            return try consume(bytes)
        } catch {
            discardAndClose()
            throw error
        }
    }

    /// Call on byte-stream EOF. Incomplete headers/payloads are never silently discarded.
    /// A clean frame boundary does not imply a successful remote exit; the relay must still
    /// require an explicit exit/failure frame when it owns the connection lifecycle.
    public mutating func finish() throws {
        guard !closed else { throw BridgeProtocolError.decoderClosed }
        let incomplete = !header.isEmpty || kind != nil
        discardAndClose()
        if incomplete { throw BridgeProtocolError.truncatedFrame }
    }

    private mutating func consume(_ bytes: Data) throws -> [BridgeFrame] {
        var frames: [BridgeFrame] = []
        var cursor = bytes.startIndex
        while cursor < bytes.endIndex {
            if kind == nil {
                let count = min(BridgeFrame.headerByteCount - header.count, bytes.endIndex - cursor)
                header.append(contentsOf: bytes[cursor..<(cursor + count)])
                cursor += count
                guard header.count == BridgeFrame.headerByteCount else { continue }
                guard let nextKind = BridgeFrame.Kind(rawValue: header[header.startIndex]) else {
                    throw BridgeProtocolError.unknownFrameType
                }
                let length = header.dropFirst().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                // UInt32 fits Int on the supported 64-bit macOS target. Validate *before*
                // reserving or copying payload bytes, even when this read contains more bytes.
                try nextKind.validate(length: Int(length))
                kind = nextKind
                expectedLength = Int(length)
                header = Data()
                payload.reserveCapacity(expectedLength)
            }
            let count = min(expectedLength - payload.count, bytes.endIndex - cursor)
            payload.append(contentsOf: bytes[cursor..<(cursor + count)])
            cursor += count
            if payload.count == expectedLength, let kind {
                frames.append(try BridgeFrame.decode(kind: kind, payload: payload))
                self.kind = nil
                payload = Data()
                expectedLength = 0
            }
        }
        return frames
    }

    private mutating func discardAndClose() {
        header = Data()
        payload = Data()
        kind = nil
        expectedLength = 0
        closed = true
    }

    public var description: String { "BridgeDecoder(bufferedBytes: \(bufferedByteCount), closed: \(closed))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
