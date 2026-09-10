import CryptoKit
import Darwin
import Foundation
@testable import KubixRuntime

/// A single synthetic exchange on 127.0.0.1. Never listens on external interfaces or uses DNS.
/// Blocking test IO runs on a GCD worker with bounded poll/read/write timeouts, not a Swift actor.
final class LoopbackTransportServer: @unchecked Sendable {
    enum Reply: Sendable {
        case http(Int, String, retryAfter: String? = nil)
        case websocket
        case quiet
    }
    enum Failure: Error { case socket, request, frame }

    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var peer: Int32 = -1
    private var stopped = false
    private var captured = ""
    private var binary: Data?
    private var pingReceived = false
    private var framePrefixes: [[UInt8]] = []
    private let completion = TransportPromise<Void>()
    var request: String { lock.withLock { captured } }
    var receivedBinary: Data? { lock.withLock { binary } }
    var receivedPing: Bool { lock.withLock { pingReceived } }
    var frames: [[UInt8]] { lock.withLock { framePrefixes } }

    init(reply: Reply) throws {
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Failure.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(listener, 1) == 0 else { Darwin.close(listener); throw Failure.socket }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(listener, $0, &size) }
        }
        guard named == 0 else { Darwin.close(listener); throw Failure.socket }
        self.listener = listener
        port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global().async {
            do { try self.serve(reply); self.completion.finish(.success(())) } catch {
                self.completion.finish(.failure(error))
            }
        }
    }

    func wait() async throws { try await completion.value(cancel: stop) }

    func stop() {
        lock.withLock {
            stopped = true
            Darwin.shutdown(listener, SHUT_RDWR)
            if peer >= 0 { Darwin.shutdown(peer, SHUT_RDWR) }
        }
    }

    private func serve(_ reply: Reply) throws {
        var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&ready, 1, 5_000) > 0 else { throw Failure.socket }
        let socket = Darwin.accept(listener, nil, nil)
        guard socket >= 0 else { throw Failure.socket }
        lock.withLock { peer = socket; if stopped { Darwin.shutdown(socket, SHUT_RDWR) } }
        defer {
            lock.withLock { peer = -1 }
            Darwin.close(socket)
        }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        var enabled: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var header = Data()
        while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard header.count < 16_384 else { throw Failure.request }
            header.append(try read(socket, count: 1))
        }
        let text = String(decoding: header, as: UTF8.self)
        lock.withLock { captured = text }
        switch reply {
        case .http(let code, let body, let retryAfter):
            let retry = retryAfter.map { "Retry-After: \($0)\r\n" } ?? ""
            try write(socket, Data("HTTP/1.1 \(code) Synthetic\r\nContent-Length: \(body.utf8.count)\r\n\(retry)Connection: close\r\n\r\n\(body)".utf8))
        case .websocket: try upgrade(socket, request: text)
        case .quiet:
            // Caller cancellation closes the TCP connection. The socket timeout bounds failures.
            var byte: UInt8 = 0
            _ = Darwin.recv(socket, &byte, 1, 0)
        }
    }

    private func upgrade(_ socket: Int32, request: String) throws {
        let key = request.components(separatedBy: "\r\n").first {
            $0.lowercased().hasPrefix("sec-websocket-key:")
        }?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
        guard let key else { throw Failure.request }
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let accept = Data(digest).base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\nSec-WebSocket-Protocol: v5.channel.k8s.io\r\n\r\n"
        try write(socket, Data(response.utf8) + Data([0x82, 3, 1, 65, 66]))
        while true {
            let prefix = [UInt8](try read(socket, count: 2))
            lock.withLock { framePrefixes.append(prefix) }
            let length = Int(prefix[1] & 0x7f)
            guard length < 126, prefix[1] & 0x80 != 0 else { throw Failure.frame }
            let mask = [UInt8](try read(socket, count: 4))
            let payload = Data(try read(socket, count: length).enumerated().map { $0.element ^ mask[$0.offset % 4] })
            switch prefix[0] & 0x0f {
            case 2: lock.withLock { binary = payload }
            case 9:
                lock.withLock { pingReceived = true }
                try write(socket, Data([0x8a, UInt8(length)]) + payload)
            case 8: return
            default: throw Failure.frame
            }
            if lock.withLock({ binary != nil && pingReceived }) {
                // Wait for cancellation/close so a sent pong can be consumed before TCP EOF.
                var byte: UInt8 = 0
                _ = Darwin.recv(socket, &byte, 1, 0)
                return
            }
        }
    }

    private func read(_ socket: Int32, count: Int) throws -> Data {
        var bytes = Data(count: count)
        var offset = 0
        while offset < count {
            let received = bytes.withUnsafeMutableBytes {
                Darwin.recv(socket, $0.baseAddress?.advanced(by: offset), count - offset, 0)
            }
            guard received > 0 else { throw Failure.socket }
            offset += received
        }
        return bytes
    }

    private func write(_ socket: Int32, _ bytes: Data) throws {
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { Darwin.send(socket, $0.baseAddress?.advanced(by: offset), bytes.count - offset, 0) }
            guard sent > 0 else { throw Failure.socket }
            offset += sent
        }
    }

    deinit { Darwin.close(listener) }
}
