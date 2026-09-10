import Foundation
import KubixCore
import Testing

struct RetryAfterTests {
    let now = Date(timeIntervalSince1970: 1_445_412_480) // Wed, 21 Oct 2015 07:28:00 GMT

    @Test(arguments: [
        ("0", 0.0), ("0002", 2), ("  45 ", 45),
        ("Wed, 21 Oct 2015 07:28:45 GMT", 45), ("Wed, 21 Oct 2015 07:27:00 GMT", 0),
    ])
    func deltaSecondsAndHTTPDatesUseInjectedWallTime(header: String, expected: Double) {
        #expect(RetryAfter.delay(header, now: now) == expected)
    }

    @Test(arguments: [
        nil, "", " ", "-1", "+1", "1.5", "NaN", "inf", "1e9", "forty-five",
        "Wed, 99 Oct 2015 07:28:45 GMT", "Wed, 21 Oct 2015 07:28:45 GMT trailing",
        "2015-10-21T07:28:45Z", String(repeating: "9", count: 400),
    ])
    func malformedHeadersAreNotRetainedOrUsed(_ header: String?) {
        #expect(RetryAfter.delay(header, now: now) == nil)
    }

    @Test func responseRetainsOnlyNumericStatusRetryMetadataAndRedactsMessages() throws {
        let body = Data("""
        {"apiVersion":"v1","kind":"Status","reason":"TooManyRequests","message":"synthetic-token",
         "details":{"name":"synthetic-token","uid":"synthetic-token","retryAfterSeconds":15,
                    "causes":[{"message":"synthetic-token"}]},"code":429}
        """.utf8)
        let error = APIError.response(
            code: 429, body: body, resource: "pods", redacting: "synthetic-token",
            retryAfter: "Wed, 21 Oct 2015 07:28:45 GMT", now: now
        )
        #expect(error.httpCode == 429 && error.retryAfterDelay == 45)
        #expect(error.kubernetesStatus?.details?.retryAfterSeconds == 15)
        #expect(error.kubernetesStatus?.details?.name == nil && error.kubernetesStatus?.details?.causes == nil)
        #expect(error.kubernetesStatus?.message == "[redacted]")
        #expect(!String(reflecting: error).contains("synthetic-token"))
        #expect(!error.credentialRefreshExhausted)
        let status = try watchStatus(429, details: #"{"retryAfterSeconds":100}"#)
        #expect(APIError.retryAfter(.status(status, httpCode: 429, resource: "pods"), delay: 45).retryAfterDelay == 100)
        #expect(APIError.credentialsExhausted(.status(status, httpCode: 401, resource: "pods")).kubernetesStatus == status)
    }

    @Test func missingOrNegativeStatusDelayDoesNotOverrideBackoff() throws {
        for details in ["null", #"{"retryAfterSeconds":-1}"#] {
            let status = try watchStatus(500, details: details)
            let error = APIError.response(code: 500, body: try JSONEncoder().encode(status), resource: "pods")
            #expect(error.retryAfterDelay == nil && error.kubernetesStatus?.details == nil)
        }
        let error = APIError.response(code: 503, body: Data("not Status".utf8), resource: "pods", retryAfter: "42", now: now)
        #expect(error.retryAfterDelay == 42 && error.httpCode == 503 && error.kubernetesStatus == nil)
    }
}
