import AOSComputerUseKit
import Foundation

// MARK: - DevComputerUseSnapshot
//
// Formatting-only projection for the Dev Mode Computer Use section. Keeping
// this separate from the SwiftUI view gives tests a deterministic seam while
// the live section still talks directly to `ComputerUseCore`.

struct DevComputerUseSnapshot {
    let apps: [AppInfo]
    let windows: [WindowInfo]
    let state: DevComputerUseStateSnapshot?

    var appCountLine: String {
        "\(apps.count) running app\(apps.count == 1 ? "" : "s")"
    }

    var windowCountLine: String {
        "\(windows.count) window\(windows.count == 1 ? "" : "s")"
    }

    static func appLine(_ app: AppInfo) -> String {
        var chunks: [String] = []
        if let bundleId = app.bundleId {
            chunks.append(bundleId)
        }
        if let pid = app.pid {
            chunks.append("pid \(pid)")
        }
        if app.active {
            chunks.append("active")
        }
        return chunks.isEmpty ? app.name : "\(app.name) (\(chunks.joined(separator: ", ")))"
    }

    static func windowLine(_ window: WindowInfo) -> String {
        let title = window.title.isEmpty ? "Untitled" : window.title
        return "\(title) (#\(window.id), \(Int(window.bounds.width))x\(Int(window.bounds.height)), z \(window.zIndex))"
    }

    static func windowDetailLine(_ window: WindowInfo) -> String {
        "x \(Int(window.bounds.x)), y \(Int(window.bounds.y)), layer \(window.layer), onScreen \(window.isOnScreen)"
    }
}

struct DevComputerUseStateSnapshot {
    let stateId: String
    let appName: String?
    let bundleId: String?
    let elementCount: Int
    let treeMarkdown: String
    let screenshot: DevComputerUseScreenshotSnapshot?

    init(bundle: AppStateBundle) {
        self.stateId = bundle.stateId.raw
        self.appName = bundle.appName
        self.bundleId = bundle.bundleId
        self.elementCount = bundle.elementCount
        self.treeMarkdown = bundle.treeMarkdown
        if let screenshot = bundle.screenshot {
            self.screenshot = DevComputerUseScreenshotSnapshot(screenshot: screenshot)
        } else {
            self.screenshot = nil
        }
    }

    init(
        stateId: String,
        appName: String?,
        bundleId: String?,
        elementCount: Int,
        treeMarkdown: String,
        screenshot: DevComputerUseScreenshotSnapshot?
    ) {
        self.stateId = stateId
        self.appName = appName
        self.bundleId = bundleId
        self.elementCount = elementCount
        self.treeMarkdown = treeMarkdown
        self.screenshot = screenshot
    }

    var identityLine: String {
        let name = appName ?? "Unknown app"
        if let bundleId {
            return "\(name) (\(bundleId))"
        }
        return name
    }

    var axLine: String {
        "state \(stateId), \(elementCount) element\(elementCount == 1 ? "" : "s")"
    }
}

struct DevComputerUseScreenshotSnapshot {
    let width: Int
    let height: Int
    let byteCount: Int
    let format: String
    let originalWidth: Int?
    let originalHeight: Int?

    init(screenshot: Screenshot) {
        self.width = screenshot.width
        self.height = screenshot.height
        self.byteCount = screenshot.imageData.count
        self.format = screenshot.format.rawValue
        self.originalWidth = screenshot.originalWidth
        self.originalHeight = screenshot.originalHeight
    }

    init(
        width: Int,
        height: Int,
        byteCount: Int,
        format: String,
        originalWidth: Int? = nil,
        originalHeight: Int? = nil
    ) {
        self.width = width
        self.height = height
        self.byteCount = byteCount
        self.format = format
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
    }

    var line: String {
        var text = "\(width)x\(height) \(format.uppercased()), \(byteCount) bytes"
        if let originalWidth, let originalHeight {
            text += " (downscaled from \(originalWidth)x\(originalHeight))"
        }
        return text
    }
}
