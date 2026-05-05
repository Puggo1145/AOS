import Foundation
import Testing

@Suite("AOS app entitlements")
struct EntitlementsTests {

    @Test("hardened runtime build declares Apple Events automation entitlement")
    func hardenedRuntimeDeclaresAppleEventsAutomation() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let entitlementsURL = root.appendingPathComponent("Sources/AOSShellResources/AOS.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let entitlements = try #require(plist as? [String: Any])

        #expect(entitlements["com.apple.security.automation.apple-events"] as? Bool == true)
    }
}
