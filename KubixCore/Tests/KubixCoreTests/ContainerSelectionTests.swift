import Foundation
import KubixCore
import Testing

@Suite struct ContainerSelectionTests {
    private func fixture(_ name: String = "mixed") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "pod-details-\(name)", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func details(_ transform: (inout [String: Any]) -> Void = { _ in }) throws -> PodDetails {
        var object = try #require(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        transform(&object)
        return try JSONDecoder().decode(PodDetails.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func runningRegularOnlyAndAllDeclaredLogTypes() throws {
        let pod = try details()
        let selection = ContainerSelection(details: pod)
        #expect(selection.shell.map(\.name) == ["web", "sidecar"])
        #expect(selection.defaultShell == "sidecar")
        #expect(selection.unavailableExplanation == nil)
        #expect(selection.logs.map(\.name) == ["web", "sidecar", "waiting", "terminated", "unknown", "setup", "debugger"])
        #expect(selection.logs.map(\.kind) == [.regular, .regular, .regular, .regular, .regular, .initContainer, .ephemeral])
        #expect(selection.logs.map(\.state) == [.running, .running, .waiting, .terminated, .unknown, .running, .running])
        #expect(pod.uid == "synthetic-uid" && pod.name == "synthetic-pod" && pod.namespace == "team")
    }

    @Test(arguments: ["setup", "debugger", "waiting", "terminated", "unknown", "absent", ""])
    func ignoresIneligibleDefault(annotation: String) throws {
        let pod = try details { object in
            var metadata = object["metadata"] as? [String: Any] ?? [:]
            metadata["annotations"] = ["kubectl.kubernetes.io/default-container": annotation]
            object["metadata"] = metadata
        }
        #expect(ContainerSelection(details: pod).defaultShell == "web")
    }

    @Test func singleRegularAndUnreadyRunningIsEligible() throws {
        let pod = try details { object in
            object["spec"] = ["containers": [["name": "web"]]]
        }
        #expect(ContainerSelection(details: pod).shell.map(\.name) == ["web"])
        #expect(ContainerSelection(details: pod).defaultShell == "web")
    }

    @Test func initializingPodHasLogsButNoShell() throws {
        let pod = try JSONDecoder().decode(PodDetails.self, from: fixture("initializing"))
        let selection = ContainerSelection(details: pod)
        #expect(selection.shell.isEmpty && selection.defaultShell == nil)
        #expect(selection.unavailableExplanation?.contains("running regular") == true)
        #expect(selection.logs.map(\.name) == ["web", "setup", "debugger"])
    }

    @Test func absentStatusAndAnnotationAreSafe() throws {
        let pod = try details { object in
            object["status"] = NSNull()
            object["metadata"] = ["uid": "id", "name": "pod", "namespace": "team"]
        }
        #expect(ContainerSelection(details: pod).shell.isEmpty)
        #expect(pod.defaultContainer == nil)
        #expect(pod.containers.allSatisfy { $0.state == .unknown })
    }

    @Test func ambiguousOrMissingStateAndUndeclaredStatusCannotEnableExec() throws {
        let pod = try details { object in
            object["status"] = ["containerStatuses": [
                ["name": "web", "state": ["running": [:], "terminated": [:]]],
                ["name": "sidecar"],
                ["name": "undeclared", "state": ["running": [:]]],
            ]]
        }
        #expect(ContainerSelection(details: pod).shell.isEmpty)
        #expect(!pod.containers.contains { $0.name == "undeclared" })
    }

    @Test(arguments: ["kind", "apiVersion", "uid", "duplicateDeclaration", "duplicateState", "emptyName", "missingSpec"])
    func rejectsInvalidDetails(field: String) throws {
        #expect(throws: (any Error).self) {
            _ = try details { object in
                switch field {
                case "kind", "apiVersion": object[field] = "invalid"
                case "uid": object["metadata"] = ["uid": " ", "name": "pod", "namespace": "team"]
                case "duplicateDeclaration": object["spec"] = ["containers": [["name": "web"], ["name": "web"]]]
                case "duplicateState": object["status"] = ["containerStatuses": [["name": "web"], ["name": "web"]]]
                case "emptyName": object["spec"] = ["containers": [["name": ""]]]
                default: object["spec"] = NSNull()
                }
            }
        }
    }

    @Test func unrelatedPayloadIsNotDecodedOrRetained() throws {
        let pod = try details { object in
            var spec = object["spec"] as? [String: Any] ?? [:]
            spec["volumes"] = "deliberately wrong type"
            object["spec"] = spec
            object["metadata"] = [
                "uid": "id", "name": "pod", "namespace": "team",
                "annotations": ["irrelevant": ["not even a string"]], "managedFields": "ignored",
            ] as [String: Any]
        }
        #expect(pod.defaultContainer == nil && pod.containers.count == 7)
    }

    @Test(arguments: ["not-an-object", "false", "[]"])
    func aRunningStateMustActuallyBeAnObject(_ value: String) throws {
        #expect(throws: (any Error).self) {
            _ = try details { object in
                let invalid: Any = value == "false" ? false : value == "[]" ? [] : value
                object["status"] = ["containerStatuses": [["name": "web", "state": ["running": invalid]]]]
            }
        }
    }
}
