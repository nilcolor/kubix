import Foundation

public enum RemoteCommandProtocolError: Error, Equatable, Sendable {
    case emptyFrame
    case unknownChannel(UInt8)
    case invalidClose
    case invalidResize
    case malformedStatus
}

/// Kubernetes' terminal dimensions are unsigned 16-bit values, including zero.
public struct RemoteCommandSize: Codable, Equatable, Sendable {
    public let columns: UInt16
    public let rows: UInt16

    public init(columns: UInt16, rows: UInt16) {
        self.columns = columns
        self.rows = rows
    }

    enum CodingKeys: String, CodingKey {
        case columns = "Width"
        case rows = "Height"
    }
}

/// One binary WebSocket message, not a byte-stream fragment. Text is rejected by the transport.
public enum RemoteCommandFrame: Equatable, Sendable {
    public enum Channel: UInt8, CaseIterable, Sendable {
        case stdin = 0, stdout, stderr, error, resize
    }

    case stdin(Data)
    case stdout(Data)
    case stderr(Data)
    case error(Data)
    case resize(RemoteCommandSize)
    case close(Channel)

    public init(data: Data) throws {
        guard let first = data.first else { throw RemoteCommandProtocolError.emptyFrame }
        let payload = data.dropFirst()
        if first == 255 {
            guard payload.count == 1, let channelID = payload.first,
                  let channel = Channel(rawValue: channelID) else {
                throw RemoteCommandProtocolError.invalidClose
            }
            self = .close(channel)
            return
        }
        guard let channel = Channel(rawValue: first) else { throw RemoteCommandProtocolError.unknownChannel(first) }
        switch channel {
        case .stdin: self = .stdin(Data(payload))
        case .stdout: self = .stdout(Data(payload))
        case .stderr: self = .stderr(Data(payload))
        case .error: self = .error(Data(payload))
        case .resize:
            guard let size = try? JSONDecoder().decode(RemoteCommandSize.self, from: payload) else {
                throw RemoteCommandProtocolError.invalidResize
            }
            self = .resize(size)
        }
    }

    public func encoded() throws -> Data {
        switch self {
        case .stdin(let payload): Data([Channel.stdin.rawValue]) + payload
        case .stdout(let payload): Data([Channel.stdout.rawValue]) + payload
        case .stderr(let payload): Data([Channel.stderr.rawValue]) + payload
        case .error(let payload): Data([Channel.error.rawValue]) + payload
        case .resize(let size): try Data([Channel.resize.rawValue]) + JSONEncoder().encode(size)
        case .close(let channel): Data([255, channel.rawValue])
        }
    }
}
