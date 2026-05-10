import Foundation

// MARK: - AOSComputerUseKit
//
// Remaining Computer Use foundation. This package intentionally contains no
// app-operation stack: no focus suppression, event input, visual cursor, or
// Shell RPC handlers. Rebuild those layers explicitly on top of this clean
// app/window/snapshot/capture base.

public enum AOSComputerUseKit {
    public static let moduleName: String = "AOSComputerUseKit"
}
