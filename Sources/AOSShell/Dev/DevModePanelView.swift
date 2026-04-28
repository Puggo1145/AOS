import SwiftUI
import AOSRPCSchema
import AOSComputerUseKit

// MARK: - DevModePanelView
//
// Standalone Dev Mode window content. The panel is split into a sidebar of
// sections and a detail area. Stage 0 ships a single section ("Context");
// the layout is built so adding more sections later is a one-row edit to
// `Section.allCases`.

struct DevModePanelView: View {
    let contextService: DevContextService
    var sessionStore: SessionStore?
    var doctorService: ComputerUseDoctorService?

    @State private var selected: Section = .context

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case context = "Context"
        case computerUse = "Computer Use"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selected) { section in
                Label(section.rawValue, systemImage: icon(for: section))
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            switch selected {
            case .context:
                DevContextSectionView(service: contextService, sessionStore: sessionStore)
            case .computerUse:
                if let doctorService {
                    DevComputerUseSectionView(service: doctorService)
                } else {
                    ContentUnavailableView(
                        "Computer Use unavailable",
                        systemImage: "stethoscope",
                        description: Text("Doctor service was not wired into Dev Mode at boot.")
                    )
                }
            }
        }
        .task {
            // Hydrate when the window opens so the panel is not empty between
            // turns. Subsequent updates flow over `dev.context.changed`.
            await contextService.refresh()
        }
    }

    private func icon(for section: Section) -> String {
        switch section {
        case .context: return "doc.text"
        case .computerUse: return "stethoscope"
        }
    }
}

// MARK: - DevComputerUseSectionView
//
// Renders the cached `DoctorReport` as a checklist (Accessibility / Screen
// Recording / each SkyLight SPI), plus a "Re-run" button that re-probes
// in-process. The section auto-runs once on first appear so opening Dev Mode
// after a Privacy toggle gives an up-to-date read without a manual click.

struct DevComputerUseSectionView: View {
    let service: ComputerUseDoctorService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            if let report = service.lastReport {
                reportBody(report)
            } else if service.isRefreshing {
                ProgressView("Probing…")
                    .controlSize(.small)
            } else {
                ContentUnavailableView(
                    "No report yet",
                    systemImage: "stethoscope",
                    description: Text("Click Re-run to probe accessibility, screen recording, and SkyLight SPI status.")
                )
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Computer Use")
        .task {
            // First-open hydrate: re-run regardless of cache, so the panel
            // always reflects current TCC state when the dev opens it.
            await service.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("computerUse.doctor")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
            if let at = service.lastRefreshedAt {
                Text(timestamp(at))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button {
                Task { await service.refresh() }
            } label: {
                if service.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Re-run", systemImage: "arrow.clockwise")
                }
            }
            .disabled(service.isRefreshing)
        }
    }

    @ViewBuilder
    private func reportBody(_ r: DoctorReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            checklistGroup(
                title: "Permissions",
                rows: [
                    ("Accessibility", r.accessibility),
                    ("Screen Recording", r.screenRecording),
                    ("Automation", r.automation),
                ]
            )
            checklistGroup(
                title: "SkyLight Private SPI",
                rows: [
                    ("SLEventPostToPid", r.skyLightSPI.postToPid),
                    ("Authentication message envelope", r.skyLightSPI.authMessage),
                    ("Focus without raise (yabai)", r.skyLightSPI.focusWithoutRaise),
                    ("Window-local CGEvent location", r.skyLightSPI.windowLocation),
                    ("Spaces enumeration", r.skyLightSPI.spaces),
                    ("_AXUIElementGetWindow", r.skyLightSPI.getWindow),
                ]
            )
        }
    }

    private func checklistGroup(title: String, rows: [(String, Bool)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        Image(systemName: row.1 ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(row.1 ? .green : .red)
                        Text(row.0)
                            .font(.system(size: 12, design: .monospaced))
                        Spacer()
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
    }

    private func timestamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}

// MARK: - DevContextSectionView
//
// Renders the latest LLM context snapshot as monospace text — the wire
// payload as the model sees it. Auto-scrolls to top on each new snapshot
// so an active turn is read from the beginning rather than wherever the
// previous scroll position landed.

struct DevContextSectionView: View {
    let service: DevContextService
    /// Optional — when present, lets the header render a badge indicating
    /// whether the snapshot's session is the one the user is currently
    /// looking at. Per design, Dev Mode shows global latest; the badge is
    /// purely informational.
    var sessionStore: SessionStore?

    var body: some View {
        Group {
            if let snap = service.snapshot {
                snapshotView(snap, error: service.lastError)
            } else if let err = service.lastError {
                // No snapshot AND the refresh failed: surface the wire-level
                // failure explicitly so Dev Mode reports its own brokenness
                // instead of pretending the agent is just idle.
                ContentUnavailableView {
                    Label("Refresh failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(err)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                } actions: {
                    Button("Retry") { Task { await service.refresh() } }
                }
            } else {
                ContentUnavailableView(
                    "No context yet",
                    systemImage: "tray",
                    description: Text("Submit a prompt — the next turn's payload will appear here.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Context")
    }

    @ViewBuilder
    private func snapshotView(_ snap: DevContextSnapshot, error: String?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(snap)
                if let error {
                    // Snapshot exists but the most recent refresh failed —
                    // tell the user the data may be stale.
                    refreshErrorBanner(error)
                }
                Divider()
                section(title: "System Prompt", body: snap.systemPrompt)
                DevMessagesView(messagesJson: snap.messagesJson)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(snap.capturedAt)
    }

    private func refreshErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Refresh failed — snapshot below may be stale.")
                    .font(.system(size: 11, weight: .semibold))
                Text(message)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.yellow.opacity(0.10))
        )
    }

    private func header(_ snap: DevContextSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(snap.providerId) / \(snap.modelId)")
                    .font(.system(size: 12, weight: .semibold))
                if let effort = snap.effort {
                    Text("effort: \(effort)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(timestamp(snap.capturedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 6) {
                Text("session: \(snap.sessionId)")
                Text(activeBadge(for: snap.sessionId))
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(isActive(snap.sessionId) ? Color.green.opacity(0.18) : Color.gray.opacity(0.18))
                    )
                Spacer()
                Text("turn: \(snap.turnId)")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
    }

    /// Per docs/designs/session-management.md: Dev Mode shows the *global
    /// latest* LLM input. The active badge surfaces whether that input came
    /// from the currently-foregrounded session or a background one.
    private func isActive(_ sessionId: String) -> Bool {
        sessionStore?.activeId == sessionId
    }

    private func activeBadge(for sessionId: String) -> String {
        isActive(sessionId) ? "active" : "background"
    }

    private func section(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(body.isEmpty ? "—" : body)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )
        }
    }

    private func timestamp(_ msSinceEpoch: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(msSinceEpoch) / 1000)
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: date)
    }
}
