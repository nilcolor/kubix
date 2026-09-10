#if DEBUG
import Foundation
import KubixCore

/// Installed before auto-discovery; rejected scope never reaches authentication or networking.
struct ExecLiveScopedTransport: Transport {
    let underlying: any Transport

    func data(for request: APIRequest) async throws -> Data {
        try validate(request, subresource: nil)
        return try await underlying.data(for: request)
    }

    func stream(for request: APIRequest, purpose: TransportPurpose) async throws -> any HTTPByteStream {
        if purpose == .watch {
            try validate(request, subresource: nil)
            guard request.path.count == 5, request.accept == APIRequest.tableAccept else { throw APIError.invalidRequest }
            return try await underlying.stream(for: request, purpose: purpose)
        }
        try validate(request, subresource: "log")
        guard purpose == .logs, request.query.contains(where: {
            $0.name == "container" && $0.value == ExecLiveDiscovery.container
        }) else { throw APIError.invalidRequest }
        // Only new bytes; never collect or persist the ordinary viewer's historical 200-line tail.
        var query = request.query.filter { $0.name != "tailLines" }
        query.append(.init(name: "tailLines", value: "0"))
        return try await underlying.stream(for: APIRequest(
            resource: "pods", namespace: ExecLiveDiscovery.namespace, name: request.path[5], subresource: "log", query: query
        ), purpose: purpose)
    }

    func webSocket(for request: APIRequest) async throws -> any WebSocketConnection {
        try validate(request, subresource: "exec")
        guard request.query.contains(where: { $0.name == "container" && $0.value == ExecLiveDiscovery.container }) else {
            throw APIError.invalidRequest
        }
        return try await underlying.webSocket(for: request)
    }

    func invalidateCredentials(after error: APIError) async throws { try await underlying.invalidateCredentials(after: error) }

    private func validate(_ request: APIRequest, subresource: String?) throws {
        guard request.path.prefix(5) == ["api", "v1", "namespaces", ExecLiveDiscovery.namespace, "pods"] else {
            throw APIError.invalidRequest
        }
        if request.path.count == 5 {
            guard subresource == nil, request.accept == APIRequest.tableAccept else { throw APIError.invalidRequest }
        } else {
            guard request.path.count == (subresource == nil ? 6 : 7),
                  request.path[5].hasPrefix(ExecLiveDiscovery.prefix),
                  subresource == nil || request.path.last == subresource else { throw APIError.invalidRequest }
        }
    }
}

extension ExecLiveScopedTransport {
    static func validateNativeScope() async throws -> String {
        let peer = ExecScopeFixture()
        let transport = Self(underlying: peer)
        let name = ExecLiveDiscovery.prefix + "synthetic"
        for request in [
            APIRequest(resource: "namespaces"),
            APIRequest(resource: "pods", namespace: "default", table: true),
            APIRequest(resource: "pods", namespace: ExecLiveDiscovery.namespace, name: "unapproved"),
            APIRequest(resource: "pods", namespace: ExecLiveDiscovery.namespace),
        ] {
            do { _ = try await transport.data(for: request); throw ScopeFailure.assertion } catch APIError.invalidRequest {}
        }
        let wrongContainer = APIRequest(
            resource: "pods", namespace: ExecLiveDiscovery.namespace, name: name, subresource: "exec",
            query: [.init(name: "container", value: "setup")]
        )
        do { _ = try await transport.webSocket(for: wrongContainer); throw ScopeFailure.assertion } catch APIError.invalidRequest {}
        guard await peer.requests.isEmpty else { throw ScopeFailure.assertion }
        _ = try await transport.data(for: APIRequest(resource: "pods", namespace: ExecLiveDiscovery.namespace, table: true))
        _ = try await transport.data(for: APIRequest(resource: "pods", namespace: ExecLiveDiscovery.namespace, name: name))
        let log = try await transport.stream(for: APIRequest(
            resource: "pods", namespace: ExecLiveDiscovery.namespace, name: name, subresource: "log",
            query: [.init(name: "container", value: ExecLiveDiscovery.container), .init(name: "tailLines", value: "200")]
        ), purpose: .logs)
        log.cancel()
        guard await peer.requests.count == 3,
              await peer.requests.last?.query.filter({ $0.name == "tailLines" }).map(\.value) == ["0"] else {
            throw ScopeFailure.assertion
        }
        return "CONTROLLED negative scope preflight: five rejected before underlying IO; approved Table/details/log forwarded; tailLines forced0"
    }

    private enum ScopeFailure: Error { case assertion }
}

private actor ExecScopeFixture: Transport {
    private(set) var requests: [APIRequest] = []
    func data(for request: APIRequest) -> Data { requests.append(request); return Data() }
    func stream(for request: APIRequest, purpose: TransportPurpose) -> any HTTPByteStream {
        requests.append(request)
        return PodFixtureStream()
    }
    func webSocket(for request: APIRequest) throws -> any WebSocketConnection {
        requests.append(request)
        throw APIError.invalidRequest
    }
}
#endif
