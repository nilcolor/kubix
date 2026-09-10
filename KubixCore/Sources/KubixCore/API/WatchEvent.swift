import Foundation

public enum WatchDecodingError: Error, Equatable, Sendable {
    case malformedEvent, unknownEventType, invalidPayload, invalidUTF8
    case lineTooLong(limit: Int), truncatedEOF, decoderClosed
}

public struct WatchBookmark: Equatable, Sendable {
    public let resourceVersion: String
    public let columnDefinitions: [KubernetesTable.ColumnDefinition]?

    public init(resourceVersion: String, columnDefinitions: [KubernetesTable.ColumnDefinition]? = nil) throws {
        guard !resourceVersion.isEmpty else { throw WatchDecodingError.invalidPayload }
        self.resourceVersion = resourceVersion
        self.columnDefinitions = columnDefinitions
    }
}

public enum WatchEvent: Decodable, Equatable, Sendable {
    case added(KubernetesTable), modified(KubernetesTable), deleted(KubernetesTable)
    case bookmark(WatchBookmark)
    case error(KubernetesStatus)

    private enum CodingKeys: String, CodingKey { case type, object }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .type) {
        case "ADDED": self = .added(try values.decode(KubernetesTable.self, forKey: .object))
        case "MODIFIED": self = .modified(try values.decode(KubernetesTable.self, forKey: .object))
        case "DELETED": self = .deleted(try values.decode(KubernetesTable.self, forKey: .object))
        case "BOOKMARK":
            let table = try values.decode(KubernetesTable.self, forKey: .object)
            // Negotiated Table bookmarks have sparse PartialObjectMetadata rows, even with printed cells.
            let versions = table.rows.compactMap { $0.object?.metadata?.resourceVersion }
            guard versions.allSatisfy({ !$0.isEmpty }),
                  let version = table.metadata?.resourceVersion ?? versions.last else { throw WatchDecodingError.invalidPayload }
            self = .bookmark(try WatchBookmark(resourceVersion: version, columnDefinitions: table.columnDefinitions))
        case "ERROR": self = .error(try values.decode(KubernetesStatus.self, forKey: .object))
        default: throw WatchDecodingError.unknownEventType
        }
        try validate()
    }

    /// Also used by the state machine: public enum cases can bypass Decodable.
    public func validate() throws {
        switch self {
        case .added(let table), .modified(let table), .deleted(let table):
            _ = try Self.dataRows(table)
        case .bookmark(let bookmark):
            guard !bookmark.resourceVersion.isEmpty else { throw WatchDecodingError.invalidPayload }
        case .error(let status):
            guard status.apiVersion == "v1", status.kind == "Status",
                  status.status == nil || status.status == "Failure",
                  status.code.map({ (400...599).contains($0) }) ?? (status.reason?.isEmpty == false) else {
                throw WatchDecodingError.invalidPayload
            }
        }
    }

    static func dataRows(_ table: KubernetesTable) throws -> (rows: [PodRow], resourceVersion: String) {
        guard !table.rows.isEmpty, table.metadata?.continuation?.isEmpty != false else { throw WatchDecodingError.invalidPayload }
        do {
            let rows = try table.rows.map(PodRow.init)
            guard Set(rows.map(\.id)).count == rows.count,
                  rows.allSatisfy({ ($0.metadata.resourceVersion ?? table.metadata?.resourceVersion)?.isEmpty == false }),
                  let version = table.metadata?.resourceVersion ?? rows.last?.metadata.resourceVersion,
                  !version.isEmpty else { throw WatchDecodingError.invalidPayload }
            return (rows, version)
        } catch { throw WatchDecodingError.invalidPayload }
    }
}

/// Emits valid prefixes BEFORE a terminal error, even when both occur in one input chunk.
/// After failure, the owner must stop the connection: continuing would silently lose updates.
public struct WatchEventDecoder: Sendable {
    public let maximumLineBytes: Int
    public private(set) var failure: WatchDecodingError?
    public private(set) var isFinished = false
    private var buffer = Data()
    public var bufferedByteCount: Int { buffer.count }

    public init(maximumLineBytes: Int = 1_048_576) {
        precondition(maximumLineBytes > 0)
        self.maximumLineBytes = maximumLineBytes
    }

    public mutating func append(_ bytes: Data) -> [Result<WatchEvent, WatchDecodingError>] {
        if let failure { return [.failure(failure)] }
        guard !isFinished else { return [.failure(.decoderClosed)] }
        var results: [Result<WatchEvent, WatchDecodingError>] = []
        for byte in bytes {
            if byte == 10 {
                let result = decodeLine()
                buffer.removeAll(keepingCapacity: true)
                results.append(result)
                if case .failure(let error) = result { failure = error; break }
            } else {
                guard buffer.count < maximumLineBytes else {
                    let error = WatchDecodingError.lineTooLong(limit: maximumLineBytes)
                    failure = error
                    buffer.removeAll()
                    results.append(.failure(error))
                    break
                }
                buffer.append(byte)
            }
        }
        return results
    }

    public mutating func finish() -> [Result<WatchEvent, WatchDecodingError>] {
        if let failure { return [.failure(failure)] }
        guard !isFinished else { return [.failure(.decoderClosed)] }
        isFinished = true
        guard buffer.isEmpty else {
            buffer.removeAll()
            failure = .truncatedEOF
            return [.failure(.truncatedEOF)]
        }
        return []
    }

    private func decodeLine() -> Result<WatchEvent, WatchDecodingError> {
        guard String(data: buffer, encoding: .utf8) != nil else { return .failure(.invalidUTF8) }
        do { return .success(try JSONDecoder().decode(WatchEvent.self, from: buffer)) } catch let error as WatchDecodingError {
            return .failure(error)
        } catch { return .failure(.malformedEvent) }
    }
}
