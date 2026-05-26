import Foundation
import Testing

@Suite("Shell UI layout policy")
struct ShellUILayoutPolicyTests {
    @Test("permission approval bottom page is content-measured instead of stretch-measured")
    func permissionApprovalPageIsContentMeasured() throws {
        let section = try Self.source("Sources/Shell/Notch/Permissions/PermissionApprovalSection.swift")
        let card = try Self.source("Sources/Shell/Notch/Permissions/PermissionApprovalCard.swift")
        let pager = try Self.source("Sources/Shell/Notch/Chrome/OpenedPanelView.swift")

        #expect(!card.contains("fillsAvailableHeight"))
        #expect(!card.contains("Spacer(minLength:"))
        #expect(!section.contains(".hidden()"))
        #expect(!pager.contains("height: measuredPageHeight"))
    }

    private static func source(_ path: String, file: String = #filePath) throws -> String {
        let url = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
