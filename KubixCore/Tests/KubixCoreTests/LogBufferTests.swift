import Foundation
import KubixCore
import Testing

@Suite struct LogBufferTests {
    @Test func ringEvictsInOrderWithinBothLimits() {
        var buffer = LogBuffer(maximumLines: 3, maximumBytes: 8)
        for text in ["aa", "bb", "cc", "dddd", "ee"] { buffer.append(.init(text: text)) }
        #expect(buffer.lines.map(\.text) == ["cc", "dddd", "ee"])
        #expect(buffer.byteCount == 8 && buffer.count == 3 && buffer.evicted == 2)
        #expect(Set(buffer.lines.map(\.id)).count == 3)
        buffer.append(.init(text: "1234567890"))
        #expect(buffer.lines.map(\.text) == ["12345678"])
        #expect(buffer.lines.first?.truncated == true)
        #expect(buffer.byteCount == 8)
    }

    @Test func unfinishedLineDropsExcessThroughNewlineAndRecovers() {
        var decoder = LogLineDecoder(maximumBytes: 4)
        for _ in 0..<100_000 { #expect(decoder.consume(65) == nil) }
        #expect(decoder.pendingByteCount == 4)
        #expect(decoder.consume(10) == DecodedLogLine(text: "AAAA", truncated: true))
        #expect(decoder.pendingByteCount == 0)
        _ = decoder.consume(66)
        #expect(decoder.finish() == DecodedLogLine(text: "B"))
        #expect(decoder.finish() == nil)
    }

    @Test func splitUTF8CRLFEmptyLinesAndFinalPartial() {
        var decoder = LogLineDecoder()
        let bytes = Array("🙂é\r\n\nlast".utf8)
        var lines: [DecodedLogLine] = []
        for byte in bytes { if let line = decoder.consume(byte) { lines.append(line) } }
        #expect(lines == [.init(text: "🙂é"), .init(text: "")])
        #expect(decoder.finish() == .init(text: "last"))
    }

    @Test func invalidAndTruncatedScalarsAreMarkedAndBounded() {
        var decoder = LogLineDecoder(maximumBytes: 3)
        for byte in "🙂discard".utf8 { _ = decoder.consume(byte) }
        let line = decoder.finish()
        #expect(line == .init(text: "�", truncated: true, repairedUTF8: true))
        _ = decoder.consume(255)
        #expect(decoder.finish() == .init(text: "�", repairedUTF8: true))
        var buffer = LogBuffer(maximumBytes: 1)
        buffer.append(.init(text: "🙂"))
        #expect(buffer.byteCount <= 1 && buffer.lines.first?.truncated == true)
    }

    @Test func localFilterPreservesBoundariesAndDoesNotModifyRing() {
        var buffer = LogBuffer()
        buffer.append(.init(text: "segment"), boundary: true)
        buffer.append(.init(text: "Synthetic MATCH"))
        buffer.append(.init(text: "other"))
        #expect(buffer.filtered("match").map(\.text) == ["segment", "Synthetic MATCH"])
        #expect(buffer.filtered("missing").map(\.text) == ["segment"])
        #expect(buffer.filtered("").count == 3 && buffer.count == 3)
    }

    @Test func oversizedConfigurationCannotDisableBounds() {
        let buffer = LogBuffer(maximumLines: .max, maximumBytes: .max)
        #expect(buffer.maximumLines == 2_000 && buffer.maximumBytes == 2_097_152)
        #expect(LogLineDecoder(maximumBytes: .max).maximumBytes == 16_384)
    }
}
