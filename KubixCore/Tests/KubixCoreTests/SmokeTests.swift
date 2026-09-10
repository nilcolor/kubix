import KubixCore
import Testing
import Yams

@Test func coreModuleLoads() {
    #expect(KubixCoreModule.name == "KubixCore")
}

@Test func yamlDependencyDecodes() throws {
    let value = try YAMLDecoder().decode([String: String].self, from: "name: kubix")
    #expect(value == ["name": "kubix"])
}

@Test func yamlDependencyRejectsMalformedInput() {
    #expect(throws: (any Error).self) {
        try YAMLDecoder().decode([String: String].self, from: "name: [")
    }
}
