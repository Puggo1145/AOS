import Foundation
import Testing
@testable import OSSenseKit

@Suite("PreviewAdapter")
struct PreviewAdapterTests {

    @Test("Preview document projects to pdf.document payload")
    func previewDocumentProjectsToPayload() throws {
        let document = PreviewDocumentItem(
            title: "Quarterly Report.pdf",
            fileURL: URL(fileURLWithPath: "/Users/puggo/Documents/Quarterly Report.pdf")
        )

        let envelopes = PreviewAdapter.makeEnvelopes(from: document)

        #expect(envelopes.count == 1)
        let envelope = try #require(envelopes.first)
        #expect(envelope.kind == "pdf.document")
        #expect(envelope.citationKey == "pdf.document")
        #expect(envelope.displaySummary == "Quarterly Report.pdf")

        guard case let .object(payload) = envelope.payload else {
            Issue.record("expected object payload")
            return
        }
        #expect(payload["title"] == .string("Quarterly Report.pdf"))
        #expect(payload["fileURL"] == .string("file:///Users/puggo/Documents/Quarterly%20Report.pdf"))
    }

    @Test("Missing Preview document emits no envelope")
    func missingPreviewDocumentEmitsNoEnvelope() {
        #expect(PreviewAdapter.makeEnvelopes(from: nil).isEmpty)
    }

    @Test("Non-PDF Preview document emits no envelope")
    func nonPDFPreviewDocumentEmitsNoEnvelope() {
        let document = PreviewDocumentItem(
            title: "Screenshot.png",
            fileURL: URL(fileURLWithPath: "/Users/puggo/Desktop/Screenshot.png")
        )

        #expect(PreviewAdapter.makeEnvelopes(from: document).isEmpty)
    }

    @Test("PreviewAdapter declares Preview routing and live-stream permissions")
    func adapterContract() {
        #expect(PreviewAdapter.id == "preview")
        #expect(PreviewAdapter.supportedBundleIds == ["com.apple.Preview"])
        #expect(PreviewAdapter().requiredPermissions == [.accessibility, .automation])
    }
}
