import Foundation
import KubixCore
import Testing

@Suite struct BridgeHandshakeTests {
    @Test func nonceHasExactBinaryAndEnvironmentRepresentations() throws {
        let bytes = Data(0..<32)
        let nonce = try BridgeNonce(bytes: bytes)
        let hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        #expect(nonce.environmentValue == hex)
        #expect(try BridgeNonce(environmentValue: hex) == nonce)
        #expect(try BridgeNonce(environmentValue: hex.uppercased()) == nonce)
        #expect(try BridgeNonce(bytes: (Data([99]) + bytes).dropFirst()) == nonce)
        #expect(try BridgeFrame.hello(nonce).encoded().dropFirst(5) == bytes)
    }

    @Test func nonceRejectsMissingExtraNonhexAndMultibyteValues() {
        for count in [0, 1, 31, 33, 64, 1024] {
            #expect(throws: BridgeProtocolError.invalidNonce) { try BridgeNonce(bytes: Data(repeating: 0, count: count)) }
        }
        let valid = String(repeating: "ab", count: 32)
        let invalid = [
            "", String(valid.dropLast()), valid + "a", " " + valid, valid + "\n",
            String(repeating: "g", count: 64), String(repeating: "é", count: 32),
            "\0" + String(valid.dropFirst()), "0x" + String(valid.dropFirst(2)),
        ]
        for text in invalid {
            #expect(throws: BridgeProtocolError.invalidNonce) { try BridgeNonce(environmentValue: text) }
        }
    }

    @Test func helloInitialResizeThenDataAndHalfCloseUseProductionDecoderAndValidator() throws {
        let nonce = try testNonce()
        let handshake = BridgeHandshake(expectedNonce: nonce)
        #expect(handshake.state == .awaitingHello)
        let frames: [BridgeFrame] = [
            .hello(nonce), .resize(BridgeSize(columns: 80, rows: 24)), .data(Data([3, 4, 255])),
            .resize(BridgeSize(columns: 120, rows: 40)), .data(Data()), .closeInput,
            .resize(BridgeSize(columns: 0, rows: 0)),
        ]
        let states: [BridgeHandshake.State] = [
            .awaitingInitialResize, .relaying, .relaying, .relaying, .relaying, .inputClosed, .inputClosed,
        ]
        var decoder = BridgeDecoder()
        let wire = try frames.reduce(into: Data()) { $0.append(try $1.encoded()) }
        for (frame, state) in zip(try decoder.append(wire), states) {
            try handshake.accept(frame)
            #expect(handshake.state == state)
        }
        try decoder.finish()
    }

    @Test func everyNonceByteParticipatesAndMismatchConsumesTheAttempt() throws {
        let nonce = try testNonce()
        for index in 0..<BridgeNonce.byteCount {
            var bytes = Data(repeating: 0xab, count: BridgeNonce.byteCount)
            bytes[index] ^= 1
            let wrong = try BridgeNonce(bytes: bytes)
            #expect(wrong != nonce)
            let handshake = BridgeHandshake(expectedNonce: nonce)
            #expect(throws: BridgeProtocolError.invalidNonce) { try handshake.accept(.hello(wrong)) }
            #expect(handshake.state == .failed)
            #expect(throws: BridgeProtocolError.unexpectedFrame) { try handshake.accept(.hello(nonce)) }
            #expect(handshake.state == .failed)
        }
    }

