import Foundation
import KubixCore
import Testing

struct WatchRetryTests {
    @Test(arguments: [410, 401, 403, 429, 500, 502, 503, 504, 404, 400])
    func httpAndInStreamCodesHaveDistinctDecisions(_ code: Int) throws {
        var http = try watchState()
        var stream = try watchState()
        let error = APIError.http(code: code, resource: "pods")
        let status = try watchStatus(code)
        let expected: WatchDecision
        switch code {
        case 410: expected = .relist
        case 401: expected = .refreshCredentials
        case 429, 500...599: expected = .retry(delay: 1, resourceVersion: "list-rv")
        default: expected = .failed(.api(error))
        }
        #expect(http.failedRequest(error, jitter: 1) == expected)
        let streamed = stream.receive(.error(status), jitter: 1)
        if case .failed = expected {
            #expect(streamed == .failed(.api(.watchStatus(status))))
        } else { #expect(streamed == expected) }
        #expect(http.rows.isEmpty == (code == 410))
        #expect(stream.rows.isEmpty == (code == 410))
    }

    @Test(arguments: [
        ("Expired", 410), ("Gone", 410), ("Unauthorized", 401), ("Forbidden", 403),
        ("TooManyRequests", 429), ("InternalError", 500), ("ServiceUnavailable", 503),
        ("Timeout", 504), ("ServerTimeout", 504), ("CustomFailure", 0),
    ])
    func reasonOnlyStatusIsNotMistakenForTableOrAutomaticRelist(reason: String, code: Int) throws {
        var state = try watchState()
        let status = try watchStatus(reason: reason)
        var comparison = try watchState()
        #expect(APIError.watchStatus(status).httpCode == code)
        #expect(state.receive(.error(status)) == comparison.failedRequest(.watchStatus(status)))
    }

    @Test func httpForbiddenOverridesMisleadingExpiredBodyAndDoesNotLoop() throws {
        var state = try watchState()
        let error = APIError.status(try watchStatus(410, reason: "Expired"), httpCode: 403, resource: "pods")
        #expect(state.failedRequest(error) == .failed(.api(error)))
        #expect(state.resume() == .failed(.api(error)))
        #expect(state.rows.count == 1)
    }

    @Test func expiredHistoryClearsSnapshotAndRelistPreservesBudgets() throws {
        var state = try watchState()
        _ = state.failedRequest(.http(code: 401, resource: "pods"))
        _ = state.resume()
        _ = state.end(.eof, elapsed: 1)
        _ = state.resume()
        #expect(state.receive(.error(try watchStatus(reason: "Expired"))) == .relist)
        #expect(state.rows.isEmpty && state.rowsByUID.isEmpty && state.columns == nil && state.resourceVersion.isEmpty)
        let table = try watchTable(columns: watchColumns)
        #expect(state.installSnapshot(rows: try table.rows.map(ResourceRow.init), columns: table.columnDefinitions, resourceVersion: "fresh") == .watch(resourceVersion: "fresh"))
        #expect(state.retryAttempts == 1 && state.credentialRefreshes == 1)
        #expect(state.resume() == .watch(resourceVersion: "fresh"))
        #expect(state.failedRequest(.http(code: 401, resource: "pods")) == .failed(.credentialRefreshLimit))
    }

    @Test func invalidRelistSnapshotCannotPartiallyInstall() throws {
        var state = try watchState()
        _ = state.failedRequest(.http(code: 410, resource: "pods"))
        let table = try watchTable()
        #expect(state.installSnapshot(rows: try table.rows.map(ResourceRow.init), columns: [], resourceVersion: "fresh") == .failed(.decoding(.invalidPayload)))
        #expect(state.rows.isEmpty && state.resourceVersion.isEmpty && state.columns == nil)
    }

    @Test(arguments: [true, false])
    func authRefreshBudgetSurvivesEventsAndFailedSessions(_ sendEvent: Bool) throws {
        var state = try watchState()
        #expect(state.receive(.error(try watchStatus(401))) == .refreshCredentials)
        #expect(state.resume() == .watch(resourceVersion: "list-rv"))
        if sendEvent { #expect(state.receive(try watchEvent("MODIFIED")) == .applied) }
        _ = state.end(.disconnected, elapsed: 10)
        _ = state.resume()
        #expect(state.receive(.error(try watchStatus(401))) == .failed(.credentialRefreshLimit))
        #expect(state.credentialRefreshes == 1)
    }

    @Test func transportExhausted401MustNeverRequestAnotherRefresh() throws {
        var state = try watchState()
        let error = APIError.retryAfter(.credentialsExhausted(.http(code: 401, resource: "pods")), delay: 3)
        #expect(error.httpCode == 401 && error.credentialRefreshExhausted)
        #expect(state.failedRequest(error) == .failed(.credentialRefreshLimit))
        #expect(state.credentialRefreshes == 0 && state.rows.count == 1)
    }

    @Test(arguments: [true, false])
    func boundedBackoffProgressionSurvivesShortConnectionsWithOrWithoutEvents(_ sendEvent: Bool) throws {
        var state = try watchState()
        for (attempt, delay) in [1.0, 2, 4, 8, 16, 30].enumerated() {
            if sendEvent {
                #expect(state.receive(try watchEvent("MODIFIED")) == .applied)
                #expect(state.receive(.bookmark(try WatchBookmark(resourceVersion: "progress"))) == .applied)
            }
            #expect(state.end(.eof, elapsed: 1, jitter: 1) == .retry(delay: delay, resourceVersion: state.resourceVersion))
            #expect(state.retryAttempts == attempt + 1)
            _ = state.resume()
        }
        #expect(state.end(.eof, elapsed: 1) == .failed(.retryLimit))
        #expect(state.resume() == .failed(.retryLimit))
    }

    @Test(arguments: [0.0, 0.5, 1])
    func deterministicEqualJitterAndServerRetryAfterAreHonored(_ jitter: Double) throws {
        var state = try watchState()
        #expect(state.end(.disconnected, elapsed: 2, jitter: jitter) == .retry(delay: 0.5 + 0.5 * jitter, resourceVersion: "list-rv"))
        _ = state.resume()
        let status = try watchStatus(429, details: #"{"retryAfterSeconds":45,"causes":[{"reason":"Throttled","field":"watch"}]}"#)
        #expect(status.details?.causes?.first?.reason == "Throttled")
        #expect(state.receive(.error(status), jitter: jitter) == .retry(delay: 45, resourceVersion: "list-rv"))
        _ = state.resume()
        #expect(state.failedRequest(.retryAfter(.http(code: 503, resource: "pods"), delay: 50), jitter: jitter) == .retry(delay: 50, resourceVersion: "list-rv"))
    }

    @Test(arguments: [300.0, 329.999])
    func onlyHealthyLeaseEOFResetsBothBudgetsAndPreservesRows(_ elapsed: Double) throws {
        var state = try watchState()
        _ = state.failedRequest(.http(code: 401, resource: "pods"))
        _ = state.resume()
        _ = state.end(.disconnected, elapsed: 1)
        _ = state.resume()
        let rows = state.rows
        let columns = state.columns
        #expect(state.end(.eof, elapsed: elapsed) == .watch(resourceVersion: "list-rv"))
        #expect(state.rows == rows && state.columns == columns && state.retryAttempts == 0 && state.credentialRefreshes == 0)
        _ = state.resume()
        #expect(state.failedRequest(.http(code: 401, resource: "pods")) == .refreshCredentials)
    }

    @Test(arguments: [0.0, 299.999, 330, 400])
    func earlyOrClientDeadlineEOFIsNotHealthyLease(_ elapsed: Double) throws {
        var state = try watchState()
        #expect(state.end(.eof, elapsed: elapsed, jitter: 1) == .retry(delay: 1, resourceVersion: "list-rv"))
        #expect(state.rows.count == 1)
    }

    @Test(arguments: [WatchEnd.disconnected, .clientDeadline])
    func explicitFailuresAreNotLeaseRenewalsEvenAfter300Seconds(_ end: WatchEnd) throws {
        var state = try watchState()
        #expect(state.end(end, elapsed: 300, jitter: 1) == .retry(delay: 1, resourceVersion: "list-rv"))
        _ = state.resume()
        #expect(state.failedRequest(.transport(.timedOut), jitter: 1) == .retry(delay: 2, resourceVersion: "list-rv"))
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func cancellationDominatesPendingRetryAuthRelistTerminalAndEveryLateInput(_ phase: Int) throws {
        var state = try watchState()
        switch phase {
        case 1: _ = state.end(.eof, elapsed: 1)
        case 2: _ = state.failedRequest(.http(code: 401, resource: "pods"))
        case 3: _ = state.failedRequest(.http(code: 410, resource: "pods"))
        case 4: _ = state.decodingFailed(.invalidUTF8)
        default: break
        }
        #expect(state.end(.cancelled, elapsed: .nan) == .stopped)
        let rows = state.rows
        let version = state.resourceVersion
        #expect(state.resume() == .stopped)
        #expect(state.receive(try watchEvent("ADDED")) == .stopped)
        #expect(state.failedRequest(.http(code: 401, resource: "pods")) == .stopped)
        #expect(state.end(.eof, elapsed: 300) == .stopped)
        #expect(state.installSnapshot(rows: [], columns: [], resourceVersion: "late") == .stopped)
        #expect(state.decodingFailed(.truncatedEOF) == .stopped && state.cancel() == .stopped)
        #expect(state.rows == rows && state.resourceVersion == version && state.phase == .stopped)
    }

    @Test(arguments: [-1.0, Double.infinity, Double.nan])
    func invalidElapsedAndJitterFailInsteadOfProducingUnboundedRetry(_ value: Double) throws {
        var state = try watchState()
        #expect(state.end(.eof, elapsed: value) == .failed(.invalidTransition))
        var jitter = try watchState()
        #expect(jitter.end(.disconnected, elapsed: 1, jitter: value) == .failed(.invalidTransition))
    }

    @Test(arguments: [TransportFailure.invalidResponse, .receiveBufferOverflow, .streamReadInProgress, .nonBinaryMessage])
    func nonTransientTransportFailuresAreVisibleRatherThanRetried(_ failure: TransportFailure) throws {
        var state = try watchState()
        #expect(state.failedRequest(.transport(failure)) == .failed(.api(.transport(failure))))
    }
}
