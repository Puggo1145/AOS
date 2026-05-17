import AppKit
import ComputerUseKit
import CoreGraphics
import SwiftUI

// MARK: - DevComputerUseSectionView
//
// Manual Computer Use probe for Dev Mode. Selecting an app starts a
// pid-scoped session against its frontmost operable window; changing or
// leaving the selection ends the session owned by this panel.

struct DevComputerUseSectionView: View {
    let service: DevComputerUseService

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if let error = service.lastError {
                        errorBanner(error)
                    }
                    appList
                    windowList
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            statePane
        }
        .navigationTitle("Computer Use")
        .task {
            await service.refreshApps()
        }
        .onDisappear {
            Task { await service.clearSelection() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("ComputerUseCore")
                .font(.headline.monospaced())
            Spacer()
            captureModeButton("AX", mode: .ax)
            captureModeButton("Vision", mode: .vision)
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await service.refreshApps() }
            }
        }
    }

    private var appList: some View {
        devGroup("Apps") {
            if service.apps.isEmpty {
                Text("No running apps")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(service.apps, id: \.identity) { app in
                    Button {
                        Task { await service.selectApp(identity: app.identity) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: app.active ? "app.badge.checkmark" : "app")
                                .frame(width: 18)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                    .font(.body)
                                Text(app.bundleId ?? app.path ?? app.identity)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if let pid = app.pid {
                                Text("pid \(pid)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selectionFill(app.identity == service.selectedAppIdentity))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var windowList: some View {
        devGroup("Windows") {
            if service.windows.isEmpty {
                Text("Select a running app")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(service.windows, id: \.id) { window in
                    Button {
                        Task { await service.selectWindow(id: window.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(window.title.isEmpty ? "(untitled)" : window.title)
                                    .font(.body)
                                    .lineLimit(1)
                                Spacer()
                                Text("#\(window.id)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(boundsLine(window.bounds))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selectionFill(window.id == service.selectedWindowId))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var statePane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text("App State")
                        .font(.headline.monospaced())
                    Spacer()
                    Button("Read State", systemImage: "waveform.path.ecg") {
                        Task { await service.refreshState() }
                    }
                    .disabled(service.selectedWindowId == nil)
                }

                if let state = service.appState {
                    stateSummary(state)
                    if let screenshot = state.screenshot,
                       let image = NSImage(data: screenshot.imageData) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 240)
                            .accessibilityLabel("Selected app window screenshot")
                    }
                    codeBlock(state.treeMarkdown, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "No app state",
                        systemImage: "rectangle.and.text.magnifyingglass",
                        description: Text("Select a running app window to start a session and read its AX tree.")
                    )
                }
            }
            .padding(16)
            .frame(minWidth: 360, maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stateSummary(_ state: AppStateBundle) -> some View {
        devGroup("State") {
            keyValueRow("App", state.appName ?? state.bundleId ?? "pid \(state.pid)")
            keyValueRow("State", state.stateId.raw)
            keyValueRow("Elements", "\(state.elementCount)")
            keyValueRow("Screenshot", state.screenshot == nil ? "none" : "captured")
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
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
        .accessibilityElement(children: .combine)
    }

    private func keyValueRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .font(.body.monospaced())
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func devGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 8) {
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

    private func selectionFill(_ selected: Bool) -> some ShapeStyle {
        selected ? Color.accentColor.opacity(0.18) : Color.clear
    }

    private func captureModeButton(_ title: String, mode: CaptureMode) -> some View {
        Button(title) {
            Task { await service.setCaptureMode(mode) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(service.captureMode == mode)
    }

    private func boundsLine(_ bounds: WindowBounds) -> String {
        "x \(Int(bounds.x)) y \(Int(bounds.y)) w \(Int(bounds.width)) h \(Int(bounds.height))"
    }
}
