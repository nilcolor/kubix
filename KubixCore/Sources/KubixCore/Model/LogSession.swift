import Foundation
import Observation

@Observable @MainActor
public final class LogSession: Identifiable {
    public enum State: Equatable, Sendable {
        case connecting, following, paused, completed
        case interrupted(LogFailure), failed(LogFailure)
    }

    public let id = UUID()
    public let target: LogTarget
    public internal(set) var containers: [PodDetails.Container]
    public internal(set) var buffer = LogBuffer()
    public internal(set) var state: State = .connecting
    public internal(set) var segment = 0
    public internal(set) var filter = ""
    public internal(set) var autoscroll = true
    public internal(set) var isClosed = false
    public static let replayNotice = "Resume starts a fresh tail, not lossless replay. Lines may be missing or duplicated."

    public init(target: LogTarget, containers: [PodDetails.Container]) {
        self.target = target
        self.containers = containers
    }

    func beginSegment() {
        segment += 1
        buffer.append(DecodedLogLine(text: "— Tail segment \(segment) — " + Self.replayNotice), boundary: true)
        state = .connecting
    }

    public var status: String {
        switch state {
        case .connecting: "Validating / connecting…"
        case .following: "Following — 24h idle / 7d resource limit."
        case .paused: "Paused. Retained lines are preserved."
        case .completed: "Stream ended cleanly (EOF). Resume starts a new tail."
        case .interrupted(let failure), .failed(let failure): failure.diagnostic
        }
    }
}
