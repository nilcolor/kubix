import Foundation
import KubixCore
@testable import KubixRuntime
import Testing

struct PodSnapshotTests {
    @Test func memoryBudgetsAreCumulativeAndCheckedBeforeAppendingAnotherPage() throws {
        let first = try podPage(ids: [1], cursor: "next")
        let second = try podPage(ids: [2])
        var bytes = PodSnapshot(byteBudget: first.count + second.count - 1)
        try bytes.append(first, namespace: "team")
        #expect(throws: APIError.podSnapshot(.byteLimit)) { try bytes.append(second, namespace: "team") }
        #expect(bytes.rows.count == 1)
        var rows = PodSnapshot(rowBudget: 1)
        try rows.append(first, namespace: "team")
        #expect(throws: APIError.podSnapshot(.rowLimit)) { try rows.append(second, namespace: "team") }
        #expect(rows.rows.count == 1)
        var exact = PodSnapshot(rowBudget: 2, byteBudget: first.count + second.count)
        try exact.append(first, namespace: "team")
        try exact.append(second, namespace: "team")
        #expect(exact.rows.count == 2 && exact.cursor.isEmpty)
    }

    @Test func repeatedUIDWithinAPageAndMissingIdentityAreInvalid() throws {
        var snapshot = PodSnapshot()
        #expect(throws: APIError.podSnapshot(.duplicateUID)) {
            try snapshot.append(podPage(ids: [1, 1]), namespace: "team")
        }
        for field in ["uid", "name", "namespace"] {
            var object = try #require(JSONSerialization.jsonObject(with: podPage()) as? [String: Any])
            var rows = try #require(object["rows"] as? [[String: Any]])
            var rowObject = try #require(rows[0]["object"] as? [String: Any])
            var metadata = try #require(rowObject["metadata"] as? [String: Any])
            metadata.removeValue(forKey: field)
            rowObject["metadata"] = metadata
            rows[0]["object"] = rowObject
            object["rows"] = rows
            var missingIdentity = PodSnapshot()
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: APIError.podSnapshot(.invalidRow)) { try missingIdentity.append(data, namespace: "team") }
        }
    }

    @Test func absentHeadersReuseSchemaButExplicitEmptyAndMisalignedCellsAreRejected() throws {
        var absent = try #require(JSONSerialization.jsonObject(with: podPage(ids: [2])) as? [String: Any])
        absent.removeValue(forKey: "columnDefinitions")
        var snapshot = PodSnapshot()
        try snapshot.append(podPage(ids: [1], cursor: "next"), namespace: "team")
        try snapshot.append(JSONSerialization.data(withJSONObject: absent), namespace: "team")
        #expect(snapshot.columns?.count == 1 && snapshot.rows.count == 2)
        #expect(throws: APIError.podSnapshot(.inconsistentSchema)) {
            try snapshot.append(podPage(ids: [3], columns: []), namespace: "team")
        }
        var misaligned = PodSnapshot()
        #expect(throws: APIError.podSnapshot(.invalidRow)) {
            try misaligned.append(podPage(columns: []), namespace: "team")
        }
    }
}
