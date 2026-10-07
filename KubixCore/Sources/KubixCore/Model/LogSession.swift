import Foundation
import Observation

/// One tab of logs. A pod's tab holds one source, a deployment's holds one per pod, and everything
/// else — the buffer and its bounds, the filter, the segment boundary, closing — is the same either
/// way, which is why there is one type rather than two.
@Observable @MainActor
public final class LogSession: Identifiable {
    public enum State: Equatable, Sendable {
        case connecting, following, paused, completed
        case interrupted(LogFailure), failed(LogFailure)
    }

    public let id = UUID()
    public let scope: LogScope
    public internal(set) var sources: [LogSource]
    public internal(set) var containers: [PodDetails.Container]
    /// How many pods the deployment resolved to, when that is more than the tab could tail. nil
    /// whenever everything found is being followed, which is every pod session.
    public internal(set) var resolved: Int?
    public internal(set) var buffer: LogBuffer
    public internal(set) var segment = 0
    public internal(set) var filter = ""
    public internal(set) var autoscroll = true
    public internal(set) var isClosed = false
    /// Set by Pause alone. A paused tab's sources are cancelled, which is indistinguishable from
    /// several other endings from the outside, so the one the user caused is recorded rather than
    /// inferred.
    public internal(set) var isPaused = false
    public static let replayNotice = "Resume starts a fresh tail, not lossless replay. Lines may be missing or duplicated."
    /// How many pods one tab tails at once. See `TransportPolicy.maximumConcurrentLogStreams`.
    nonisolated public static let maximumSources = TransportPolicy.maximumConcurrentLogStreams

    public init(scope: LogScope, containers: [PodDetails.Container], sources: [LogSource], resolved: Int? = nil) {
        self.scope = scope
        self.containers = containers
        self.sources = sources
        self.resolved = resolved
        buffer = LogBuffer(sources: sources.count)
    }

    /// Derived, never assigned: with several streams the tab must not claim to be following when
    /// nothing is, nor report a failure while another pod is still delivering.
    public var state: State {
        if isPaused { return .paused }
        guard !sources.isEmpty else { return .failed(.noPods) }
        if sources.contains(where: { $0.state == .following }) { return .following }
        if sources.contains(where: { $0.state == .connecting }) { return .connecting }
        for source in sources {
            if case .interrupted(let failure) = source.state { return .interrupted(failure) }
        }
        for source in sources {
            if case .failed(let failure) = source.state { return .failed(failure) }
        }
        return .completed
    }

    public var followingCount: Int { sources.filter { $0.state == .following }.count }

    /// A line is labelled with its pod only when there is more than one to tell apart.
    public var labelsLines: Bool { sources.count > 1 }

    func beginSegment() {
        segment += 1
        buffer.append(DecodedLogLine(text: "— Tail segment \(segment) — " + Self.replayNotice), boundary: true)
    }

    /// Installs a resolved set of streams. The ring is widened to match, because a tab created
    /// before its pods were known was sized for none of them.
    func install(sources: [LogSource], resolved: Int?) {
        self.sources = sources
        self.resolved = resolved
        buffer.grow(for: sources.count)
    }

    func update(_ id: UUID, state: LogSource.State) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].state = state
    }

    public var status: String {
        switch state {
        case .connecting: "Validating / connecting…"
        case .following: following
        case .paused: "Paused. Retained lines are preserved."
        case .completed: "Stream ended cleanly (EOF). Resume starts a new tail."
        case .interrupted(let failure), .failed(let failure): failure.diagnostic
        }
    }

    private var following: String {
        guard sources.count > 1 else { return "Following — 24h idle / 7d resource limit." }
        let capped = resolved.map { " of \($0) found" } ?? ""
        return "Following \(followingCount) of \(sources.count) pods\(capped). "
            + "The set is fixed until Resume, so pods started since will not appear."
    }
}