    @Test func successfulNonceCannotBeReplayedThroughAnotherReference() throws {
        let nonce = try testNonce()
        let handshake = BridgeHandshake(expectedNonce: nonce)
        let anotherReference = handshake
        try handshake.accept(.hello(nonce))
        #expect(anotherReference.state == .awaitingInitialResize)
        #expect(throws: BridgeProtocolError.unexpectedFrame) { try anotherReference.accept(.hello(nonce)) }
        #expect(handshake.state == .failed)
        #expect(throws: BridgeProtocolError.unexpectedFrame) {
            try handshake.accept(.resize(BridgeSize(columns: 80, rows: 24)))
        }
    }

    @Test func everyNonHelloFrameBeforeAuthenticationConsumesTheSession() throws {
        let nonce = try testNonce()
        let frames: [BridgeFrame] = [
            .data(Data()), .resize(BridgeSize(columns: 80, rows: 24)), .closeInput,
            .exit(code: 0), .failure(.authentication),
        ]
        for frame in frames {
            let handshake = BridgeHandshake(expectedNonce: nonce)
            #expect(throws: BridgeProtocolError.unexpectedFrame) { try handshake.accept(frame) }
            #expect(handshake.state == .failed)
            #expect(throws: BridgeProtocolError.unexpectedFrame) { try handshake.accept(.hello(nonce)) }
        }
    }

    @Test func everyNonResizeFrameAfterHelloIsRejectedIncludingEarlyEOF() throws {
        let nonce = try testNonce()
        let frames: [BridgeFrame] = [.hello(nonce), .data(Data()), .closeInput, .exit(code: 0), .failure(.session)]
        for frame in frames {
            let handshake = BridgeHandshake(expectedNonce: nonce)
            try handshake.accept(.hello(nonce))
            #expect(throws: BridgeProtocolError.unexpectedFrame) { try handshake.accept(frame) }
            #expect(handshake.state == .failed)
        }
    }

    @Test func relayingRejectsRepeatedHelloAndWrongDirectionTerminalFrames() throws {
        let nonce = try testNonce()
        for frame in [BridgeFrame.hello(nonce), .exit(code: 0), .failure(.connection)] {
            let handshake = try readyHandshake()
            #expect(throws: BridgeProtocolError.unexpectedFrame) { try handshake.accept(frame) }
            #expect(handshake.state == .failed)
        }
    }

    @Test func closedInputRejectsFurtherDataAndRepeatedEOFButNotResize() throws {
        for frame in [BridgeFrame.data(Data()), .data(Data([4])), .closeInput] {
            let handshake = try readyHandshake()
            try handshake.accept(.closeInput)
            try handshake.accept(.resize(BridgeSize(columns: .max, rows: .max)))
            #expect(handshake.state == .inputClosed)
            #expect(throws: BridgeProtocolError.unexpectedFrame) { try handshake.accept(frame) }
            #expect(handshake.state == .failed)
        }
    }

    @Test func directInputValidationAlsoRejectsOversizedUnencodedData() throws {
        let handshake = try readyHandshake()
        try handshake.accept(.data(Data(repeating: 0, count: BridgeFrame.maximumDataByteCount)))
        #expect(throws: BridgeProtocolError.invalidPayloadLength) {
            try handshake.accept(.data(Data(repeating: 0, count: BridgeFrame.maximumDataByteCount + 1)))
        }
        #expect(handshake.state == .failed)
    }

    @Test func descriptionsDebugAndReflectionNeverExposeNonceOrBufferedData() throws {
        let nonce = try testNonce()
        let secret = "SYNTHETIC_INPUT_SECRET_DO_NOT_PRINT"
        let dataFrame = BridgeFrame.data(Data(secret.utf8))
        var decoder = BridgeDecoder()
        #expect(try decoder.append(dataFrame.encoded().dropLast()).isEmpty)
        var nonceDecoder = BridgeDecoder()
        #expect(try nonceDecoder.append(BridgeFrame.hello(nonce).encoded().dropLast()).isEmpty)
        let values: [Any] = [
            nonce, BridgeFrame.hello(nonce), dataFrame, decoder, nonceDecoder,
            BridgeHandshake(expectedNonce: nonce), BridgeProtocolError.invalidNonce,
        ]
        for value in values {
            var dumped = ""
            dump(value, to: &dumped)
            let diagnostics = String(describing: value) + String(reflecting: value) + dumped
            #expect(!diagnostics.contains(nonce.environmentValue))
            #expect(!diagnostics.contains(secret))
            #expect(!diagnostics.contains(String(secret.dropLast())))
            #expect(Mirror(reflecting: value).children.isEmpty)
        }
    }

    private func testNonce() throws -> BridgeNonce {
        try BridgeNonce(bytes: Data(repeating: 0xab, count: BridgeNonce.byteCount))
    }

    private func readyHandshake() throws -> BridgeHandshake {
        let nonce = try testNonce()
        let handshake = BridgeHandshake(expectedNonce: nonce)
        try handshake.accept(.hello(nonce))
        try handshake.accept(.resize(BridgeSize(columns: 80, rows: 24)))
        return handshake
    }
}

