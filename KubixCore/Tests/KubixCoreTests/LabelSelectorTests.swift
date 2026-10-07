import Foundation
@testable import KubixCore
import Testing

/// The selector is the only thing standing between "this deployment's pods" and "some other
/// workload's pods", and it is assembled into a query string by hand. `,` and `=` are the grammar's
/// own separators, so a key carrying one is a *different* selector rather than an invalid one — which
/// is why these are rejected rather than escaped.
@Suite struct LabelSelectorTests {
    @Test func labelsRenderSortedSoTheSameSelectorIsTheSameRequest() throws {
        let selector = try LabelSelector(["tier": "web", "app": "checkout", "pod-template-hash": "7d9f"])
        #expect(selector.query == "app=checkout,pod-template-hash=7d9f,tier=web")
        // An empty value is legal, and `key=` is how the grammar says so.
        #expect(try LabelSelector(["app": ""]).query == "app=")
    }

    @Test func prefixedKeysAndTheFullCharacterSetAreAccepted() throws {
        #expect(try LabelSelector(["app.kubernetes.io/name": "checkout"]).query == "app.kubernetes.io/name=checkout")
        #expect(try LabelSelector(["a_b.c-d": "A_1.b-2"]).query == "a_b.c-d=A_1.b-2")
        let longest = String(repeating: "a", count: 63)
        #expect(try LabelSelector([longest: longest]).query == "\(longest)=\(longest)")
    }

    @Test func aSelectorWithNoLabelsIsRefusedRatherThanMatchingEverything() {
        #expect(throws: LabelSelectorFailure.empty) { try LabelSelector([:]) }
    }

    @Test(arguments: [
        "", "-leading", "trailing-", ".dotted.", "_under", "has space", "has,comma", "has=equals",
        "has(paren", "has!bang", "a/b/c", "/name", "name/", "héllo",
    ])
    func anUnaddressableKeyIsRefused(_ key: String) {
        #expect(throws: LabelSelectorFailure.invalidKey) { try LabelSelector([key: "value"]) }
    }

    @Test(arguments: ["-leading", "trailing-", "has space", "has,comma", "has=equals", "héllo"])
    func anUnaddressableValueIsRefused(_ value: String) {
        #expect(throws: LabelSelectorFailure.invalidValue) { try LabelSelector(["app": value]) }
    }

    @Test func anythingOverSixtyThreeCharactersIsRefused() throws {
        let tooLong = String(repeating: "a", count: 64)
        #expect(throws: LabelSelectorFailure.invalidKey) { try LabelSelector([tooLong: "value"]) }
        #expect(throws: LabelSelectorFailure.invalidValue) { try LabelSelector(["app": tooLong]) }
        let longPrefix = String(repeating: "a", count: 60) + "." + String(repeating: "b", count: 60)
        #expect(try LabelSelector(["\(longPrefix)/name": "v"]).query.hasSuffix("/name=v"))
        let hugePrefix = (0..<5).map { _ in String(repeating: "a", count: 63) }.joined(separator: ".")
        #expect(throws: LabelSelectorFailure.invalidKey) { try LabelSelector(["\(hugePrefix)/name": "v"]) }
    }
}
