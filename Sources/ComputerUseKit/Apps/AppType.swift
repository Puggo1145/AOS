import Darwin
import Foundation

/// Notch Agent's current mouse-delivery classification for a running app.
public enum AppType: String, Sendable, Codable, Equatable {
    case appKit
    case webContent
}

/// Why Notch Agent chose an app type classification.
public enum AppTypeReason: String, Sendable, Codable, Equatable {
    case electronFramework
    case chromiumEmbeddedFramework
    case chromiumRuntimeResources
    case chromiumBrowserBundleId
    case safariBundleId
    case knownElectronBundleId
    case appKitDefault
}

/// Diagnostic result describing how Notch Agent classifies a pid for app operations.
public struct AppTypeResult: Sendable, Codable, Equatable {
    public let pid: pid_t
    public let appName: String?
    public let bundleId: String?
    public let bundlePath: String?
    public let type: AppType
    public let reason: AppTypeReason

    public init(
        pid: pid_t,
        appName: String?,
        bundleId: String?,
        bundlePath: String?,
        type: AppType,
        reason: AppTypeReason
    ) {
        self.pid = pid
        self.appName = appName
        self.bundleId = bundleId
        self.bundlePath = bundlePath
        self.type = type
        self.reason = reason
    }
}
