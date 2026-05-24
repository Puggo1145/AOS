import RPCSchema
import SwiftUI

// MARK: - PermissionApprovalCard
//
// Inline permission decision surface rendered inside the notch panel while
// the sidecar is blocked on `permission.requestApproval`.
struct PermissionApprovalCard: View {
    let request: PermissionRequestApprovalParams
    let allow: () -> Void
    let deny: () -> Void
    var fillsAvailableHeight: Bool = false

    var body: some View {
        if fillsAvailableHeight {
            VStack(alignment: .leading, spacing: 8) {
                requestSummary
                Spacer(minLength: 8)
                actionRow
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .contain)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                requestSummary
                actionRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
        }
    }

    private var requestSummary: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: request.risk == .high ? "exclamationmark.triangle.fill" : "lock.fill")
                .notchFont(size: 12, weight: .semibold, relativeTo: .caption)
                .foregroundStyle(request.risk == .high ? Color.yellow.opacity(0.95) : Color.white.opacity(0.75))
                .accessibilityHidden(true)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(request.title)
                    .notchFont(size: 13, weight: .semibold)
                    .notchForeground(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(request.message)
                    .notchFont(size: 12, relativeTo: .caption)
                    .notchForeground(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let capability = request.capabilities.first {
                    Text(capabilityLine(capability))
                        .notchFont(size: 11, relativeTo: .caption)
                        .notchForeground(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button(action: deny) {
                Text("Deny")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.notchPressable)
            .notchFont(size: 12, weight: .semibold, relativeTo: .caption)
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.gray.opacity(0.42))
            )
            .accessibilityLabel(Text("Deny permission request"))

            Button(action: allow) {
                Text("Allow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.notchPressable)
            .notchFont(size: 12, weight: .semibold, relativeTo: .caption)
            .foregroundStyle(Color.white)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.blue)
            )
            .accessibilityLabel(Text("Allow permission request"))
        }
    }

    private func capabilityLine(_ capability: PermissionCapabilityView) -> String {
        guard let target = capability.target, !target.isEmpty else {
            return capability.action
        }
        return "\(capability.action): \(target)"
    }
}
