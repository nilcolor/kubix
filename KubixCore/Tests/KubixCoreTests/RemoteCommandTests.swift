import Foundation
import KubixCore
import Testing

@Suite struct RemoteCommandTests {
    @Test(arguments: [Data(), Data([0, 4, 255, 128, 10]), Data("hello\r\n世界".utf8)])
    func binaryChannelsRoundTrip(payload: Data) throws {
        let frames: [RemoteCommandFrame] = [.stdin(payload), .stdout(payload), .stderr(payload), .error(payload)]
        for (channel, frame) in frames.enumerated() {
            let wire = try frame.encoded()
            #expect(wire == Data([UInt8(channel)]) + payload)
            #expect(try RemoteCommandFrame(data: wire) == frame)
            // Data slices need not start at index zero.
            #expect(try RemoteCommandFrame(data: (Data([99]) + wire).dropFirst()) == frame)
        }
    }

    @Test func emptyFrameAndEveryUnknownChannelAreRejected() {
        #expect(throws: RemoteCommandProtocolError.emptyFrame) { try RemoteCommandFrame(data: Data()) }
        for channel in UInt8(5)...254 {
            #expect(throws: RemoteCommandProtocolError.unknownChannel(channel)) {
                try RemoteCommandFrame(data: Data([channel, 0]))
            }
        }
    }

    @Test(arguments: RemoteCommandFrame.Channel.allCases)
    func closeIsExactlyTwoBytes(channel: RemoteCommandFrame.Channel) throws {
        let frame = RemoteCommandFrame.close(channel)
        let wire = try frame.encoded()
        #expect(wire == Data([255, channel.rawValue]))
        #expect(try RemoteCommandFrame(data: wire) == frame)
        #expect(try RemoteCommandFrame(data: (Data([99]) + wire).dropFirst()) == frame)
    }

    @Test func closeRejectsMissingExtraAndInvalidChannelBytes() {
        for wire in [Data([255]), Data([255, 0, 0]), Data([255, 0, 255, 1])] {
            #expect(throws: RemoteCommandProtocolError.invalidClose) { try RemoteCommandFrame(data: wire) }
        }
        for channel in UInt8(5)...255 {
            #expect(throws: RemoteCommandProtocolError.invalidClose) {
                try RemoteCommandFrame(data: Data([255, channel]))
            }
        }
    }

    @Test func inputHalfCloseIsNotControlDOrEmptyInput() throws {
        #expect(try RemoteCommandFrame.stdin(Data([4])).encoded() == Data([0, 4]))
        #expect(try RemoteCommandFrame.stdin(Data()).encoded() == Data([0]))
        #expect(try RemoteCommandFrame.close(.stdin).encoded() == Data([255, 0]))
        #expect(try RemoteCommandFrame(data: Data([255, 0])) != .stdin(Data([4])))
        // Framing does not treat stdin close as whole-session EOF.
        #expect(try RemoteCommandFrame(data: Data([1, 65])) == .stdout(Data([65])))
    }

    @Test(arguments: [
        RemoteCommandSize(columns: 120, rows: 40), RemoteCommandSize(columns: 1, rows: 1),
        RemoteCommandSize(columns: 0, rows: 0), RemoteCommandSize(columns: .max, rows: .max),
    ])
    func resizeWireUsesKubernetesDimensionNames(size: RemoteCommandSize) throws {
        let frame = RemoteCommandFrame.resize(size)
        let wire = try frame.encoded()
        #expect(wire.first == 4)
        let json = try JSONDecoder().decode([String: UInt16].self, from: wire.dropFirst())
        #expect(json == ["Width": size.columns, "Height": size.rows])
        #expect(try RemoteCommandFrame(data: wire) == frame)
    }

    @Test func resizeAcceptsJSONWhitespaceAndReorderedKeys() throws {
        let wire = Data([4]) + Data(" { \"Height\": 24, \"Width\": 80 }\n".utf8)
        #expect(try RemoteCommandFrame(data: wire) == .resize(RemoteCommandSize(columns: 80, rows: 24)))
    }

    @Test(arguments: [
        "", "{}", "null", "[]", "text", #"{"Width":80}"#, #"{"Height":24}"#,
        #"{"width":80,"height":24}"#, #"{"Width":"80","Height":24}"#,
        #"{"Width":true,"Height":24}"#, #"{"Width":null,"Height":24}"#,
        #"{"Width":-1,"Height":24}"#, #"{"Width":80,"Height":65536}"#,
        #"{"Width":80.5,"Height":24}"#, #"{"Width":80,"Height":24}{}"#,
    ])
    func malformedResizeIsProtocolError(payload: String) {
        #expect(throws: RemoteCommandProtocolError.invalidResize) {
            try RemoteCommandFrame(data: Data([4]) + Data(payload.utf8))
        }
    }

    @Test func malformedBinaryJSONIsNotReplacedWithText() {
        let payload = Data([255, 254, 0])
        #expect(throws: RemoteCommandProtocolError.invalidResize) {
            try RemoteCommandFrame(data: Data([4]) + payload)
        }
        #expect(ExecOutcome(statusData: payload) == .protocolFailure(.malformedStatus))
    }

    @Test func execUsesExistingBuilderAndPreservesRepeatedCommandArguments() throws {
        let command = ["sh", "-c", "printf '%s' 'é +&=%/?#'", ""]
        let request = try ExecRequest(namespace: "a/b", pod: "p ?#%", container: "side&car+", command: command)
        let base = try #require(URL(string: "https://synthetic.invalid/gateway/a%20b/"))
        let outgoing = try request.urlRequest(baseURL: base)
        let url = try #require(outgoing.url)
        #expect(outgoing.httpMethod == "GET")
        #expect(outgoing == (try request.apiRequest.urlRequest(baseURL: base, purpose: .webSocket)))
        #expect(url.absoluteString.hasPrefix("wss://synthetic.invalid/gateway/a%20b/api/v1/namespaces/a%2Fb/pods/p%20%3F%23%25/exec?"))
        #expect(url.absoluteString.contains("container=side%26car%2B"))
        #expect(url.absoluteString.contains("%C3%A9%20%2B%26%3D%25%2F%3F%23"))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.filter { $0.name == "command" }.map(\.value) == command)
        #expect(query.filter { $0.name == "container" }.map(\.value) == ["side&car+"])
        #expect(query.filter { $0.name == "stdin" }.map(\.value) == ["true"])
        #expect(query.filter { $0.name == "stdout" }.map(\.value) == ["true"])
        #expect(query.filter { $0.name == "stderr" }.map(\.value) == ["false"])
        #expect(query.filter { $0.name == "tty" }.map(\.value) == ["true"])
        #expect(query.count == command.count + 5)
        #expect(request.tty && !request.stderr)
        #expect(outgoing.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(outgoing.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(outgoing.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == nil)
        #expect(!request.description.contains("printf"))
        let plainBase = try #require(URL(string: "http://synthetic.invalid/prefix"))
        #expect(try request.urlRequest(baseURL: plainBase).url?.scheme == "ws")
    }

    @Test func ttyAndStderrInvariantIsEnforcedForEveryCombination() throws {
        for tty in [true, false] {
            for stderr in [nil, false, true] as [Bool?] {
                if tty && stderr == true {
                    #expect(throws: APIError.invalidRequest) {
                        try ExecRequest(namespace: "n", pod: "p", container: "c", command: ["sh"], tty: tty, stderr: stderr)
                    }
                } else {
                    let request = try ExecRequest(namespace: "n", pod: "p", container: "c", command: ["sh"], tty: tty, stderr: stderr)
                    #expect(request.stderr == (stderr ?? !tty))
                    #expect(!request.tty || !request.stderr)
                    #expect(request.apiRequest.query.contains(URLQueryItem(name: "stderr", value: String(request.stderr))))
                }
            }
        }
        let request = try ExecRequest(
            namespace: "n", pod: "p", container: "c", command: ["sh"],
            stdin: false, stdout: false, tty: false, stderr: true
        )
        #expect(request.apiRequest.query.contains(URLQueryItem(name: "stdin", value: "false")))
        #expect(request.apiRequest.query.contains(URLQueryItem(name: "stdout", value: "false")))
        #expect(throws: APIError.invalidRequest) {
            try ExecRequest(namespace: "n", pod: "p", container: "c", command: ["sh"], stdin: false, stdout: false, tty: false, stderr: false)
        }
    }

    @Test func invalidExecTargetsAndCommandsAreRejected() {
        for value in ["", ".", "..", "bad\0name"] {
            #expect(throws: APIError.invalidRequest) {
                try ExecRequest(namespace: value, pod: "p", container: "c", command: ["sh"])
            }
            #expect(throws: APIError.invalidRequest) {
                try ExecRequest(namespace: "n", pod: value, container: "c", command: ["sh"])
            }
            #expect(throws: APIError.invalidRequest) {
                try ExecRequest(namespace: "n", pod: "p", container: value, command: ["sh"])
            }
        }
        for command in [[], [""], ["sh", "bad\0argument"]] {
            #expect(throws: APIError.invalidRequest) {
                try ExecRequest(namespace: "n", pod: "p", container: "c", command: command)
            }
        }
    }

    @Test func serverFixturesDecodeSuccessAndNonzeroExitsWithoutTypeMeta() throws {
        #expect(ExecOutcome(statusData: try fixture("status-exec-success")) == .remoteExit(code: 0))
        let wire = try RemoteCommandFrame.error(fixture("status-exitcode")).encoded()
        guard case .error(let payload) = try RemoteCommandFrame(data: wire) else {
            Issue.record("Expected channel 3")
            return
        }
        #expect(ExecOutcome(statusData: payload) == .remoteExit(code: 42))
        let decoded = try JSONDecoder().decode(KubernetesStatus.self, from: payload)
        #expect(decoded.apiVersion == nil && decoded.kind == nil && decoded.code == nil)
        #expect(decoded.details?.causes?.first?.reason == "ExitCode")
        #expect(try JSONDecoder().decode(KubernetesStatus.self, from: JSONEncoder().encode(decoded)) == decoded)
    }

    @Test(arguments: ["1", "126", "137", "255", "042"])
    func validNonzeroExitCodes(code: String) throws {
        #expect(ExecOutcome(statusData: try exitStatus(code)) == .remoteExit(code: Int(code)!))
    }

    @Test(arguments: ["", "0", "000", "-1", "+1", "256", "9999999999999999999999", "1.5", "1e2", " 1", "1\n", "one", "١"])
    func invalidExitCodesAreProtocolFailures(code: String) throws {
        #expect(ExecOutcome(statusData: try exitStatus(code)) == .protocolFailure(.malformedStatus))
    }

    @Test(arguments: [
        "", "null", "[]", "{}", "<html>failure</html>", #"{"status":true}"#,
        #"{"status":"Unknown"}"#, #"{"status":"success"}"#, #"{"status":null}"#,
        #"{"reason":"NonZeroExitCode","details":{"causes":[{"reason":"ExitCode","message":"1"}]}}"#,
        #"{"status":"Success","apiVersion":"v2"}"#, #"{"status":"Success","kind":"Pod"}"#,
        #"{"status":"Success","code":"0"}"#, #"{"status":"Success","details":[]}"#,
        #"{"status":"Failure","reason":42}"#, #"{"status":"Failure","message":false}"#,
        #"{"status":"Failure","reason":"NonZeroExitCode"}"#,
        #"{"status":"Failure","reason":"NonZeroExitCode","details":{"causes":[]}}"#,
        #"{"status":"Failure","reason":"NonZeroExitCode","details":{"causes":[{"reason":"Other","message":"42"}]}}"#,
        #"{"status":"Failure","reason":"NonZeroExitCode","details":{"causes":[{"reason":"ExitCode"}]}}"#,
        #"{"status":"Failure","reason":"NonZeroExitCode","details":{"causes":[{"reason":"ExitCode","message":42}]}}"#,
        #"{"status":"Failure","reason":"NonZeroExitCode","details":{"causes":[{"reason":"ExitCode","message":"1"},{"reason":"ExitCode","message":"2"}]}}"#,
        #"{"status":"Success"}{"status":"Failure"}"#,
    ])
    func malformedStatusesAreNotRemoteExits(payload: String) {
        #expect(ExecOutcome(statusData: Data(payload.utf8)) == .protocolFailure(.malformedStatus))
    }

    @Test func statusDiscriminatorAndExitCauseAreAuthoritativeNotHTTPCode() throws {
        let success = Data(#"{"apiVersion":"v1","kind":"Status","status":"Success","code":200}"#.utf8)
        #expect(ExecOutcome(statusData: success) == .remoteExit(code: 0))
        let nonzero = Data("""
        {"status":"Failure","reason":"NonZeroExitCode","code":500,
         "details":{"causes":[{"reason":"Other","message":"not a code"},{"reason":"ExitCode","message":"2","field":"command"}]}}
        """.utf8)
        #expect(ExecOutcome(statusData: nonzero) == .remoteExit(code: 2))
        let otherFailure = Data("""
        {"status":"Failure","reason":"InternalError","message":"original reason",
         "details":{"causes":[{"reason":"ExitCode","message":"2"}]}}
        """.utf8)
        let decoded = try JSONDecoder().decode(KubernetesStatus.self, from: otherFailure)
        #expect(ExecOutcome(statusData: otherFailure) == .remoteFailure(decoded))
        let minimalFailure = Data(#"{"status":"Failure"}"#.utf8)
        #expect(ExecOutcome(statusData: minimalFailure) == .remoteFailure(try JSONDecoder().decode(KubernetesStatus.self, from: minimalFailure)))
    }

    @Test(arguments: [("status-exec-failure", "InternalError", 500), ("status-exec-forbidden", "Forbidden", 403)])
    func postUpgradeFailuresPreserveOriginalStatus(name: String, reason: String, code: Int) throws {
        let data = try fixture(name)
        let status = try JSONDecoder().decode(KubernetesStatus.self, from: data)
        guard case .remoteFailure(let failure) = ExecOutcome(statusData: data) else {
            Issue.record("Expected a remote API/execution failure, not a remote exit or transport failure")
            return
        }
        #expect(failure == status)
        #expect(failure.reason == reason)
        #expect(failure.code == code)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(failure.message == (json["message"] as? String))
        #expect(failure.details != nil)
        #expect(ExecOutcome.remoteFailure(failure) != .protocolFailure(.malformedStatus))
        #expect(ExecOutcome.remoteFailure(failure) != .transportFailure(.closed))
        #expect(ExecOutcome.remoteFailure(failure) != .remoteExit(code: code))
    }

    @Test func missingStatusAndTransportFailuresNeverInventAnExit() {
        #expect(ExecOutcome(statusData: nil) == .transportFailure(.closed))
        #expect(ExecOutcome(statusData: Data()) == .protocolFailure(.malformedStatus))
        for failure in [TransportFailure.closed, .connection, .timedOut, .pongTimedOut, .nonBinaryMessage] {
            #expect(ExecOutcome.transportFailure(failure) != .remoteExit(code: 0))
            #expect(ExecOutcome.transportFailure(failure) != .protocolFailure(.malformedStatus))
        }
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func exitStatus(_ code: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "status": "Failure", "reason": "NonZeroExitCode",
            "details": ["causes": [["reason": "ExitCode", "message": code]]],
        ])
    }
}
