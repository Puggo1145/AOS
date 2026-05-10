import SwiftUI
import AOSComputerUseKit
import AOSRPCSchema
import AOSOSSenseKit

// MARK: - DevModePanelView
//
// Standalone Dev Mode window content. The panel is split into a sidebar of
// diagnostic sections and a detail area; each section observes its own
// production service/store rather than a copied debug mirror.

struct DevModePanelView: View {
    let contextService: DevContextService
    let senseStore: SenseStore
    let computerUseService: ComputerUseService
    var sessionStore: SessionStore?

    @State private var selected: Section = .context

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case context = "Context"
        case osSense = "OS Sense"
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
            case .osSense:
                DevOSSenseSectionView(senseStore: senseStore)
            case .computerUse:
                DevComputerUseSectionView(service: computerUseService)
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
        case .osSense: return "eye"
        case .computerUse: return "macwindow"
        }
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

    @State private var messagesShowRaw: Bool = false

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
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(snap)
                        .id("snapshot-top")
                    if let error {
                        refreshErrorBanner(error)
                    }
                    Divider()
                    section(title: "System Prompt", body: snap.systemPrompt)
                    DevMessagesView(messagesJson: snap.messagesJson, showRaw: $messagesShowRaw)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: snap.turnId) { _, _ in
                proxy.scrollTo("snapshot-top", anchor: .top)
            }
        }
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
