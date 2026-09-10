import Foundation
import KubixCore
import Testing

struct WatchStatusPrivacyTests {
    @Test(arguments: ["Forbidden", "SYNTHETIC-SECRET"])
    func terminalWatchStatusDropsAllFreeTextBeforeStoring(reason: String) throws {
        let status = try JSONDecoder().decode(KubernetesStatus.self, from: Data("""
        {"kind":"Status","apiVersion":"v1","code":403,"reason":"\(reason)",
         "status":"Failure","message":"SYNTHETIC-SECRET",
         "details":{"name":"SYNTHETIC-SECRET","group":"SYNTHETIC-SECRET","kind":"SYNTHETIC-SECRET",
         "uid":"SYNTHETIC-SECRET","causes":[{"reason":"SYNTHETIC-SECRET","message":"SYNTHETIC-SECRET","field":"SYNTHETIC-SECRET"}],
         "retryAfterSeconds":7}}
        """.utf8))
        var state = try watchState()
        let decision = state.receive(.error(status))
        guard case .failed(.api(let error)) = decision else { Issue.record("Expected terminal Status"); return }
        #expect(error.httpCode == 403 && error.retryAfterDelay == 7)
        #expect(error.kubernetesStatus?.reason == (reason == "Forbidden" ? reason : nil))
        #expect(error.kubernetesStatus?.message == nil && error.kubernetesStatus?.status == nil)
        let stored = try JSONEncoder().encode(#require(error.kubernetesStatus))
        #expect(!String(decoding: stored, as: UTF8.self).contains("SYNTHETIC-SECRET"))
        #expect(!String(reflecting: state).contains("SYNTHETIC-SECRET"))
        #expect(error.description.contains("pods watch"))
    }
}
