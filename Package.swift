// swift-tools-version: 5.10
import PackageDescription

// AOS SwiftPM workspace.
//
// Targets:
//   - executable `AOSShell`      (Notch UI + RPC client + AgentService composition root)
//   - executable `AOSComputerUseCLI` (terminal entrypoint for Computer Use core)
//   - library `AOSRPCSchema`     (wire protocol — see docs/plans/rpc-protocol.md)
//   - library `AOSOSSenseKit`    (OS Sense — see docs/designs/os-sense.md)
//   - library `AOSComputerUseKit` (Computer Use foundation)
//   - library `AOSAXSupport`     (shared AX SPI bridge + Chromium AX activation —
//                                 see docs/designs/os-sense.md §"共享 AX SPI 底层模块".
//                                 Holds `_AXUIElementGetWindow` and
//                                 `AXWebAccessibilityActivator` so OS Sense
//                                 and AOSComputerUseKit both depend on it
//                                 without read-side ↔ write-side coupling.)
let package = Package(
    name: "AOS",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "AOSShell",
            targets: ["AOSShell"]
        ),
        .library(
            name: "AOSRPCSchema",
            targets: ["AOSRPCSchema"]
        ),
        .library(
            name: "AOSOSSenseKit",
            targets: ["AOSOSSenseKit"]
        ),
        .library(
            name: "AOSAXSupport",
            targets: ["AOSAXSupport"]
        ),
        .library(
            name: "AOSComputerUseKit",
            targets: ["AOSComputerUseKit"]
        ),
        .executable(
            name: "AOSComputerUseCLI",
            targets: ["AOSComputerUseCLI"]
        ),
        .executable(
            name: "AOSCoordinateTarget",
            targets: ["AOSCoordinateTarget"]
        )
    ],
    dependencies: [
        // SwiftUI Markdown renderer — used by the agent reply view to render
        // streamed model output (headings, lists, code blocks, etc.). GFM
        // support out of the box; theme customized to match the panel's
        // monospaced visual style. See OpenedPanelView.turnRow.
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0")
    ],
    targets: [
        .target(
            name: "AOSRPCSchema",
            path: "Sources/AOSRPCSchema"
        ),
        .testTarget(
            name: "AOSRPCSchemaTests",
            dependencies: ["AOSRPCSchema"],
            path: "Tests/AOSRPCSchemaTests"
        ),
        // Shared AX primitives. Owns the `_AXUIElementGetWindow` SPI bridge
        // and Chromium / Electron web AX activation so OS Sense and
        // AOSComputerUseKit both depend on this package, never on each other.
        .target(
            name: "AOSAXSupport",
            path: "Sources/AOSAXSupport"
        ),
        .testTarget(
            name: "AOSAXSupportTests",
            dependencies: ["AOSAXSupport"],
            path: "Tests/AOSAXSupportTests"
        ),
        // OS Sense — read-side OS state mirror. No dependency on
        // `AOSRPCSchema`: per `docs/designs/os-sense.md` §"依赖方向（核心契约）",
        // OS Sense is read-side, RPC is wire — strict module isolation. The
        // Shell composition layer projects from the live model to the wire
        // schema; this package never imports the wire types.
        .target(
            name: "AOSOSSenseKit",
            dependencies: ["AOSAXSupport"],
            path: "Sources/AOSOSSenseKit"
        ),
        .testTarget(
            name: "AOSOSSenseKitTests",
            dependencies: ["AOSOSSenseKit", "AOSAXSupport"],
            path: "Tests/AOSOSSenseKitTests"
        ),
        // AOSComputerUseKit — remaining app/window/snapshot/capture
        // foundation. App operation layers were removed; this target depends
        // only on AOSAXSupport for shared AX primitives.
        .target(
            name: "AOSComputerUseKit",
            dependencies: ["AOSAXSupport"],
            path: "Sources/AOSComputerUseKit",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "AOSComputerUseKitTests",
            dependencies: ["AOSComputerUseKit", "AOSAXSupport"],
            path: "Tests/AOSComputerUseKitTests"
        ),
        // Terminal-only interface for calling the Computer Use core without
        // launching AOSShell. CLI parsing, output formatting, and permission
        // prompts live in the executable target; the reusable foundation stays
        // in AOSComputerUseKit.
        .executableTarget(
            name: "AOSComputerUseCLI",
            dependencies: ["AOSComputerUseKit"],
            path: "Sources/AOSComputerUseCLI"
        ),
        .executableTarget(
            name: "AOSCoordinateTarget",
            path: "Sources/AOSCoordinateTarget"
        ),
        .testTarget(
            name: "AOSComputerUseCLITests",
            dependencies: ["AOSComputerUseCLI", "AOSComputerUseKit"],
            path: "Tests/AOSComputerUseCLITests"
        ),
        // AOSShell — the macOS Notch UI executable. Depends on both library
        // targets; bundles Info.plist and AOS.entitlements as resources via
        // `.copy(...)` so they're addressable from `Bundle.main.resourceURL`
        // when the .app bundle is assembled by Scripts/build-app.sh.
        // AOSShell `swift build` emits a bare Mach-O; the .app bundle layout
        // (including Info.plist and entitlements from Sources/AOSShellResources/)
        // is assembled by Scripts/build-app.sh — see docs/plans/.../§B. Those
        // files are intentionally NOT declared as SwiftPM resources because
        // SwiftPM forbids `.copy(...)` paths outside the target directory and
        // bundling them under .resources would put them inside the executable's
        // resource bundle rather than at Contents/Info.plist where macOS expects
        // them.
        .executableTarget(
            name: "AOSShell",
            dependencies: [
                "AOSRPCSchema",
                "AOSOSSenseKit",
                "AOSComputerUseKit",
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ],
            path: "Sources/AOSShell",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency=complete")
            ]
        ),
        .testTarget(
            name: "AOSShellTests",
            dependencies: ["AOSShell", "AOSRPCSchema", "AOSOSSenseKit", "AOSComputerUseKit"],
            path: "Tests/AOSShellTests"
        )
    ]
)
