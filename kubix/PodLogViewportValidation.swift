#if DEBUG
import AppKit
import KubixCore

/// Exercises the mounted production table through LogService and the session's real bounded ring.
@MainActor enum PodLogViewportValidation {
    static var evidence: [String: String] = [:]
    static var stage = "not started"

    static func check(_ fixture: PodBrowsingFixture, session: LogSession, table: NSTableView) async throws {
        guard let stream = await fixture.transport.logStreams.last else { throw Failure.assertion("stream missing") }
        let driver = Driver(session: session, actions: fixture.actions, table: table, stream: stream)
        try await driver.countEviction()
        try await driver.filterChanges()
        try await driver.byteEviction()
        try await driver.latest()
    }

    @MainActor private struct Driver {
        let session: LogSession
        let actions: AppActions
        let table: NSTableView
        let stream: PodFixtureStream
        var lines: [LogLine] { session.buffer.filtered(session.filter) }

        func countEviction() async throws {
            stage = "full count ring"
            try await append(session.buffer.maximumLines - session.buffer.count)
            try position(id: 1_000, offset: 7)
            record("count-before")
            stage = "count retained anchor"
            try await append(100)
            try expect(id: 1_000, offset: 7)
            guard session.buffer.count == 2_000, session.buffer.lines.first?.id == 100 else {
                throw Failure.assertion("count ring bounds")
            }
            record("count-retained")
            stage = "count evicted anchor"
            try await append(1_000)
            try expect(id: 1_100, offset: 0)
            record("count-fallback")
        }

        func filterChanges() async throws {
            stage = "filtered retained anchor"
            try await filter("viewport keep")
            try position(id: 1_600, offset: 9)
            record("filtered-before")
            try await append(100)
            try expect(id: 1_600, offset: 9)
            record("filtered-retained")
            stage = "filter edit retains anchor"
            try await filter("viewport")
            try expect(id: 1_600, offset: 9)
            record("filter-expanded")
            try await filter("viewport keep")
            try expect(id: 1_600, offset: 9)
            stage = "filter removes anchor"
            try await filter("viewport drop")
            try expect(id: 1_201, offset: 0)
            record("filter-fallback")
            try await unchangedRows()
            try await emptyAndShortFilter()
        }

        private func unchangedRows() async throws {
            stage = "unchanged filtered rows"
            let before = lines
            let cell = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
            try await append(1)
            guard lines == before, let coordinator = table.dataSource as? NativeLogList.Coordinator else {
                throw Failure.assertion("unchanged filtered IDs")
            }
            for _ in 0..<3 { coordinator.update(table) }
            try expect(id: 1_201, offset: 0)
            guard table.view(atColumn: 0, row: 0, makeIfNecessary: true) === cell else {
                throw Failure.assertion("unchanged native cell replaced")
            }
            record("filtered-unchanged")
        }

        private func emptyAndShortFilter() async throws {
            stage = "empty filter"
            try await filter("no-viewport-match")
            record("filter-empty")
            guard table.numberOfRows == 0, table.visibleRect.minY == clampedTop, !session.autoscroll else {
                throw Failure.assertion("empty viewport clamp")
            }
            try await filter("viewport")
            try expect(id: 1_201, offset: 0)
            stage = "short filtered document clamps retained offset"
            try position(id: 3_150, offset: 11)
            try await filter("id-3150 end")
            record("filter-short")
            try expect(id: 3_150, offset: clampedTop - table.rect(ofRow: 0).minY)
            guard table.numberOfRows == 1, table.visibleRect.minY == clampedTop,
                  table.visibleRect.maxY >= table.rect(ofRow: 0).maxY else { throw Failure.assertion("short viewport clamp") }
            try await filter("")
        }

        func byteEviction() async throws {
            stage = "full byte ring"
            try await append(160, bytes: 16_384)
            guard session.buffer.count == 128, session.buffer.byteCount == session.buffer.maximumBytes,
                  session.buffer.count < session.buffer.maximumLines, let first = lines.first else {
                throw Failure.assertion("byte ring bounds")
            }
            let anchor = first.id + 48
            try position(id: anchor, offset: 5)
            record("byte-before")
            stage = "byte retained anchor"
            let evicted = session.buffer.evicted
            try await append(8, bytes: 16_384)
            try expect(id: anchor, offset: 5)
            guard session.buffer.evicted == evicted + 8, session.buffer.count == 128,
                  session.buffer.byteCount == session.buffer.maximumBytes else { throw Failure.assertion("byte eviction count") }
            record("byte-retained")
            stage = "byte evicted anchor"
            try await append(100, bytes: 16_384)
            guard let oldest = lines.first else { throw Failure.assertion("byte fallback missing") }
            try expect(id: oldest.id, offset: 0)
            record("byte-fallback")
        }

