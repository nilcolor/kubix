import Foundation

public struct KubernetesTable: Decodable, Equatable, Sendable {
    public let apiVersion: String
    public let kind: String
    public let metadata: ListMetadata?
    /// nil means reuse the previous schema; an empty array is an explicitly supplied schema.
    public let columnDefinitions: [ColumnDefinition]?
    public let rows: [Row]

    public struct ListMetadata: Decodable, Equatable, Sendable {
        public let resourceVersion: String?
        public let continuation: String?

        enum CodingKeys: String, CodingKey {
            case resourceVersion
            case continuation = "continue"
        }
    }

    public struct ColumnDefinition: Decodable, Equatable, Sendable {
        public let name: String
        /// Preserve future/custom types instead of rejecting an otherwise readable Table.
        public let type: String
        public let format: String?
        public let description: String?
        public let priority: Int
        public var isWideOnly: Bool { priority > 0 }

        enum CodingKeys: String, CodingKey { case name, type, format, description, priority }

        /// For the columns the app computes itself; the server's own arrive decoded.
        public init(name: String, type: String, format: String? = nil, description: String? = nil, priority: Int = 0) {
            self.name = name
            self.type = type
            self.format = format
            self.description = description
            self.priority = priority
        }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            name = try values.decode(String.self, forKey: .name)
            type = try values.decode(String.self, forKey: .type)
            format = try values.decodeIfPresent(String.self, forKey: .format)
            description = try values.decodeIfPresent(String.self, forKey: .description)
            priority = try values.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        }
    }

    public struct Row: Decodable, Equatable, Sendable {
        public let cells: [TableCell]
        public let object: RowObject?

        enum CodingKeys: String, CodingKey { case cells, object }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            cells = try values.decodeIfPresent([TableCell].self, forKey: .cells) ?? []
            object = try values.decodeIfPresent(RowObject.self, forKey: .object)
        }
    }

    /// Decode only metadata, even if a server returns a full object despite includeObject=Metadata.
    public struct RowObject: Decodable, Equatable, Sendable {
        public let apiVersion: String?
        public let kind: String?
        public let metadata: KubernetesObjectMetadata?
    }

    enum CodingKeys: String, CodingKey { case apiVersion, kind, metadata, columnDefinitions, rows }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        apiVersion = try values.decode(String.self, forKey: .apiVersion)
        kind = try values.decode(String.self, forKey: .kind)
        guard apiVersion == "meta.k8s.io/v1", kind == "Table" else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected a meta.k8s.io/v1 Table."))
        }
        metadata = try values.decodeIfPresent(ListMetadata.self, forKey: .metadata)
        columnDefinitions = try values.decodeIfPresent([ColumnDefinition].self, forKey: .columnDefinitions)
        rows = try values.decodeIfPresent([Row].self, forKey: .rows) ?? []
    }

    public func columns(reusing previous: [ColumnDefinition]?) -> [ColumnDefinition]? {
        columnDefinitions ?? previous
    }
}

/// Optional identity fields also allow progress-only metadata; PodRow validates actual resource identity.
public struct KubernetesObjectMetadata: Decodable, Equatable, Sendable {
    public let uid: String?
    public let name: String?
    public let namespace: String?
    public let resourceVersion: String?
    public let creationTimestamp: Date?

    enum CodingKeys: String, CodingKey { case uid, name, namespace, resourceVersion, creationTimestamp }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        uid = try values.decodeIfPresent(String.self, forKey: .uid)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        namespace = try values.decodeIfPresent(String.self, forKey: .namespace)
        resourceVersion = try values.decodeIfPresent(String.self, forKey: .resourceVersion)
        if let timestamp = try values.decodeIfPresent(String.self, forKey: .creationTimestamp) {
            guard let date = RFC3339.date(from: timestamp) else {
                throw DecodingError.dataCorruptedError(forKey: .creationTimestamp, in: values, debugDescription: "Expected an RFC3339 timestamp.")
            }
            creationTimestamp = date
        } else {
            creationTimestamp = nil
        }
    }
}

/// Cells follow their JSON value, not the declared column type. Servers can print strings in numeric columns.
public enum TableCell: Codable, Equatable, Sendable {
    case string(String)
    case number(Decimal)
    case boolean(Bool)
    case null
    case array([TableCell])
    case object([String: TableCell])

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let string = try? value.decode(String.self) {
            self = .string(string)
        } else if let boolean = try? value.decode(Bool.self) {
            self = .boolean(boolean)
        } else if let number = try? value.decode(Decimal.self) {
            self = .number(number)
        } else if let array = try? value.decode([TableCell].self) {
            self = .array(array)
        } else {
            self = .object(try value.decode([String: TableCell].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .boolean(let boolean): try value.encode(boolean)
        case .null: try value.encodeNil()
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        }
    }

    public var displayText: String {
        switch self {
        case .string(let string): return string
        case .number(let number): return NSDecimalNumber(decimal: number).stringValue
        case .boolean(let boolean): return boolean ? "true" : "false"
        case .null: return ""
        case .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(self) else { return "<invalid cell>" }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
