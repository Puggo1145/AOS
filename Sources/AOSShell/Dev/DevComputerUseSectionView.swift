import AppKit
import CoreGraphics
import SwiftUI
import AOSComputerUseKit

// MARK: - DevComputerUseSectionView
//
// Dev-only workbench for every public Computer Use capability. Calls the
// same in-process `ComputerUseService` instance used by the RPC handlers so
// state IDs and screenshot coordinate references are tested against the real
// Shell wiring.

struct DevComputerUseSectionView: View {
    @State private var workbench: DevComputerUseWorkbench
    @State private var selectedPage: DevComputerUsePage? = DevComputerUsePage.defaultSelection

    init(service: ComputerUseService, doctorService: ComputerUseDoctorService) {
        _workbench = State(
            initialValue: DevComputerUseWorkbench(
                service: service,
                doctorService: doctorService
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let message = workbench.lastError {
                    statusBanner(message, systemImage: "exclamationmark.triangle.fill", tint: .yellow)
                } else if let message = workbench.lastResult {
                    statusBanner(message, systemImage: "checkmark.circle.fill", tint: .green)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let selectedPage {
                        pageHeader(selectedPage)
                        pageContent(selectedPage)
                    } else {
                        sectionIndex
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Computer Use")
        .task {
            await workbench.refreshApps()
            await workbench.refreshDoctor()
        }
        .onChange(of: workbench.selectedAppIdentity) { _, _ in
            Task { await workbench.refreshWindows() }
        }
    }

    @ViewBuilder
    private func pageContent(_ page: DevComputerUsePage) -> some View {
        switch page {
        case .target:
            targetSection
        case .state:
            stateSection
        case .elementClick:
            elementClickSection
        case .coordinates:
            coordinateSection
        case .coordinateReliability:
            coordinateReliabilitySection
        case .keyboard:
            keyboardSection
        case .activeAppIndicator:
            activeAppIndicatorSection
        case .listApps:
            listAppsSection
        case .doctor:
            doctorSection
        }
    }

    private var sectionIndex: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sections")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(DevComputerUsePage.allCases) { page in
                    Button {
                        selectedPage = page
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: page.systemImage)
                                .frame(width: 18)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(page.title)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 44)
                        .padding(.horizontal, 10)
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.secondary.opacity(0.12))
                    )
                }
            }
        }
    }

    private func pageHeader(_ page: DevComputerUsePage) -> some View {
        HStack(spacing: 8) {
            Button {
                selectedPage = nil
            } label: {
                Label("Sections", systemImage: "chevron.left")
            }
            Divider()
                .frame(height: 18)
            Label(page.title, systemImage: page.systemImage)
                .font(.headline)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("computerUse.*")
                .font(.headline.monospaced())
            Spacer()
            if workbench.isRunning {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                Task {
                    await workbench.refreshApps()
                    await workbench.refreshDoctor()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(workbench.isRunning)
        }
    }

    private var listAppsSection: some View {
        devGroup("List Apps") {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("computerUse.listApps")
                    .font(.subheadline.monospaced())
                Picker("Mode", selection: $workbench.appListMode) {
                    Text("running").tag(AppListMode.running)
                    Text("all").tag(AppListMode.all)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                Spacer()
                Button {
                    Task { await workbench.refreshApps() }
                } label: {
                    Label("List Apps", systemImage: "square.grid.2x2")
                }
                .disabled(workbench.isRunning)
            }

            resultBlock(workbench.appListSummary)
        }
    }

    private var targetSection: some View {
        devGroup("Target Selection") {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Picker("App", selection: $workbench.selectedAppIdentity) {
                    Text("Select app").tag(Optional<String>.none)
                    ForEach(workbench.apps, id: \.identity) { app in
                        Text(appLabel(app)).tag(Optional(app.identity))
                    }
                }
                .frame(maxWidth: 460)
                .disabled(workbench.isRunning)

                Button {
                    Task { await workbench.refreshWindows() }
                } label: {
                    Label("List Windows", systemImage: "macwindow")
                }
                .disabled(workbench.selectedPid == nil || workbench.isRunning)
            }

            Picker("Window", selection: $workbench.selectedWindowId) {
                Text("Select window").tag(Optional<CGWindowID>.none)
                ForEach(workbench.windows) { row in
                    Text(windowLabel(row)).tag(Optional(row.id))
                }
            }
            .frame(maxWidth: 520)
            .disabled(workbench.windows.isEmpty)

            resultBlock(workbench.enumerationSummary)
        }
    }

    private var stateSection: some View {
        devGroup("State") {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Picker("Capture", selection: $workbench.captureMode) {
                    Text("som").tag(CaptureMode.som)
                    Text("vision").tag(CaptureMode.vision)
                    Text("ax").tag(CaptureMode.ax)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)

                TextField("Max image dimension", text: $workbench.maxImageDimension)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)

                Button {
                    Task { await workbench.getAppState() }
                } label: {
                    Label("Get App State", systemImage: "camera.viewfinder")
                }
                .disabled(!workbench.hasTarget || workbench.isRunning)
            }

            if let summary = workbench.stateSummary {
                resultBlock(summary)
            }

            if let shot = workbench.screenshotImage {
                Image(nsImage: shot)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.secondary.opacity(0.25))
                    )
                    .accessibilityLabel("Latest Computer Use screenshot")
            }

            if let tree = workbench.axTree {
                codeBlock(tree, maxHeight: 260)
            }
        }
    }

    private var elementClickSection: some View {
        devGroup("Element Click") {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                TextField("Element index", text: $workbench.elementIndex)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                TextField("AX action", text: $workbench.axAction)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                Button {
                    Task { await workbench.clickElement() }
                } label: {
                    Label("Click Element", systemImage: "cursorarrow.click")
                }
                .disabled(!workbench.canClickElement || workbench.isRunning)
            }
        }
    }

    private var coordinateSection: some View {
        devGroup("Coordinates") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    coordFields(x: $workbench.x, y: $workbench.y)
                    Stepper("Count \(workbench.clickCount)", value: $workbench.clickCount, in: 1...3)
                        .frame(width: 120)
                    TextField("Modifiers", text: $workbench.modifiers)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    Button {
                        Task { await workbench.clickAt() }
                    } label: {
                        Label("Click At", systemImage: "scope")
                    }
                    .disabled(!workbench.hasTarget || workbench.isRunning)
                }

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    coordFields(x: $workbench.scrollX, y: $workbench.scrollY)
                    TextField("dx", text: $workbench.scrollDX)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                    TextField("dy", text: $workbench.scrollDY)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                    Button {
                        Task { await workbench.scroll() }
                    } label: {
                        Label("Scroll", systemImage: "scroll")
                    }
                    .disabled(!workbench.hasTarget || workbench.isRunning)
                }

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    TextField("From x", text: $workbench.dragFromX)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 86)
                    TextField("From y", text: $workbench.dragFromY)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 86)
                    TextField("To x", text: $workbench.dragToX)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 86)
                    TextField("To y", text: $workbench.dragToY)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 86)
                    Button {
                        Task { await workbench.drag() }
                    } label: {
                        Label("Drag", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .disabled(!workbench.hasTarget || workbench.isRunning)
                }
            }
        }
    }

    private var coordinateReliabilitySection: some View {
        devGroup("Coordinate Reliability") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Button {
                        Task { await workbench.openCoordinateReliabilityTarget() }
                    } label: {
                        Label("Open Target", systemImage: "scope")
                    }
                    .disabled(workbench.isRunning)

                    TextField("Tolerance pt", text: $workbench.coordinateReliabilityTolerance)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)

                    Button {
                        Task { await workbench.runCoordinateReliabilityClicks() }
                    } label: {
                        Label("Run Clicks", systemImage: "cursorarrow.click.2")
                    }
                    .disabled(!workbench.hasTarget || workbench.isRunning)

                    Button {
                        Task { await workbench.clearCoordinateReliabilityTarget() }
                    } label: {
                        Label("Clear", systemImage: "eraser")
                    }
                    .disabled(workbench.isRunning)

                    if let summary = workbench.coordinateReliabilitySummary {
                        Text(summary)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                TextEditor(text: $workbench.coordinateReliabilityScript)
                    .font(.caption.monospaced())
                    .frame(minHeight: 96)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.secondary.opacity(0.20))
                    )
                    .accessibilityLabel("Coordinate reliability input")

                if !workbench.coordinateReliabilityResults.isEmpty {
                    coordinateReliabilityResults
                }
            }
        }
    }

    private var coordinateReliabilityResults: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("#")
                Text("Expected")
                Text("Actual")
                Text("Delta")
                Text("Distance")
                Text("Result")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            ForEach(workbench.coordinateReliabilityResults) { result in
                GridRow {
                    Text("\(result.index)")
                    Text(pointLabel(result.expected))
                    Text(pointLabel(result.actual))
                    Text(sizeLabel(result.delta))
                    Text(String(format: "%.2f pt", result.distance))
                    Label(result.passed ? "pass" : "fail", systemImage: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.passed ? .green : .red)
                }
                .font(.caption.monospaced())
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var keyboardSection: some View {
        devGroup("Keyboard") {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                TextField("Text", text: $workbench.textToType)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Button {
                    Task { await workbench.typeText() }
                } label: {
                    Label("Type Text", systemImage: "text.cursor")
                }
                .disabled(!workbench.hasTarget || workbench.isRunning)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                TextField("Key", text: $workbench.key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                TextField("Modifiers", text: $workbench.keyModifiers)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Button {
                    Task { await workbench.pressKey() }
                } label: {
                    Label("Press Key", systemImage: "keyboard")
                }
                .disabled(!workbench.hasTarget || workbench.isRunning)
            }
        }
    }

    private var activeAppIndicatorSection: some View {
        devGroup("Active App Indicator") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Button {
                        Task { await workbench.showActiveAppUseIndicator() }
                    } label: {
                        Label("Show", systemImage: "eye")
                    }
                    .disabled(!workbench.hasTarget || workbench.isRunning)

                    Button {
                        Task { await workbench.closeActiveAppUseIndicator() }
                    } label: {
                        Label("Close", systemImage: "xmark.circle")
                    }
                    .disabled(workbench.isRunning)

                    if let summary = workbench.activeAppUseIndicatorSummary {
                        Text(summary)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                resultBlock(workbench.enumerationSummary)
            }
        }
    }

    private var doctorSection: some View {
        devGroup("Doctor") {
            HStack(spacing: 8) {
                Text("computerUse.doctor")
                    .font(.subheadline.monospaced())
                if let at = workbench.doctorService.lastRefreshedAt {
                    Text(timestamp(at))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button {
                    Task { await workbench.refreshDoctor() }
                } label: {
                    Label("Re-run", systemImage: "stethoscope")
                }
                .disabled(workbench.doctorService.isRefreshing)
            }
            if let report = workbench.doctorService.lastReport {
                checklistGroup(
                    title: "Permissions",
                    rows: [
                        ("Accessibility", report.accessibility),
                        ("Screen Recording", report.screenRecording),
                        ("Automation", report.automation),
                    ]
                )
                checklistGroup(
                    title: "SkyLight Private SPI",
                    rows: [
                        ("SLEventPostToPid", report.skyLightSPI.postToPid),
                        ("Authentication message envelope", report.skyLightSPI.authMessage),
                        ("Focus without raise", report.skyLightSPI.focusWithoutRaise),
                        ("Window-local CGEvent location", report.skyLightSPI.windowLocation),
                        ("Spaces enumeration", report.skyLightSPI.spaces),
                        ("_AXUIElementGetWindow", report.skyLightSPI.getWindow),
                    ]
                )
            } else if workbench.doctorService.isRefreshing {
                ProgressView("Probing...")
                    .controlSize(.small)
            }
        }
    }

    private func coordFields(x: Binding<String>, y: Binding<String>) -> some View {
        Group {
            TextField("x", text: x)
                .textFieldStyle(.roundedBorder)
                .frame(width: 86)
            TextField("y", text: y)
                .textFieldStyle(.roundedBorder)
                .frame(width: 86)
        }
    }

    private func devGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
    }

    private func statusBanner(_ message: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .accessibilityElement(children: .combine)
    }

    private func resultBlock(_ value: String) -> some View {
        codeBlock(value, maxHeight: 120)
    }

    private func codeBlock(_ value: String, maxHeight: CGFloat) -> some View {
        ScrollView {
            Text(value.isEmpty ? "-" : value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: maxHeight)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.08))
        )
    }

    private func checklistGroup(title: String, rows: [(String, Bool)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    Image(systemName: row.1 ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(row.1 ? .green : .red)
                        .accessibilityHidden(true)
                    Text(row.0)
                        .font(.caption.monospaced())
                    Spacer()
                    Text(row.1 ? "pass" : "fail")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func appLabel(_ app: AppInfo) -> String {
        let state = app.running ? "pid=\(app.pid.map(String.init) ?? "-")" : "not running"
        return "\(app.active ? "* " : "")\(app.name) \(state)"
    }

    private func windowLabel(_ row: DevComputerUseWindowRow) -> String {
        let title = row.title.isEmpty ? "(untitled)" : row.title
        let space = row.onCurrentSpace ? "current" : "off-space"
        return "\(title) id=\(row.id) \(space)"
    }

    private func timestamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    private func pointLabel(_ point: CGPoint) -> String {
        if !point.x.isFinite || !point.y.isFinite { return "-" }
        return "\(String(format: "%.1f", point.x)), \(String(format: "%.1f", point.y))"
    }

    private func sizeLabel(_ size: CGSize) -> String {
        if !size.width.isFinite || !size.height.isFinite { return "-" }
        return "\(String(format: "%+.1f", size.width)), \(String(format: "%+.1f", size.height))"
    }
}
