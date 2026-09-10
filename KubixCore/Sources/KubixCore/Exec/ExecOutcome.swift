import Foundation

public enum ExecOutcome: Equatable, Sendable {
    case remoteExit(code: Int)
    /// A channel-3 failure after upgrade, not an HTTP error (there is no HTTP failure code).
    case remoteFailure(KubernetesStatus)
    case protocolFailure(RemoteCommandProtocolError)
    case transportFailure(TransportFailure)

    /// Pass channel-3 payload bytes, or nil for a closed connection that supplied no status.
    /// Empty/malformed channel-3 data is a protocol failure, never a successful exit.
    public init(statusData: Data?) {
        guard let statusData else {
            self = .transportFailure(.closed)
            return
        }
        guard let status = try? JSONDecoder().decode(KubernetesStatus.self, from: statusData),
              status.apiVersion == nil || status.apiVersion == "v1",
              status.kind == nil || status.kind == "Status" else {
            self = .protocolFailure(.malformedStatus)
            return
        }
        switch status.status {
        case "Success":
            self = .remoteExit(code: 0)
        case "Failure":
            guard status.reason == "NonZeroExitCode" else {
                self = .remoteFailure(status)
                return
            }
            let causes = status.details?.causes?.filter { $0.reason == "ExitCode" } ?? []
            // Kubernetes remotecommand v4/v5 uses an unsigned 8-bit, decimal exit code.
            guard causes.count == 1, let text = causes.first?.message, !text.isEmpty,
                  text.utf8.allSatisfy({ (48...57).contains($0) }),
                  let code = UInt8(text), code != 0 else {
                self = .protocolFailure(.malformedStatus)
                return
            }
            self = .remoteExit(code: Int(code))
        default:
            self = .protocolFailure(.malformedStatus)
        }
    }
}
