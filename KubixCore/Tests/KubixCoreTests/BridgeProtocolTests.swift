import Foundation
import KubixCore
import Testing

@Suite struct BridgeProtocolTests {
    @Test func wireTypesLengthsAndIntegerByteOrderAreExplicit() throws {
        let nonceBytes = Data(0..<32)
        let nonce = try BridgeNonce(bytes: nonceBytes)
        #expect(try BridgeFrame.hello(nonce).encoded() == header(1, 32) + nonceBytes)
        let data = Data(repeating: 0xff, count: 258)
        #expect(try BridgeFrame.data(data).encoded() == Data([2, 0, 0, 1, 2]) + data)
        #expect(try BridgeFrame.resize(BridgeSize(columns: 0x1234, rows: 0xabcd)).encoded()
            == Data([3, 0, 0, 0, 4, 0x12, 0x34, 0xab, 0xcd]))
        #expect(try BridgeFrame.closeInput.encoded() == Data([4, 0, 0, 0, 0]))
        #expect(try BridgeFrame.exit(code: 255).encoded() == Data([5, 0, 0, 0, 1, 255]))
        let message = Data(BridgeFailure.session.rawValue.utf8)
        #expect(try BridgeFrame.failure(.session).encoded() == header(6, UInt32(message.count)) + message)
    }

    @Test func allFrameTypesRoundTripIncludingDataWithNonzeroStartIndex() throws {
        for frame in try sampleFrames() {
            let wire = try frame.encoded()
            var decoder = BridgeDecoder()
            #expect(try decoder.append((Data([99, 99]) + wire).dropFirst(2)) == [frame])
            #expect(decoder.bufferedByteCount == 0)
            try decoder.finish()
        }
    }

    @Test func everySplitPointWorksAcrossHeadersPayloadsAndFrameBoundaries() throws {
        let frames = try sampleFrames()
        let wire = try frames.reduce(into: Data()) { $0.append(try $1.encoded()) }
        for split in 0...wire.count {
            var decoder = BridgeDecoder()
            var decoded = try decoder.append(wire.prefix(split))
            decoded += try decoder.append(wire.dropFirst(split))
            #expect(decoded == frames)
            #expect(decoder.bufferedByteCount == 0)
            try decoder.finish()
        }
    }

    @Test func oneByteAtATimeAndEmptyReadsDoNotLoseFrames() throws {
        let frames = try sampleFrames()
        let wire = try frames.reduce(into: Data()) { $0.append(try $1.encoded()) }
        var decoder = BridgeDecoder()
        var decoded: [BridgeFrame] = []
        for byte in wire {
            #expect(try decoder.append(Data()).isEmpty)
            decoded += try decoder.append(Data([byte]))
            #expect(decoder.bufferedByteCount <= BridgeFrame.maximumDataByteCount)
        }
        #expect(decoded == frames)
        #expect(try decoder.append(Data()).isEmpty)
        try decoder.finish()
    }

    @Test func coalescedFramesPreserveOrderAndRetainOnlyIncompleteTail() throws {
        let output = BridgeFrame.data(Data("before exit".utf8))
        let final = BridgeFrame.exit(code: 42)
        let wire = try output.encoded() + final.encoded()
        var decoder = BridgeDecoder()
        #expect(try decoder.append(wire.dropLast()) == [output])
        #expect(decoder.bufferedByteCount == 0) // Exit header consumed; waiting for its one payload byte.
        #expect(try decoder.append(wire.suffix(1)) == [final])
        #expect(decoder.bufferedByteCount == 0)
        try decoder.finish()
    }

    @Test func maximumDataIsAcceptedWithoutTreatingAReadAsOneFrame() throws {
        let maximum = BridgeFrame.maximumDataByteCount
        let payload = Data(repeating: 0xa5, count: maximum)
        let frame = BridgeFrame.data(payload)
        let wire = try frame.encoded()
        #expect(wire.prefix(5) == Data([2, 0, 1, 0, 0]))
        var decoder = BridgeDecoder()
        #expect(try decoder.append(wire.dropLast()).isEmpty)
        #expect(decoder.bufferedByteCount == maximum - 1)
        #expect(try decoder.append(wire.suffix(1) + wire + wire) == [frame, frame, frame])
        #expect(decoder.bufferedByteCount == 0)
        try decoder.finish()
        #expect(throws: BridgeProtocolError.invalidPayloadLength) {
            try BridgeFrame.data(Data(repeating: 0, count: maximum + 1)).encoded()
        }
    }

    @Test func allTypesRejectInvalidLengthsAsSoonAsTheHeaderCompletes() throws {
        let invalid: [(UInt8, [UInt32])] = [
            (1, [0, 1, 31, 33, .max]), (2, [65_537, .max]), (3, [0, 1, 3, 5, .max]),
            (4, [1, 2, .max]), (5, [0, 2, 4, .max]), (6, [0, 129, .max]),
        ]
        for (type, lengths) in invalid {
            for length in lengths {
                var decoder = BridgeDecoder()
                let wire = header(type, length)
                #expect(try decoder.append(wire.prefix(4)).isEmpty)
                #expect(decoder.bufferedByteCount == 4)
                // Only a header is supplied, even for the 4 GiB advertisement.
                #expect(throws: BridgeProtocolError.invalidPayloadLength) { try decoder.append(wire.suffix(1)) }
                #expect(decoder.bufferedByteCount == 0)
                #expect(throws: BridgeProtocolError.decoderClosed) { try decoder.append(Data()) }
                #expect(throws: BridgeProtocolError.decoderClosed) { try decoder.finish() }
            }
        }
    }

    @Test func malformedHeadersRejectCoalescedPayloadWithoutRetainingIt() {
        for type in UInt8(1)...6 {
            var decoder = BridgeDecoder()
            let wire = header(type, .max) + Data(repeating: 0x41, count: 100_000)
            #expect(throws: BridgeProtocolError.invalidPayloadLength) { try decoder.append(wire) }
            #expect(decoder.bufferedByteCount == 0)
        }
        for type in [UInt8(0)] + Array(UInt8(7)...255) {
            var decoder = BridgeDecoder()
            #expect(throws: BridgeProtocolError.unknownFrameType) { try decoder.append(header(type, .max)) }
            #expect(decoder.bufferedByteCount == 0)
        }
    }

    @Test func malformedReadPoisonsDecoderInsteadOfResynchronizing() throws {
        let valid = try BridgeFrame.data(Data([65])).encoded()
        var decoder = BridgeDecoder()
        #expect(throws: BridgeProtocolError.invalidPayloadLength) {
            try decoder.append(valid + header(4, 1) + Data([0]) + valid)
        }
        #expect(decoder.bufferedByteCount == 0)
        #expect(throws: BridgeProtocolError.decoderClosed) { try decoder.append(valid) }
    }

    @Test func everyTruncatedFrameRejectsEOFAndCannotResume() throws {
        for frame in try sampleFrames() {
            let wire = try frame.encoded()
            for count in 1..<wire.count {
                var decoder = BridgeDecoder()
                #expect(try decoder.append(wire.prefix(count)).isEmpty)
                #expect(throws: BridgeProtocolError.truncatedFrame) { try decoder.finish() }
                #expect(decoder.bufferedByteCount == 0)
                #expect(throws: BridgeProtocolError.decoderClosed) { try decoder.append(wire.dropFirst(count)) }
            }
        }
    }

    @Test func boundaryEOFDoesNotInventExit() throws {
        var decoder = BridgeDecoder()
        #expect(try decoder.append(Data()).isEmpty)
        try decoder.finish()
        #expect(throws: BridgeProtocolError.decoderClosed) { try decoder.append(Data()) }
        var outputOnly = BridgeDecoder()
        let frame = BridgeFrame.data(Data([65]))
        #expect(try outputOnly.append(frame.encoded()) == [frame])
        try outputOnly.finish()
    }

    @Test(arguments: BridgeFailure.allCases)
    func failuresUseOnlyBoundedGenericUTF8Literals(message: BridgeFailure) throws {
        let wire = try BridgeFrame.failure(message).encoded()
        let payload = wire.dropFirst(5)
        #expect(!payload.isEmpty && payload.count <= BridgeFrame.maximumFailureByteCount)
        #expect(String(data: payload, encoding: .utf8) == message.rawValue)
        var decoder = BridgeDecoder()
        #expect(try decoder.append(wire) == [.failure(message)])
        try decoder.finish()
    }

    @Test func failureRejectsArbitraryTextObjectsCredentialsAndInvalidUTF8() {
        let invalid = [
            Data([0xff]), Data([0]), Data("Bearer SYNTHETIC_SECRET".utf8),
            Data(#"{"kind":"Status","message":"synthetic credential"}"#.utf8),
            Data("The terminal session failed.\n".utf8), Data("The terminal session failed.\0".utf8),
            Data("世界".utf8), Data(repeating: 65, count: 128),
        ]
        for payload in invalid {
            var decoder = BridgeDecoder()
            #expect(throws: BridgeProtocolError.invalidFailureMessage) {
                try decoder.append(header(6, UInt32(payload.count)) + payload)
            }
            #expect(decoder.bufferedByteCount == 0)
        }
    }

    @Test(arguments: [UInt8(0), 1, 42, 127, 255])
    func exitIsNotFailureOrAnImplicitSuccessfulClose(code: UInt8) throws {
        var decoder = BridgeDecoder()
        let exit = BridgeFrame.exit(code: code)
        let failure = BridgeFrame.failure(.connection)
        let close = BridgeFrame.closeInput
        #expect(try decoder.append(exit.encoded() + failure.encoded() + close.encoded()) == [exit, failure, close])
        #expect(exit != failure && exit != close)
        #expect(try exit.encoded().first == 5)
        #expect(try failure.encoded().first == 6)
    }

    @Test func emptyDataHalfCloseAndControlCharactersStayDistinct() throws {
        let frames: [BridgeFrame] = [.data(Data()), .data(Data([3, 4, 0, 255])), .closeInput, .data(Data("output".utf8))]
        var decoder = BridgeDecoder()
        let decoded = try decoder.append(frames.reduce(into: Data()) { $0.append(try $1.encoded()) })
        #expect(decoded == frames)
        #expect(try frames[0].encoded() == Data([2, 0, 0, 0, 0]))
        #expect(try frames[2].encoded() == Data([4, 0, 0, 0, 0]))
        try decoder.finish()
    }

    @Test(arguments: [
        BridgeSize(columns: 0, rows: 0), BridgeSize(columns: 80, rows: 24),
        BridgeSize(columns: .max, rows: .max), BridgeSize(columns: 0, rows: .max),
    ])
    func dimensionBoundariesRoundTrip(size: BridgeSize) throws {
        var decoder = BridgeDecoder()
        #expect(try decoder.append(BridgeFrame.resize(size).encoded()) == [.resize(size)])
        try decoder.finish()
    }

    private func header(_ type: UInt8, _ length: UInt32) -> Data {
        Data([
            type, UInt8(length >> 24), UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length),
        ])
    }

    private func sampleFrames() throws -> [BridgeFrame] {
        [
            .hello(try BridgeNonce(bytes: Data(0..<32))),
            .data(Data()), .data(Data([0, 3, 4, 255, 128, 10])), .data(Data("世界\r\n".utf8)),
            .resize(BridgeSize(columns: 120, rows: 40)), .closeInput, .exit(code: 0), .exit(code: 255),
        ] + BridgeFailure.allCases.map { .failure($0) }
    }
}
