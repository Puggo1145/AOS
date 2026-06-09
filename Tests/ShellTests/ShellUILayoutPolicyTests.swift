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

    @Test("settings page transitions are top-leading anchored")
    func settingsPageTransitionsAreTopLeadingAnchored() throws {
        let settings = try Self.source("Sources/Shell/Notch/Settings/SettingsPanelView.swift")

        #expect(settings.contains("ZStack(alignment: .topLeading)"))
        #expect(settings.components(separatedBy: ".frame(maxWidth: .infinity, alignment: .topLeading)").count >= 9)
    }

    @Test("settings main page scrolls only middle vertical rows")
    func settingsMainPageScrollsOnlyMiddleVerticalRows() throws {
        let settings = try Self.source("Sources/Shell/Notch/Settings/SettingsPanelView.swift")
        let mainPage = try Self.section(
            in: settings,
            from: "private var mainPage: some View",
            to: "// MARK: - API key row + page"
        )
        let cardsRange = try #require(mainPage.range(of: "BentoPickerCard("))
        let scrollRange = try #require(mainPage.range(of: "ScrollView(.vertical, showsIndicators: false)"))
        let quitRange = try #require(mainPage.range(of: "quitButton"))
        let scrollToQuit = try Self.section(
            in: mainPage,
            from: "ScrollView(.vertical, showsIndicators: false)",
            to: "quitButton"
        )

        #expect(cardsRange.lowerBound < scrollRange.lowerBound)
        #expect(scrollRange.lowerBound < quitRange.lowerBound)
        #expect(!scrollToQuit.contains("BentoPickerCard("))
        #expect(mainPage.contains(".frame(maxHeight: mainRowsScrollMaxHeight)"))
    }

    @Test("settings MCP page exposes add-server form")
    func settingsMcpPageExposesAddServerForm() throws {
        let settings = try Self.source("Sources/Shell/Notch/Settings/SettingsPanelView.swift")
        let draft = try Self.source("Sources/Shell/Notch/Settings/McpServerDraft.swift")
        let rows = try Self.source("Sources/Shell/Notch/Settings/SettingsRows.swift")

        #expect(settings.contains("case mcpAdd"))
        #expect(settings.contains("private var mcpAddPage: some View"))
        #expect(settings.contains("SettingsMcpAddButton"))
        #expect(settings.contains("Picker(\"Auth\", selection: $mcpDraft.authType)"))
        #expect(settings.contains("Toggle(isOn: $mcpDraft.autoConnect)"))
        #expect(settings.contains("openMcpEditPage"))
        #expect(settings.contains("mcpDraft.buildAddParams()"))
        #expect(settings.contains("mcpDraft.buildUpdateParams()"))
        #expect(draft.contains("McpAddParams("))
        #expect(draft.contains("McpUpdateParams("))
        #expect(draft.contains("authType: authType"))
        #expect(draft.contains("autoConnect: autoConnect"))
        #expect(draft.contains("headersForSelectedAuthType()"))
        #expect(draft.contains("decodeJSON([String].self"))
        #expect(rows.contains("struct SettingsMcpAddButton"))
        #expect(rows.contains("Label(\"Edit\", systemImage: \"pencil\")"))
    }

    @Test("settings MCP server items do not render separate status text")
    func settingsMcpServerItemsDoNotRenderSeparateStatusText() throws {
        let rows = try Self.source("Sources/Shell/Notch/Settings/SettingsRows.swift")
        let card = try Self.section(
            in: rows,
            from: "struct SettingsMcpServerCard: View",
            to: "struct SettingsDisplayModeRow: View"
        )

        #expect(!card.contains("\"Disconnected\""))
        #expect(!card.contains("\"Connected\""))
        #expect(!card.contains("\"Authenticating…\""))
        #expect(!card.contains("\"Awaiting callback…\""))
        #expect(!card.contains("\"Verifying…\""))
        #expect(!card.contains("\"Auth required\""))
        #expect(!card.contains("\"Auth failed\""))
        #expect(!card.contains("\"Auth cancelled\""))
    }

    @Test("opened content swaps are top-leading anchored")
    func openedContentSwapsAreTopLeadingAnchored() throws {
        let notchView = try Self.source("Sources/Shell/Notch/NotchView.swift")

        #expect(notchView.contains("private var openedContent: some View"))
        #expect(notchView.contains("ZStack(alignment: .topLeading)"))
    }

    @Test("attached and detached panels share opened content state animations")
    func attachedAndDetachedPanelsShareOpenedContentStateAnimations() throws {
        let notchView = try Self.source("Sources/Shell/Notch/NotchView.swift")

        #expect(notchView.contains("private var animatedOpenedContent: some View"))
        #expect(notchView.components(separatedBy: "animatedOpenedContent").count >= 3)
        #expect(notchView.contains("private var openedPanelAnimationKey: OpenedPanelAnimationKey"))
        #expect(notchView.contains("private var openedPanelContent: some View"))
        #expect(notchView.contains("private var openedTrayContent: some View"))
        #expect(notchView.components(separatedBy: "value: openedPanelAnimationKey").count >= 3)
        #expect(!notchView.contains("value: viewModel.notchOpenedSize.height"))
        #expect(notchView.components(separatedBy: "SystemTrayView(viewModel: viewModel)").count == 2)
    }

    @Test("opened panel height animation wraps the final clipped frame")
    func openedPanelHeightAnimationWrapsTheFinalClippedFrame() throws {
        let notchView = try Self.source("Sources/Shell/Notch/NotchView.swift")
        let openedPanelContent = try Self.section(
            in: notchView,
            from: "private var openedPanelContent: some View",
            to: "private var openedTrayContent: some View"
        )
        let animatedOpenedContent = try Self.section(
            in: notchView,
            from: "private var animatedOpenedContent: some View",
            to: "private var openedPanelContent: some View"
        )

        let frameRange = try #require(openedPanelContent.range(of: ".frame("))
        let animationRange = try #require(openedPanelContent.range(of: ".animation(reduceMotion ? nil : .notchHeight"))
        #expect(frameRange.lowerBound < animationRange.lowerBound)
        #expect(!animatedOpenedContent.contains(".animation("))
    }

    @Test("detached placement is derived from opened surface size instead of synchronized from content didSets")
    func detachedPlacementIsDerivedFromOpenedSurfaceSizeInsteadOfSynchronizedFromContentDidSets() throws {
        let viewModel = try Self.source("Sources/Shell/Notch/NotchViewModel.swift")

        #expect(viewModel.contains("public var currentPlacement: NotchPlacement"))
        #expect(!viewModel.contains("syncFloatingPlacementToDetachedTotalSize"))
        #expect(!viewModel.contains("didSet { sync"))
    }

    @Test("detached opened-surface geometry changes are emitted by view model state changes")
    func detachedOpenedSurfaceGeometryChangesAreEmittedByViewModelStateChanges() throws {
        let notchView = try Self.source("Sources/Shell/Notch/NotchView.swift")
        let viewModel = try Self.source("Sources/Shell/Notch/NotchViewModel.swift")

        #expect(!notchView.contains(".onChange(of: viewModel.notchOpenedTotalSize)"))
        #expect(viewModel.contains("private func openedSurfaceStateDidChange()"))
    }

    @Test("detached window shrink keeps last-applied placement tied to applied frame")
    func detachedWindowShrinkKeepsLastAppliedPlacementTiedToAppliedFrame() throws {
        let controller = try Self.source("Sources/Shell/Notch/NotchWindowController.swift")

        #expect(controller.contains("pendingDeferredFrame: self.deferredWindowFrameTarget"))
        #expect(controller.contains("lastAppliedPlacement = self.deferredWindowFramePlacement ?? appliedPlacement"))
        #expect(!controller.contains("self.lastAppliedPlacement = currentPlacement\n                self.applyWindowFrame"))
    }

    @Test("opened page measurements report on appear and on height changes")
    func openedPageMeasurementsReportOnAppearAndOnHeightChanges() throws {
        let notchView = try Self.source("Sources/Shell/Notch/NotchView.swift")

        #expect(notchView.contains("private struct HeightReporter: View"))
        #expect(notchView.contains(".onAppear"))
        #expect(notchView.contains(".onChange(of: geo.size.height)"))
        #expect(!notchView.contains(".onPreferenceChange(SettingsHeightKey.self)"))
        #expect(!notchView.contains(".onPreferenceChange(HistoryPanelHeightKey.self)"))
    }

    private static func source(_ path: String, file: String = #filePath) throws -> String {
        let url = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func section(in source: String, from start: String, to end: String) throws -> String {
        let startRange = try #require(source.range(of: start))
        let tail = source[startRange.lowerBound...]
        let endRange = try #require(tail.range(of: end))
        return String(tail[..<endRange.lowerBound])
    }
}
