import Foundation

/// Mouse-event delivery route selected for a target process.
enum BackgroundMouseEventDeliveryRoute: Sendable, Equatable {
    case appKit
    case webContent

    var appType: AppType {
        switch self {
        case .appKit:
            return .appKit
        case .webContent:
            return .webContent
        }
    }
}

extension BackgroundMouseEventDeliveryRoute {
    func supports(_ event: BackgroundMouseEvent) -> Bool {
        switch (self, event) {
        case (.appKit, .click), (.webContent, _):
            return true
        case (.appKit, .drag):
            return false
        }
    }
}

struct BackgroundMouseEventDeliveryClassification: Sendable, Equatable {
    let route: BackgroundMouseEventDeliveryRoute
    let reason: AppTypeReason
}

/// Classifies targets that need the web-content SkyLight mouse delivery recipe.
struct BackgroundMouseEventDeliveryClassifier: Sendable {
    typealias FileExists = @Sendable (String) -> Bool
    typealias ContainsChromiumRuntimeResources = @Sendable (URL) -> Bool

    private let fileExists: FileExists
    private let containsChromiumRuntimeResources: ContainsChromiumRuntimeResources

    init(
        fileExists: @escaping FileExists = { FileManager.default.fileExists(atPath: $0) },
        containsChromiumRuntimeResources: @escaping ContainsChromiumRuntimeResources = {
            Self.bundleContainsChromiumRuntimeResources(bundleURL: $0)
        }
    ) {
        self.fileExists = fileExists
        self.containsChromiumRuntimeResources = containsChromiumRuntimeResources
    }

    func deliveryRoute(
        bundleIdentifier: String?,
        bundleURL: URL?
    ) -> BackgroundMouseEventDeliveryRoute {
        classification(bundleIdentifier: bundleIdentifier, bundleURL: bundleURL).route
    }

    func classification(
        bundleIdentifier: String?,
        bundleURL: URL?
    ) -> BackgroundMouseEventDeliveryClassification {
        if let bundleURL {
            let electronFrameworkPath = bundleURL
                .appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
                .path
            if fileExists(electronFrameworkPath) {
                return BackgroundMouseEventDeliveryClassification(route: .webContent, reason: .electronFramework)
            }

            let chromiumEmbeddedFrameworkPath = bundleURL
                .appendingPathComponent("Contents/Frameworks/Chromium Embedded Framework.framework")
                .path
            if fileExists(chromiumEmbeddedFrameworkPath) {
                return BackgroundMouseEventDeliveryClassification(route: .webContent, reason: .chromiumEmbeddedFramework)
            }

            if containsChromiumRuntimeResources(bundleURL) {
                return BackgroundMouseEventDeliveryClassification(route: .webContent, reason: .chromiumRuntimeResources)
            }
        }

        if bundleIdentifier == "com.apple.Safari" {
            return BackgroundMouseEventDeliveryClassification(route: .webContent, reason: .safariBundleId)
        }

        if let bundleIdentifier,
           Self.chromiumFamilyBundleIdentifiers.contains(bundleIdentifier)
        {
            return BackgroundMouseEventDeliveryClassification(route: .webContent, reason: .chromiumBrowserBundleId)
        }

        if let bundleIdentifier,
           Self.knownElectronBundleIdentifiers.contains(bundleIdentifier)
        {
            return BackgroundMouseEventDeliveryClassification(route: .webContent, reason: .knownElectronBundleId)
        }

        return BackgroundMouseEventDeliveryClassification(route: .appKit, reason: .appKitDefault)
    }

    private static let chromiumFamilyBundleIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    private static let knownElectronBundleIdentifiers: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.discordapp.Discord",
        "notion.id",
        "com.figma.Desktop",
        "com.tencent.qq",
    ]

    private static let chromiumRuntimeResourceMarkers: Set<String> = [
        "chrome_100_percent.pak",
        "chrome_200_percent.pak",
        "icudtl.dat",
        "resources.pak",
        "v8_context_snapshot.arm64.bin",
        "v8_context_snapshot.x86_64.bin",
    ]

    private static func bundleContainsChromiumRuntimeResources(bundleURL: URL) -> Bool {
        let frameworksURL = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: frameworksURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        var matchedMarkers: Set<String> = []
        for case let url as URL in enumerator {
            let marker = url.lastPathComponent
            guard chromiumRuntimeResourceMarkers.contains(marker) else {
                continue
            }
            matchedMarkers.insert(marker)
            if matchedMarkers.count >= 3 {
                return true
            }
        }
        return false
    }
}
