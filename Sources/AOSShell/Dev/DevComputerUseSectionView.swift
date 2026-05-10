import AppKit
import AOSComputerUseKit
import SwiftUI

// MARK: - DevComputerUseSectionView
//
// Local-only diagnostic surface for the remaining Computer Use foundation.
// It intentionally does not register RPC handlers or agent tools; Dev Mode
// can inspect apps, windows, AX trees, and screenshots without restoring the
// removed app-operation stack.

struct DevComputerUseSectionView: View {
    let service: ComputerUseService

    @State private var apps: [AppInfo] = []
    @State private var windows: [WindowInfo] = []
    @State private var selectedAppIdentity: String?
    @State private var selectedWindowId: CGWindowID?
    @State private var captureMode: CaptureMode = .som
    @State private var maxImageDimension: Int = 1024
    @State private var stateSnapshot: DevComputerUseStateSnapshot?
    @State private var screenshotImage: NSImage?
    @State private var errorMessage: String?
    @State private var isRefreshingApps = false
    @State private var isRefreshingWindows = false
    @State private var isCapturingState = false

    private var snapshot: DevComputerUseSnapshot {
        DevComputerUseSnapshot(apps: apps, windows: windows, state: stateSnapshot)
    }

    private var selectedApp: AppInfo? {
        guard let selectedAppIdentity else { return nil }
        return apps.first { $0.identity == selectedAppIdentity }
    }

    private var selectedWindow: WindowInfo? {
        guard let selectedWindowId else { return nil }
        return windows.first { $0.id == selectedWindowId }
    }

    var body: some View {
        HSplitView {
            leftPane
                .frame(minWidth: 250, idealWidth: 300)
            detailPane
                .frame(minWidth: 420)
        }
        .navigationTitle("Computer Use")
        .task {
            await refreshApps()
        }
        .onChange(of: selectedAppIdentity) { _, _ in
            Task { await refreshWindowsForSelection() }
        }
    }

    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(snapshot.appCountLine)
                    .font(.headline)
                Spacer()
                Button {
                    Task { await refreshApps() }
                } label: {
                    Image(systemName: isRefreshingApps ? "arrow.clockwise.circle" : "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh running apps")
                .disabled(isRefreshingApps)
            }

            List(apps, id: \.identity, selection: $selectedAppIdentity) { app in
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .lineLimit(1)
                    Text(DevComputerUseSnapshot.appLine(app))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .tag(app.identity)
            }
            .listStyle(.sidebar)
        }
        .padding(12)
    }

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let errorMessage {
                    errorBanner(errorMessage)
                }
                windowsSection
                captureSection
                stateSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Foundation diagnostics")
                .font(.headline)
            Text("Apps, windows, AX snapshots, and ScreenCaptureKit screenshots from the local Swift service.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var windowsSection: some View {
        devGroup("Windows") {
            HStack {
                Text(snapshot.windowCountLine)
                    .font(.subheadline.monospaced())
                Spacer()
                Button {
                    Task { await refreshWindowsForSelection() }
                } label: {
                    Image(systemName: isRefreshingWindows ? "arrow.clockwise.circle" : "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh windows")
                .disabled(selectedApp == nil || isRefreshingWindows)
            }

            if selectedApp == nil {
                emptyLine("Select a running app")
            } else if windows.isEmpty {
                emptyLine("No layer-0 windows")
            } else {
                Picker("Window", selection: $selectedWindowId) {
                    ForEach(windows, id: \.id) { window in
                        Text(DevComputerUseSnapshot.windowLine(window))
                            .tag(Optional(window.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)

                if let selectedWindow {
                    Text(DevComputerUseSnapshot.windowDetailLine(selectedWindow))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var captureSection: some View {
        devGroup("Get App State") {
            Picker("Mode", selection: $captureMode) {
                ForEach(CaptureMode.devCases, id: \.self) { mode in
                    Text(mode.rawValue.uppercased()).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                Text("Max image dimension")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(value: $maxImageDimension, in: 256...2048, step: 256) {
                    Text("\(maxImageDimension)")
                        .font(.caption.monospacedDigit())
                }
                .frame(width: 140)
                Spacer()
                Button {
                    Task { await captureState() }
                } label: {
                    Label(isCapturingState ? "Capturing" : "Capture", systemImage: "camera.viewfinder")
                }
                .disabled(selectedApp?.pid == nil || selectedWindowId == nil || isCapturingState)
            }
        }
    }

    @ViewBuilder
    private var stateSection: some View {
        if let state = stateSnapshot {
            devGroup("State") {
                keyValueRow("App", state.identityLine)
                keyValueRow("AX", state.axLine)
                if let screenshot = state.screenshot {
                    keyValueRow("Screenshot", screenshot.line)
                } else {
                    keyValueRow("Screenshot", "No screenshot")
                }
                if let screenshotImage {
                    Image(nsImage: screenshotImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                        )
                }
                if let tree = state.treeMarkdown {
                    codeBlock(tree, maxHeight: 360)
                } else {
                    emptyLine("No AX tree")
                }
            }
        }
    }

    private func refreshApps() async {
        isRefreshingApps = true
        defer { isRefreshingApps = false }
        errorMessage = nil

        let loaded = await service.listApps(mode: .running)
            .sorted { lhs, rhs in
                if lhs.active != rhs.active { return lhs.active && !rhs.active }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        apps = loaded

        if selectedAppIdentity == nil || !loaded.contains(where: { $0.identity == selectedAppIdentity }) {
            selectedAppIdentity = loaded.first?.identity
        } else {
            await refreshWindowsForSelection()
        }
    }

    private func refreshWindowsForSelection() async {
        guard let pid = selectedApp?.pid else {
            windows = []
            selectedWindowId = nil
            return
        }

        isRefreshingWindows = true
        defer { isRefreshingWindows = false }
        errorMessage = nil

        let loaded = await service.listWindows(pid: pid)
            .sorted { lhs, rhs in
                if lhs.isOnScreen != rhs.isOnScreen { return lhs.isOnScreen && !rhs.isOnScreen }
                return lhs.zIndex > rhs.zIndex
            }
        windows = loaded

        if selectedWindowId == nil || !loaded.contains(where: { $0.id == selectedWindowId }) {
            selectedWindowId = loaded.first?.id
        }
    }

    private func captureState() async {
        guard let pid = selectedApp?.pid, let windowId = selectedWindowId else { return }

        isCapturingState = true
        defer { isCapturingState = false }
        errorMessage = nil

        do {
            let bundle = try await service.getAppState(
                pid: pid,
                windowId: windowId,
                captureMode: captureMode,
                maxImageDimension: maxImageDimension
            )
            stateSnapshot = DevComputerUseStateSnapshot(bundle: bundle)
            screenshotImage = bundle.screenshot.flatMap { NSImage(data: $0.imageData) }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.yellow.opacity(0.10))
        )
    }

    private func keyValueRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.body.monospaced())
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.secondary)
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

    private func codeBlock(_ value: String, maxHeight: CGFloat) -> some View {
        ScrollView {
            Text(value.isEmpty ? "—" : value)
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
}

private extension CaptureMode {
    static let devCases: [CaptureMode] = [.som, .vision, .ax]
}