        func latest() async throws {
            stage = "Latest without changed rows"
            actions.setLogAutoscroll(session.id, true)
            try await PodBrowsingValidation.until { atLatest }
            record("latest")
            stage = "Latest follows byte eviction"
            try await append(8, bytes: 16_384)
            try await PodBrowsingValidation.until { atLatest }
            record("latest-following")
            stage = "passed"
        }

        private var atLatest: Bool {
            session.autoscroll && table.numberOfRows > 0
                && table.rect(ofRow: table.numberOfRows - 1).maxY <= table.visibleRect.maxY + 0.5
        }

        private var clampedTop: CGFloat {
            guard let clip = table.enclosingScrollView?.contentView else { return .nan }
            var bounds = clip.bounds
            bounds.origin.y = 0
            // Use the native clip's legal extent rather than treating table padding as scrollable.
            return table.convert(clip.constrainBoundsRect(bounds).origin, from: clip).y
        }

        private func append(_ count: Int, bytes: Int? = nil) async throws {
            guard let last = session.buffer.lines.last else { throw Failure.assertion("append missing ring") }
            let end = last.id + UInt64(count)
            var chunk = Data()
            for id in (last.id + 1)..<(end + 1) {
                var text = "viewport \(id.isMultiple(of: 2) ? "keep" : "drop") id-\(id) end"
                if let bytes { text += String(repeating: "x", count: bytes - text.utf8.count) }
                let data = Data((text + "\n").utf8)
                if chunk.count + data.count > 65_536 { stream.yield(chunk); chunk = Data() }
                chunk.append(data)
            }
            if !chunk.isEmpty { stream.yield(chunk) }
            try await PodBrowsingValidation.until { session.buffer.lines.last?.id == end }
            try await rendered()
        }

        private func filter(_ value: String) async throws {
            actions.setLogFilter(session.id, value)
            try await rendered()
        }

        private func rendered() async throws {
            try await PodBrowsingValidation.until {
                let expected = lines
                guard table.numberOfRows == expected.count else { return false }
                guard let last = expected.last else { return true }
                // Inspect synthetic cell content locally, but never copy it to result evidence.
                return (table.view(atColumn: 0, row: expected.count - 1, makeIfNecessary: true) as? NSTextField)?.stringValue == last.text
            }
        }

        private func position(id: UInt64, offset: CGFloat) throws {
            guard let row = lines.firstIndex(where: { $0.id == id }), let scroll = table.enclosingScrollView else {
                throw Failure.assertion("position missing ID")
            }
            scroll.contentView.scroll(to: NSPoint(x: 120, y: table.rect(ofRow: row).minY + offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            try expect(id: id, offset: offset)
        }

        private func expect(id: UInt64, offset: CGFloat) throws {
            let row = table.rows(in: table.visibleRect).location
            guard lines.indices.contains(row), lines[row].id == id,
                  abs(table.visibleRect.minY - table.rect(ofRow: row).minY - offset) < 0.5,
                  abs(table.visibleRect.minX - 120) < 0.5, !session.autoscroll else {
                record("failure")
                throw Failure.assertion(stage)
            }
        }

        private func record(_ name: String) {
            let row = table.rows(in: table.visibleRect).location
            let top = lines.indices.contains(row) ? String(lines[row].id) : "none"
            let offset = lines.indices.contains(row) ? table.visibleRect.minY - table.rect(ofRow: row).minY : 0
            evidence[name] = "rows=\(table.numberOfRows) count=\(session.buffer.count) bytes=\(session.buffer.byteCount) "
                + "evicted=\(session.buffer.evicted) topID=\(top) row=\(row) "
                + "y=\(table.visibleRect.minY) offset=\(offset) x=\(table.visibleRect.minX) autoscroll=\(session.autoscroll)"
                + " clipY=\(table.enclosingScrollView?.contentView.bounds.minY ?? -1) "
                + "height=\(table.frame.height) clipHeight=\(table.enclosingScrollView?.contentView.bounds.height ?? -1)"
                + " clampedTop=\(clampedTop) boundsY=\(table.bounds.minY) frameY=\(table.frame.minY)"
        }
    }

    private enum Failure: Error { case assertion(String) }
}
#endif
