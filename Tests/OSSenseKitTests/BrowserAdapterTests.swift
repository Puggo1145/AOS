import Testing
@testable import OSSenseKit

@Suite("BrowserAdapter")
struct BrowserAdapterTests {

    @Test("Browser tab projects URL and title to browser.tab payload")
    func browserTabProjectsToPayload() throws {
        let tab = BrowserTabItem(
            url: "file:///Users/puggo/Documents/Quarterly%20Report.pdf",
            title: "Quarterly Report.pdf"
        )

        let envelopes = BrowserAdapter.makeEnvelopes(from: tab)

        #expect(envelopes.count == 1)
        let envelope = try #require(envelopes.first)
        #expect(envelope.kind == "browser.tab")
        #expect(envelope.citationKey == "browser.tab")
        #expect(envelope.displaySummary == "Quarterly Report.pdf")

        guard case let .object(payload) = envelope.payload else {
            Issue.record("expected object payload")
            return
        }
        #expect(payload["url"] == .string("file:///Users/puggo/Documents/Quarterly%20Report.pdf"))
        #expect(payload["pageTitle"] == .string("Quarterly Report.pdf"))
    }

    @Test("Browser tab without URL emits no envelope")
    func browserTabWithoutURLEmitsNoEnvelope() {
        #expect(BrowserAdapter.makeEnvelopes(from: BrowserTabItem(url: "", title: "New Tab")).isEmpty)
        #expect(BrowserAdapter.makeEnvelopes(from: nil).isEmpty)
    }

    @Test("BrowserAdapter declares known browser routing and live-stream permissions")
    func adapterContract() {
        #expect(BrowserAdapter.id == "browser")
        #expect(BrowserAdapter.supportedBundleIds.contains("com.apple.Safari"))
        #expect(BrowserAdapter.supportedBundleIds.contains("com.google.Chrome"))
        #expect(BrowserAdapter.supportedBundleIds.contains("company.thebrowser.Browser"))
        #expect(BrowserAdapter().requiredPermissions == [.accessibility, .automation])
    }
}
