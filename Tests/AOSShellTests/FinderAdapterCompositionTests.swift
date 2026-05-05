import Testing
import AOSOSSenseKit
@testable import AOSShell

@Suite("FinderAdapter composition")
struct FinderAdapterCompositionTests {

    @Test("Shell registers FinderAdapter for Finder bundle routing")
    func shellRegistersFinderAdapter() async {
        let registry = AdapterRegistry()

        await CompositionRoot.registerBuiltinSenseAdapters(into: registry)

        let adapters = await registry.adapters(matching: "com.apple.finder")
        #expect(adapters.count == 1)
        #expect(type(of: adapters[0]).id == "finder")
    }
}
