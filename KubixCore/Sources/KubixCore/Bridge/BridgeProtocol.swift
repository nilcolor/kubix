import Foundation

public enum BridgeProtocolError: Error, Equatable, Sendable {
    case unknownFrameType
    case invalidPayloadLength
    case invalidNonce
    case invalidFailureMessage
    case unexpectedFrame
    case truncatedFrame
    case decoderClosed
    case invalidSocketPath
    case socketPathTooLong
}

/// Only these literal messages may cross the relay. Callers cannot accidentally forward a
/// Kubernetes Status, plugin output, credential, or arbitrary error description to the child.
public enum BridgeFailure: String, CaseIterable, Sendable {
    case connection = "The terminal connection failed."
    case session = "The terminal session failed."
    case protocolViolation = "The terminal protocol is invalid."
    case authentication = "The terminal handshake failed."
    case cancelled = "The terminal session was cancelled."
}

/// Local terminal dimensions follow the UInt16 convention, including zero, but use binary
/// encoding rather than the Kubernetes resize JSON. The relay has no Kubernetes dependency.
public struct BridgeSize: Equatable, Sendable {
    public let columns: UInt16
    public let rows: UInt16

    public init(columns: UInt16, rows: UInt16) {
        self.columns = columns
        self.rows = rows
    }
}

/// Local byte-stream protocol; each frame is a type byte, UInt32 big-endian payload byte count,
/// then payload. No version negotiation or Kubernetes channel framing is implied.
///
/// Types and strict payload bounds:
/// - 1 hello: exactly 32 nonce bytes (256 bits; not its environment hex representation).
/// - 2 data: 0...65,536 opaque bytes, in either direction.
/// - 3 resize: exactly 4 bytes, UInt16 big-endian columns then rows (0...65,535).
/// - 4 closeInput: no payload; child stdin EOF, not Ctrl-D or whole-session EOF.
/// - 5 exit: exactly 1 unsigned byte, remote exit code 0...255.
/// - 6 failure: 1...128 UTF-8 bytes, exactly one of BridgeFailure's generic literals.
///
/// hello/resize/closeInput travel child → parent; exit/failure travel parent → child.
/// Diagnostics intentionally never render nonce or data bytes.
public enum BridgeFrame: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let headerByteCount = 5
    public static let maximumDataByteCount = 65_536
    public static let maximumFailureByteCount = 128

    case hello(BridgeNonce)
    case data(Data)
    case resize(BridgeSize)
    case closeInput
    case exit(code: UInt8)
    case failure(BridgeFailure)

    enum Kind: UInt8, Sendable {
        case hello = 1, data, resize, closeInput, exit, failure

        func validate(length: Int) throws {
            let valid: Bool
            switch self {
            case .hello: valid = length == BridgeNonce.byteCount
            case .data: valid = (0...BridgeFrame.maximumDataByteCount).contains(length)
            case .resize: valid = length == 4
            case .closeInput: valid = length == 0
            case .exit: valid = length == 1
            case .failure: valid = (1...BridgeFrame.maximumFailureByteCount).contains(length)
            }
            guard valid else { throw BridgeProtocolError.invalidPayloadLength }
        }
    }

    private var kind: Kind {
        switch self {
        case .hello: .hello
        case .data: .data
        case .resize: .resize
        case .closeInput: .closeInput
        case .exit: .exit
        case .failure: .failure
        }
    }

    public func encoded() throws -> Data {
        let payload: Data
        switch self {
        case .hello(let nonce): payload = nonce.wireBytes
        case .data(let bytes): payload = bytes
        case .resize(let size):
            payload = Data([
                UInt8(size.columns >> 8), UInt8(truncatingIfNeeded: size.columns),
                UInt8(size.rows >> 8), UInt8(truncatingIfNeeded: size.rows),
            ])
        case .closeInput: payload = Data()
        case .exit(let code): payload = Data([code])
        case .failure(let message): payload = Data(message.rawValue.utf8)
        }
        try kind.validate(length: payload.count)
        let length = UInt32(payload.count)
        return Data([
            kind.rawValue, UInt8(length >> 24), UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length),
        ]) + payload
    }

    static func decode(kind: Kind, payload: Data) throws -> BridgeFrame {
        try kind.validate(length: payload.count)
        switch kind {
        case .hello: return try .hello(BridgeNonce(bytes: payload))
        case .data: return .data(payload)
        case .resize:
            let bytes = Array(payload)
            return .resize(BridgeSize(
                columns: UInt16(bytes[0]) << 8 | UInt16(bytes[1]),
                rows: UInt16(bytes[2]) << 8 | UInt16(bytes[3])
            ))
        case .closeInput: return .closeInput
        case .exit: return .exit(code: payload[payload.startIndex])
        case .failure:
            guard let text = String(data: payload, encoding: .utf8),
                  let message = BridgeFailure(rawValue: text) else {
                throw BridgeProtocolError.invalidFailureMessage
            }
            return .failure(message)
        }
    }

    public var description: String { "BridgeFrame(\(kind), payload: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
