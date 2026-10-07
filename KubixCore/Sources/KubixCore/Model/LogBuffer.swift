import Foundation

public struct DecodedLogLine: Equatable, Sendable {
    public let text: String
    public let truncated: Bool
    public let repairedUTF8: Bool

    public init(text: String, truncated: Bool = false, repairedUTF8: Bool = false) {
        self.text = text
        self.truncated = truncated
        self.repairedUTF8 = repairedUTF8
    }
}

/// UTF-8 is decoded only at a line boundary (including EOF/cancellation), so split scalars survive.
/// Oversized lines retain a byte prefix and discard through newline; malformed/truncated scalars
/// use U+FFFD, never fail the whole stream. The UI marks both truncation and encoding repair.
public struct LogLineDecoder: Sendable {
    public let maximumBytes: Int
    private var pending: [UInt8] = []
    private var truncated = false
    public var pendingByteCount: Int { pending.count }

    public init(maximumBytes: Int = 16_384) { self.maximumBytes = max(1, min(maximumBytes, 16_384)) }

    public mutating func consume(_ byte: UInt8) -> DecodedLogLine? {
        if byte == 10 { return finishLine() }
        if pending.count < maximumBytes { pending.append(byte) } else { truncated = true }
        return nil
    }

    public mutating func finish() -> DecodedLogLine? {
        guard !pending.isEmpty || truncated else { return nil }
        return finishLine()
    }

    private mutating func finishLine() -> DecodedLogLine {
        if pending.last == 13, !truncated { pending.removeLast() }
        let valid = String(bytes: pending, encoding: .utf8)
        let line = DecodedLogLine(text: valid ?? String(decoding: pending, as: UTF8.self), truncated: truncated, repairedUTF8: valid == nil)
        pending.removeAll(keepingCapacity: true)
        truncated = false
        return line
    }
}

public struct LogLine: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let text: String
    /// Which stream delivered this line, when the tab has more than one to tell apart. It is kept
    /// beside the text rather than prepended to it, so the filter matches what the pod logged and
    /// the viewer can draw the label differently from the line.
    public let source: String?
    public let isBoundary: Bool
    public let truncated: Bool
    public let repairedUTF8: Bool
}

/// Fixed-slot ring; both line count and UTF-8 bytes are capped. No array prefix retains old storage.
public struct LogBuffer: Sendable {
    public private(set) var maximumLines: Int
    public private(set) var maximumBytes: Int
    private var slots: [LogLine?]
    private var head = 0
    public private(set) var count = 0
    public private(set) var byteCount = 0
    public private(set) var evicted = 0
    private var nextID: UInt64 = 0

    /// A tab shares one ring across every stream it holds, so the bounds scale with the fan-out: a
    /// 2,000-line ring split between forty pods is fifty lines each, which is not a tail.
    public init(sources: Int) {
        self.init(
            maximumLines: min(Self.baseLines + 500 * max(0, sources - 1), Self.maximumAggregateLines),
            maximumBytes: sources > 1 ? Self.maximumAggregateBytes : Self.baseBytes
        )
    }

    public init(maximumLines: Int = LogBuffer.baseLines, maximumBytes: Int = LogBuffer.baseBytes) {
        self.maximumLines = max(1, min(maximumLines, Self.maximumAggregateLines))
        self.maximumBytes = max(1, min(maximumBytes, Self.maximumAggregateBytes))
        slots = Array(repeating: nil, count: self.maximumLines)
    }

    public static let baseLines = 2_000
    public static let baseBytes = 2_097_152
    public static let maximumAggregateLines = 20_000
    public static let maximumAggregateBytes = 8 * 1_024 * 1_024

    public var lines: [LogLine] { (0..<count).compactMap { slots[(head + $0) % maximumLines] } }

    public func filtered(_ filter: String) -> [LogLine] {
        let query = String(filter.prefix(256))
        return lines.filter { $0.isBoundary || query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
    }

    public mutating func append(_ line: DecodedLogLine, source: String? = nil, boundary: Bool = false) {
        // Also bound callers other than the decoder. Repair expansion is included in the byte cap.
        let limit = min(maximumBytes, 49_152)
        let prefix = Array(line.text.utf8.prefix(limit))
        var text = String(decoding: prefix, as: UTF8.self)
        while text.utf8.count > limit { text.removeLast() }
        let bytes = text.utf8.count
        while count > 0 && (count == maximumLines || byteCount + bytes > maximumBytes) { removeFirst() }
        slots[(head + count) % maximumLines] = LogLine(
            id: nextID, text: text, source: source, isBoundary: boundary,
            truncated: line.truncated || line.text.utf8.count > limit, repairedUTF8: line.repairedUTF8
        )
        nextID &+= 1
        count += 1
        byteCount += bytes
    }

    /// Raises the bounds for a tab that has gained streams, keeping every retained line and its id
    /// — the log viewport anchors on a retained id, so a rebuild that renumbered them would scroll
    /// the user somewhere else. Grow-only: shrinking would have to evict lines that are on screen.
    public mutating func grow(for sources: Int) {
        let wider = LogBuffer(sources: sources)
        guard wider.maximumLines > maximumLines || wider.maximumBytes > maximumBytes else { return }
        let retained = lines
        maximumLines = max(maximumLines, wider.maximumLines)
        maximumBytes = max(maximumBytes, wider.maximumBytes)
        slots = Array(repeating: nil, count: maximumLines)
        head = 0
        count = retained.count
        for (index, line) in retained.enumerated() { slots[index] = line }
    }

    private mutating func removeFirst() {
        byteCount -= slots[head]?.text.utf8.count ?? 0
        slots[head] = nil
        head = (head + 1) % maximumLines
        count -= 1
        evicted += 1
    }
}
