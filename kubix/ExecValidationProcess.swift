#if DEBUG
import Foundation
import KubixCore
import KubixRuntime

/// Counts the real credential runner without retaining its request, output or environment.
actor ExecValidationProcess: ProcessRunning {
    private let launches = ExecValidationLaunches()
    private(set) var calls = 0
    private(set) var kubectlDiscoverable = false
    var launchedPIDs: [Int32] { launches.values }

    func run(_ request: ProcessRequest, progress: @escaping @Sendable (String) -> Void) async throws -> ProcessResult {
        calls += 1
        kubectlDiscoverable = kubectlDiscoverable || (request.environment["PATH"] ?? "").split(separator: ":").contains {
            FileManager.default.isExecutableFile(atPath: String($0) + "/kubectl")
        }
        if ProcessInfo.processInfo.environment["KUBIX_EXEC_VALIDATION_CONFIRM"] == "authorized-readonly-task20", kubectlDiscoverable {
            throw APIError.invalidRequest
        }
        return try await ProcessRunner(validationDidLaunch: { [launches] in launches.append($0) }).run(request, progress: progress)
    }
}

private final class ExecValidationLaunches: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: [Int32] = []
    var values: [Int32] { lock.withLock { pids } }
    func append(_ pid: Int32) { lock.withLock { pids.append(pid) } }
}

final class ExecValidationTransportFactory: TransportSessionFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var policies: [ClusterTrustPolicy] = []
    var trustErrorCodes: [Int] { lock.withLock { policies.compactMap(\.validationErrorCode) } }
    var anchorCount: Int { lock.withLock { policies.first?.anchors.count ?? 0 } }
    var trustDiagnostics: [String: Int] { lock.withLock { policies.first?.validationDiagnostics ?? [:] } }

    func make(purpose: TransportPurpose, trust: ClusterTrustPolicy) -> any TransportSession {
        lock.withLock { policies.append(trust) }
        return URLSessionFactory().make(purpose: purpose, trust: trust)
    }
}
#endif
