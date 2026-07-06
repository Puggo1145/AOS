import SwiftUI
import OSSenseKit

// MARK: - SettingsPermissionsPage

struct SettingsPermissionsPage: View {
    let flow: SettingsFlowModel
    let topSafeInset: CGFloat

    var body: some View {
        SettingsPickerPageChrome(title: "Permissions", topSafeInset: topSafeInset, onBack: { flow.pop() }) {
            VStack(spacing: 8) {
                ForEach(Permission.settingsDisplayOrder, id: \.self) { p in
                    PermissionStatusRow(
                        permission: p,
                        status: flow.permissionStatus(for: p),
                        onOpenSettings: {
                            flow.handlePermissionSettingsAction(p)
                        }
                    )
                }
                if let permissionRequestError = flow.permissionRequestError {
                    NotchErrorText(permissionRequestError)
                }
            }
        }
    }
}
