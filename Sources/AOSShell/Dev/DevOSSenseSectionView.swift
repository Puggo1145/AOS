import SwiftUI
import AOSOSSenseKit

// MARK: - DevOSSenseSectionView
//
// Live diagnostic mirror for OS Sense. This view observes the same
// SenseStore instance as the Notch UI, so app/window/behavior/permission
// changes appear here without RPC fan-out or copied state.

struct DevOSSenseSectionView: View {
    let senseStore: SenseStore

    private var snapshot: DevOSSenseSnapshot {
        DevOSSenseSnapshot(context: senseStore.context)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(snapshot)
                identitySection(snapshot)
                behaviorsSection(snapshot.behaviors)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("OS Sense")
    }

    private func header(_ snapshot: DevOSSenseSnapshot) -> some View {
        HStack(spacing: 8) {
            Text("SenseStore.context")
                .font(.headline.monospaced())
            Spacer()
            Text(timestamp(snapshot.capturedAt))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func identitySection(_ snapshot: DevOSSenseSnapshot) -> some View {
        devGroup("Live Context") {
            keyValueRow("App", snapshot.appLine)
            keyValueRow("Window", snapshot.windowLine)
            keyValueRow("Permissions", snapshot.permissionsLine)
        }
    }

    @ViewBuilder
    private func behaviorsSection(_ behaviors: [DevOSSenseSnapshot.Behavior]) -> some View {
        devGroup("Behaviors") {
            if behaviors.isEmpty {
                Text("No behaviors")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(behaviors) { behavior in
                    behaviorBlock(behavior)
                }
            }
        }
    }

    private func behaviorBlock(_ behavior: DevOSSenseSnapshot.Behavior) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(behavior.kind)
                    .font(.subheadline.monospaced())
                    .textSelection(.enabled)
                Text(behavior.citationKey)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
            }
            Text(behavior.displaySummary)
                .font(.body)
                .textSelection(.enabled)
            codeBlock(behavior.payloadText, maxHeight: 180)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .accessibilityElement(children: .contain)
    }

    private func keyValueRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
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
            Text(value)
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

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}
