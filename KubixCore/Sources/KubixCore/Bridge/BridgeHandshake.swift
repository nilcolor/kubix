import Foundation

/// The runtime must supply 32 cryptographically random bytes per session; this pure type
/// neither generates entropy nor reads environment variables. Pass the 64 hex digits through
/// KUBIX_BRIDGE_NONCE, never argv or logs. Wire hello carries the original 32 bytes.
public struct BridgeNonce: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let byteCount = 32
    let wireBytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else { throw BridgeProtocolError.invalidNonce }
        wireBytes = bytes
    }

    public init(environmentValue: String) throws {
        guard environmentValue.utf8.count == Self.byteCount * 2 else { throw BridgeProtocolError.invalidNonce }
        let digits = Array(environmentValue.utf8)
        var bytes = Data()
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let high = Self.hexDigit(digits[index]), let low = Self.hexDigit(digits[index + 1]) else {
                throw BridgeProtocolError.invalidNonce
            }
            bytes.append(high << 4 | low)
        }
        wireBytes = bytes
    }

    public var environmentValue: String { wireBytes.map { String(format: "%02x", $0) }.joined() }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 65 + 10
        case 97...102: byte - 97 + 10
        default: nil
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        // Compare all bytes rather than exiting at the first mismatch.
        zip(lhs.wireBytes, rhs.wireBytes).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    public var description: String { "BridgeNonce(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Pure child → parent validation, owned once per session and reused across connection attempts.
/// Reference identity prevents a copied validator from reviving a consumed nonce. This mutable
/// object is deliberately not Sendable: the future IO owner must serialize calls.
/// The first attempted frame consumes the nonce, whether valid or not. Any violation fails
/// closed; no retry, second hello, or input before initial resize is accepted on this session.
public final class BridgeHandshake: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public enum State: String, Sendable {
        case awaitingHello, awaitingInitialResize, relaying, inputClosed, failed
    }

    public private(set) var state: State = .awaitingHello
    private var expectedNonce: BridgeNonce?

    public init(expectedNonce: BridgeNonce) {
        self.expectedNonce = expectedNonce
    }

    public func accept(_ frame: BridgeFrame) throws {
        do {
            try validate(frame)
        } catch {
            expectedNonce = nil
            state = .failed
            throw error
        }
    }

    private func validate(_ frame: BridgeFrame) throws {
        switch state {
        case .awaitingHello:
            let expected = expectedNonce
            expectedNonce = nil
            guard case .hello(let received) = frame else { throw BridgeProtocolError.unexpectedFrame }
            guard received == expected else { throw BridgeProtocolError.invalidNonce }
            state = .awaitingInitialResize
        case .awaitingInitialResize:
            guard case .resize = frame else { throw BridgeProtocolError.unexpectedFrame }
            state = .relaying
        case .relaying, .inputClosed:
            try validateRelay(frame)
        case .failed:
            throw BridgeProtocolError.unexpectedFrame
        }
    }

    private func validateRelay(_ frame: BridgeFrame) throws {
        switch frame {
        case .resize: break
        case .data(let bytes) where state == .relaying:
            guard bytes.count <= BridgeFrame.maximumDataByteCount else { throw BridgeProtocolError.invalidPayloadLength }
        case .closeInput where state == .relaying: state = .inputClosed
        default: throw BridgeProtocolError.unexpectedFrame
        }
    }

    public var description: String { "BridgeHandshake(\(state.rawValue))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