@Suite struct BridgeSocketPathTests {
    @Test func pathUsesOnlySuppliedPrivateDirectoryAndStableSessionUUID() throws {
        let session = try #require(UUID(uuidString: "ABCDEF00-1234-5678-9012-34567890ABCD"))
        let path = try BridgeSocketPath(runtimeDirectory: "/r/kubix-ABC123", sessionID: session)
        #expect(path.value == "/r/kubix-ABC123/abcdef00-1234-5678-9012-34567890abcd.sock")
        #expect(try BridgeSocketPath(runtimeDirectory: "/r/kubix-ABC123", sessionID: session) == path)
        #expect(try BridgeSocketPath(runtimeDirectory: "/r/kubix-ABC123", sessionID: UUID()) != path)
        try BridgeSocketPath.validate(path.value)
    }

    @Test func exactASCIIByteLimitIncludesTheTerminatingNUL() throws {
        let directory = "/" + String(repeating: "a", count: 60)
        let path = try BridgeSocketPath(runtimeDirectory: directory, sessionID: UUID())
        #expect(path.value.utf8.count + 1 == BridgeSocketPath.darwinPathByteCapacity)
        #expect(path.value.hasPrefix(directory + "/"))
        #expect(path.value.hasSuffix(".sock"))
        #expect(throws: BridgeProtocolError.socketPathTooLong) {
            try BridgeSocketPath(runtimeDirectory: directory + "a", sessionID: UUID())
        }
        try BridgeSocketPath.validate("/" + String(repeating: "b", count: 102))
        #expect(throws: BridgeProtocolError.socketPathTooLong) {
            try BridgeSocketPath.validate("/" + String(repeating: "b", count: 103))
        }
    }

    @Test func multibytePathsUseUTF8BytesRatherThanCharactersAndNeverTruncate() throws {
        let directory = "/" + String(repeating: "é", count: 30)
        let path = try BridgeSocketPath(runtimeDirectory: directory, sessionID: UUID())
        #expect(path.value.utf8.count + 1 == 104)
        #expect(path.value.count + 1 < 104)
        #expect(path.value.hasPrefix(directory + "/"))
        for suffix in ["a", "é", "😀"] {
            #expect(throws: BridgeProtocolError.socketPathTooLong) {
                try BridgeSocketPath(runtimeDirectory: directory + suffix, sessionID: UUID())
            }
        }
        let emoji = try BridgeSocketPath(runtimeDirectory: "/" + String(repeating: "😀", count: 15), sessionID: UUID())
        #expect(emoji.value.utf8.count + 1 == 104)
        let decomposed = "/" + String(repeating: "e\u{301}", count: 20)
        let combining = try BridgeSocketPath(runtimeDirectory: decomposed, sessionID: UUID())
        #expect(combining.value.utf8.count + 1 == 104)
        #expect(combining.value.utf8.starts(with: decomposed.utf8))
    }

    @Test(arguments: ["", "/", "relative", "/r/", "//r", "/r//s", "/r/.", "/r/..", "/r/../s", "/r/./s", "/r\0s"])
    func invalidDirectoryAndPathSyntaxFailInsteadOfBeingNormalized(directory: String) {
        #expect(throws: BridgeProtocolError.invalidSocketPath) {
            try BridgeSocketPath(runtimeDirectory: directory, sessionID: UUID())
        }
        #expect(throws: BridgeProtocolError.invalidSocketPath) { try BridgeSocketPath.validate(directory) }
    }

    @Test func longHomeAndTemporaryDirectoryInputsAreNotShortenedOrReplaced() {
        for directory in [
            "/Users/" + String(repeating: "long-home", count: 30),
            "/private/var/folders/" + String(repeating: "deep-runtime/", count: 30) + "end",
        ] {
            #expect(throws: BridgeProtocolError.socketPathTooLong) {
                try BridgeSocketPath(runtimeDirectory: directory, sessionID: UUID())
            }
        }
    }
}
