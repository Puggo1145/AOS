import Testing
import OSSenseKit
@testable import Shell

@Suite("OS Sense adapter composition")
struct FinderAdapterCompositionTests {

    @Test("Shell registers FinderAdapter for Finder bundle routing")
    func shellRegistersFinderAdapter() async {
        let registry = AdapterRegistry()

        await CompositionRoot.registerBuiltinSenseAdapters(into: registry)

        let adapters = await registry.adapters(matching: "com.apple.finder")
        #expect(adapters.count == 1)
        #expect(type(of: adapters[0]).id == "finder")
    }

    @Test("Shell registers PreviewAdapter for Preview PDF routing")
    func shellRegistersPreviewAdapter() async {
        let registry = AdapterRegistry()

        await CompositionRoot.registerBuiltinSenseAdapters(into: registry)

        let adapters = await registry.adapters(matching: "com.apple.Preview")
        #expect(adapters.count == 1)
        #expect(type(of: adapters[0]).id == "preview")
    }

    @Test("Shell registers BrowserAdapter for browser tab routing")
    func shellRegistersBrowserAdapter() async {
        let registry = AdapterRegistry()

        await CompositionRoot.registerBuiltinSenseAdapters(into: registry)

        let adapters = await registry.adapters(matching: "com.apple.Safari")
        #expect(adapters.count == 1)
        #expect(type(of: adapters[0]).id == "browser")
    }
}
