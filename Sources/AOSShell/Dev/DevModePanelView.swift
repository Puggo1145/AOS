import SwiftUI
import AOSRPCSchema

// MARK: - DevModePanelView
//
// Standalone Dev Mode window content. The panel is split into a sidebar of
// sections and a detail area. Stage 0 ships a single section ("Context");
// the layout is built so adding more sections later is a one-row edit to
// `Section.allCases`.

struct DevModePanelView: View {
    let contextService: DevContextService

    @State private var selected: Section = .context

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case context = "Context"
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
                DevContextSectionView(service: contextService)
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
            Text("turn: \(snap.turnId)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
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
