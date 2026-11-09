import Foundation
import KubixCore
import Testing

private func objects(_ json: String) throws -> [WorkloadObject] {
    try JSONDecoder().decode([WorkloadObject].self, from: Data(json.utf8))
}

@Suite struct ClusterOverviewClassifierTests {
    @Test func deploymentsAreReadyPendingOrPastTheirProgressDeadline() throws {
        let items = try objects("""
        [{"spec":{"replicas":3},"status":{"readyReplicas":3}},
         {"spec":{"replicas":0},"status":{}},
         {"spec":{"replicas":3},"status":{"readyReplicas":1,
           "conditions":[{"type":"Progressing","status":"True","reason":"ReplicaSetUpdated"}]}},
         {"spec":{"replicas":2},"status":{"readyReplicas":1,
           "conditions":[{"type":"Progressing","status":"False","reason":"ProgressDeadlineExceeded"}]}},
         {"status":{}}]
        """)
        // A scaled-to-zero deployment has everything it asked for; one without spec.replicas wants one.
        #expect(WorkloadCounts.tally(.deployments, items) == WorkloadCounts(total: 5, running: 2, pending: 2, failed: 1))
    }

    @Test func statefulSetsAndDaemonSetsHaveNoFailureColumn() throws {
        let sets = try objects("""
        [{"spec":{"replicas":2},"status":{"readyReplicas":2}},{"spec":{"replicas":2},"status":{"readyReplicas":1}}]
        """)
        #expect(WorkloadCounts.tally(.statefulSets, sets) == WorkloadCounts(total: 2, running: 1, pending: 1))
        let daemons = try objects("""
        [{"status":{"desiredNumberScheduled":4,"numberReady":4}},
         {"status":{"desiredNumberScheduled":4,"numberReady":3}},
         {"status":{"desiredNumberScheduled":0}}]
        """)
        #expect(WorkloadCounts.tally(.daemonSets, daemons) == WorkloadCounts(total: 3, running: 2, pending: 1))
    }

    @Test func jobsAreReadFromTheirConditionsBeforeTheirActiveCount() throws {
        let items = try objects("""
        [{"status":{"active":1}},
         {"status":{"conditions":[{"type":"Complete","status":"True"}]}},
         {"status":{"conditions":[{"type":"SuccessCriteriaMet","status":"True"}],"active":1}},
         {"status":{"conditions":[{"type":"Failed","status":"True"}]}},
         {"status":{"conditions":[{"type":"FailureTarget","status":"True"}],"active":2}},
         {"spec":{"suspend":true},"status":{"conditions":[{"type":"Suspended","status":"True"}]}},
         {"status":{}}]
        """)
        #expect(WorkloadCounts.tally(.jobs, items) == WorkloadCounts(total: 7, running: 1, succeeded: 2, pending: 2, failed: 2))
    }

    /// A CronJob's `status.active` is a list of Job references, not the number a Job reports.
    @Test func cronJobsCountActiveJobsAndSuspension() throws {
        let items = try objects("""
        [{"spec":{"suspend":false},"status":{"active":[{"kind":"Job","name":"a"}]}},
         {"spec":{"suspend":true},"status":{}},
         {"spec":{"suspend":true},"status":{"active":[{"kind":"Job","name":"b"}]}},
         {"spec":{},"status":{"lastScheduleTime":"2026-11-09T10:00:00Z"}}]
        """)
        #expect(WorkloadCounts.tally(.cronJobs, items) == WorkloadCounts(total: 4, running: 2, pending: 1))
    }

    @Test func aNodeWithoutAReadyConditionIsNotReady() throws {
        let nodes = try JSONDecoder().decode([NodeObject].self, from: Data("""
        [{"status":{"conditions":[{"type":"MemoryPressure","status":"False"},{"type":"Ready","status":"True"}]}},
         {"status":{"conditions":[{"type":"Ready","status":"Unknown","reason":"NodeStatusUnknown"}]}},
         {"status":{}}]
        """.utf8))
        var counts = NodeCounts()
        nodes.forEach { counts.add($0) }
        #expect(counts == NodeCounts(total: 3, ready: 1))
    }

    @Test func reconcileCarriesTheOverviewOnlyForAnUnchangedSnapshot() throws {
        var overview = ClusterOverview()
        overview.warningEvents = .value(4)
        let existing = [
            ClusterStatus(context: try appContext(), state: .connected, overview: overview),
            ClusterStatus(context: try appContext("second"), state: .connected, overview: overview),
        ]
        let reconciled = ClusterStatus.reconcile(
            existing: existing, contexts: [try appContext(), try redefinedContext("second")]
        )
        #expect(reconciled[0].overview == overview)
        #expect(reconciled[1].overview == ClusterOverview())
    }
}
