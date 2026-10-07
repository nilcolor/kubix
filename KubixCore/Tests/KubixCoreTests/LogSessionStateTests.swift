import Foundation
@testable import KubixCore
import Testing

@MainActor private func session(_ states: [LogSource.State], resolved: Int? = nil) throws -> LogSession {
    let context = try appContext()
    let container = PodDetails.Container(name: "server", kind: .regular, state: .declared)
    let sources = try states.enumerated().map { index, state in
        LogSource(
            target: try LogTarget(
                context: context, namespace: "team", pod: "pod-\(index)", uid: "uid-\(index)", container: container
            ),
            state: state
        )
    }
    return LogSession(
        scope: LogScope(
            context: context, namespace: "team",
            subject: .deployment(name: "web", uid: "deploy-uid"), container: container
        ),
        containers: [container], sources: sources, resolved: resolved
    )
}

/// What a tab says it is doing when it holds several streams. Every branch matters: a tab claiming to
/// follow while nothing is delivering, or reporting a failure while four pods are still streaming,
/// would be describing something that did not happen.
@Suite @MainActor struct LogSessionStateTests {
    @Test func oneDeliveringStreamIsEnoughToBeFollowing() throws {
        #expect(try session([.following]).state == .following)
        #expect(try session([.failed(.notReady), .following, .connecting]).state == .following)
        #expect(try session([.ended, .following]).state == .following)
    }

    @Test func connectingOnlyWhileSomethingStillMightOpen() throws {
        #expect(try session([.connecting]).state == .connecting)
        #expect(try session([.failed(.notReady), .connecting]).state == .connecting)
        #expect(try session([.ended, .connecting]).state == .connecting)
    }

    /// The distinction the architecture turns on: a stream that never opened failed, one that opened
    /// and stopped was interrupted. With several streams the worse news wins, so a tab never reports
    /// a clean end while one of its pods died mid-stream.
    @Test func terminalSourcesReportInterruptionAheadOfFailureAndCleanEndings() throws {
        #expect(try session([.ended, .ended]).state == .completed)
        #expect(try session([.ended, .failed(.notReady)]).state == .failed(.notReady))
        #expect(try session([.failed(.notReady), .interrupted(.transport)]).state == .interrupted(.transport))
        #expect(try session([.ended, .interrupted(.deadline)]).state == .interrupted(.deadline))
    }

    /// Pause is the user's, and a cancelled stream looks like several other endings from outside, so
    /// it is recorded rather than inferred.
    @Test func pauseOutranksWhateverTheStreamsWereDoing() throws {
        let paused = try session([.following, .connecting])
        paused.isPaused = true
        #expect(paused.state == .paused)
        #expect(paused.status == "Paused. Retained lines are preserved.")
    }

    @Test func aDeploymentWithNoPodsSaysSoRatherThanLookingDeleted() throws {
        let empty = try session([])
        #expect(empty.state == .failed(.noPods))
        #expect(empty.status == "This deployment has no pods to tail. Resume once it has some.")
    }

    @Test func theStatusCountsWhatIsFollowingAndWhatWasLeftOut() throws {
        let partial = try session([.following, .following, .failed(.notReady)])
        #expect(partial.followingCount == 2)
        #expect(partial.status.hasPrefix("Following 2 of 3 pods. "))
        #expect(partial.status.contains("fixed until Resume"))
        let capped = try session([.following, .following], resolved: 180)
        #expect(capped.status.hasPrefix("Following 2 of 2 pods of 180 found."))
        // One pod has nothing to count, so it reads as it always did.
        let single = try session([.following])
        #expect(single.status == "Following — 24h idle / 7d resource limit.")
    }

    /// A label on every line of a single-pod tab would be noise: there is nothing to tell apart.
    @Test func linesAreLabelledOnlyWhenThereIsMoreThanOneStream() throws {
        #expect(try !session([.following]).labelsLines)
        #expect(try session([.following, .following]).labelsLines)
    }

    /// 200 lines each across forty pods would evict the whole ring before any of it was read.
    @Test func theInitialTailShrinksAsTheFanOutGrows() {
        #expect(AppActions.tailLines(for: 1) == 200)
        #expect(AppActions.tailLines(for: 5) == 200)
        #expect(AppActions.tailLines(for: 10) == 100)
        #expect(AppActions.tailLines(for: 50) == 20)
        // The floor holds even if the ceiling ever rises.
        #expect(AppActions.tailLines(for: 1_000) == 20)
    }

    @Test func theDeckReadsADeploymentTabByItsSubjectRatherThanAPodName() throws {
        #expect(LogSubject.pod(name: "web-abc", uid: "u").display == "web-abc")
        #expect(LogSubject.deployment(name: "web", uid: "u").display == "deploy/web")
        #expect(LogSubject.deployment(name: "web", uid: "u").kind == .deployments)
        #expect(LogSubject.pod(name: "web", uid: "u").kind == .pods)
    }
}
