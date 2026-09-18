import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

@Suite struct PodMetricsServiceTests {
    /// The shape a live `metrics.k8s.io` list has: nanocore and bare-zero CPU, `Ki` and `Mi` memory,
    /// a Go-duration window, and two containers in one pod.
    static let body = Data("""
    {"kind":"PodMetricsList","apiVersion":"metrics.k8s.io/v1beta1","items":[
      {"metadata":{"name":"web-a","namespace":"dev","creationTimestamp":"2026-09-18T10:00:30Z"},
       "timestamp":"2026-09-18T10:00:00Z","window":"15.5s",
       "containers":[{"name":"app","usage":{"cpu":"250400000n","memory":"131072Ki"}},
                     {"name":"proxy","usage":{"cpu":"15u","memory":"64Mi"}}]},
      {"metadata":{"name":"idle","namespace":"dev"},"timestamp":"2026-09-18T10:00:00Z","window":"1m0s",
       "containers":[{"name":"app","usage":{"cpu":"0","memory":"1Mi"}}]}
    ]}
    """.utf8)

    @Test func listsANamespaceThroughTheAuthenticatedTransportAndSumsEachPod() async throws {
        let context = try transportConfiguration().resolve()
        let session = ScriptedTransportSession { _, _ in HTTPDataResponse(statusCode: 200, body: Self.body) }
        let service = PodMetricsService { [transport = try await testTransport(session: session)] _ in transport }

        let usage = try await service.podMetrics(context: context, namespace: "dev")

        #expect(usage.map(\.name) == ["web-a", "idle"])
        // Typed, because `#expect` infers an untyped literal sum differently from the value compared.
        let cpu: Decimal = 250_400_000 + 15_000
        let memory: Decimal = 134_217_728 + 67_108_864
        #expect(usage[0].cpuNanocores == cpu)
        #expect(usage[0].memoryBytes == memory)
        #expect(usage[0].window == 15.5 && usage[1].window == 60)
        #expect(usage[0].timestamp == RFC3339.date(from: "2026-09-18T10:00:00Z"))
        #expect(usage[1].cpuNanocores == 0)
        let request = try #require(await session.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://synthetic.invalid/apis/metrics.k8s.io/v1beta1/namespaces/dev/pods")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token-0")
    }

    @Test func aPodWithAnUnreadableSampleIsLeftOutWithoutVoidingTheRest() async throws {
        let body = Data("""
        {"kind":"PodMetricsList","items":[
          {"metadata":{"name":"bad"},"timestamp":"2026-09-18T10:00:00Z","window":"15s",
           "containers":[{"usage":{"cpu":"lots","memory":"1Mi"}}]},
          {"metadata":{"name":"late"},"timestamp":"yesterday","window":"15s","containers":[]},
          {"metadata":{"name":"good"},"timestamp":"2026-09-18T10:00:00Z","window":"15s",
           "containers":[{"usage":{"cpu":"1m","memory":"1Mi"}}]}
        ]}
        """.utf8)
        let session = ScriptedTransportSession { _, _ in HTTPDataResponse(statusCode: 200, body: body) }
        let service = PodMetricsService { [transport = try await testTransport(session: session)] _ in transport }
        let usage = try await service.podMetrics(context: try transportConfiguration().resolve(), namespace: "dev")
        #expect(usage.map(\.name) == ["good"])
    }

    @Test(arguments: [
        Data("not json".utf8),
        Data(#"{"kind":"Status","items":[]}"#.utf8),
        Data(#"{"kind":"PodMetricsList"}"#.utf8),
    ])
    func aBodyThatIsNotAMetricsListIsMalformed(_ body: Data) async throws {
        let session = ScriptedTransportSession { _, _ in HTTPDataResponse(statusCode: 200, body: body) }
        let service = PodMetricsService { [transport = try await testTransport(session: session)] _ in transport }
        await #expect(throws: PodMetricsFailure.malformed) {
            _ = try await service.podMetrics(context: try transportConfiguration().resolve(), namespace: "dev")
        }
    }

    @Test func anUnboundedBodyIsRefused() async throws {
        let session = ScriptedTransportSession { _, _ in
            HTTPDataResponse(statusCode: 200, body: Data(count: PodMetricsService.byteLimit + 1))
        }
        let service = PodMetricsService { [transport = try await testTransport(session: session)] _ in transport }
        await #expect(throws: PodMetricsFailure.tooManyBytes) {
            _ = try await service.podMetrics(context: try transportConfiguration().resolve(), namespace: "dev")
        }
    }

    /// The caller decides what an absent or forbidden API means; the service reports the status.
    @Test(arguments: [403, 404, 503])
    func statusFailuresReachTheCallerWithTheirCode(_ code: Int) async throws {
        let session = ScriptedTransportSession { _, _ in HTTPDataResponse(statusCode: code, body: Data()) }
        let service = PodMetricsService { [transport = try await testTransport(session: session)] _ in transport }
        do {
            _ = try await service.podMetrics(context: try transportConfiguration().resolve(), namespace: "dev")
            Issue.record("a \(code) was accepted as metrics")
        } catch let error as APIError {
            #expect(error.httpCode == code)
        }
    }
}
