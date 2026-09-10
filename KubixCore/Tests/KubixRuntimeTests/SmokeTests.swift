import KubixCore
import KubixRuntime
import Testing

@Test func runtimeModuleLoadsWithCore() {
    #expect(KubixRuntimeModule.name == "KubixRuntime")
    #expect(KubixRuntimeModule.coreModuleName == KubixCoreModule.name)
}
