// swift-tools-version: 5.10
import PackageDescription

// Notch Agent SwiftPM workspace.
//
// Targets:
//   - executable `Shell`      (Notch UI + RPC client + AgentService composition root)
//   - executable `ComputerUseCLI` (terminal entrypoint for Computer Use core)
//   - library `RPCSchema`     (wire protocol — see docs/plans/rpc-protocol.md)
//   - library `OSSenseKit`    (OS Sense — see docs/designs/os-sense.md)
//   - library `ComputerUseKit` (Computer Use foundation)
//   - library `AXSupport`     (shared AX SPI bridge + Chromium AX activation —
//                                 see docs/designs/os-sense.md §"共享 AX SPI 底层模块".
//                                 Holds `_AXUIElementGetWindow` and
//                                 `AXWebAccessibilityActivator` so OS Sense
//                                 and ComputerUseKit both depend on it
//                                 without read-side ↔ write-side coupling.)
let package = Package(
    name: "notch-agent",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "Shell",
            targets: ["Shell"]
        ),
        .library(
            name: "RPCSchema",
            targets: ["RPCSchema"]
        ),
        .library(
            name: "OSSenseKit",
            targets: ["OSSenseKit"]
        ),
        .library(
            name: "AXSupport",
            targets: ["AXSupport"]
        ),
        .library(
            name: "ComputerUseKit",
            targets: ["ComputerUseKit"]
        ),
        .executable(
            name: "ComputerUseCLI",
            targets: ["ComputerUseCLI"]
        ),
        .executable(
            name: "CoordinateTarget",
            targets: ["CoordinateTarget"]
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
            name: "RPCSchema",
            path: "Sources/RPCSchema"
        ),
        .testTarget(
            name: "RPCSchemaTests",
            dependencies: ["RPCSchema"],
            path: "Tests/RPCSchemaTests"
        ),
        // Shared AX primitives. Owns the `_AXUIElementGetWindow` SPI bridge
        // and Chromium / Electron web AX activation so OS Sense and
        // ComputerUseKit both depend on this package, never on each other.
        .target(
            name: "AXSupport",
            path: "Sources/AXSupport"
        ),
        .testTarget(
            name: "AXSupportTests",
            dependencies: ["AXSupport"],
            path: "Tests/AXSupportTests"
        ),
        // OS Sense — read-side OS state mirror. No dependency on
        // `RPCSchema`: per `docs/designs/os-sense.md` §"依赖方向（核心契约）",
        // OS Sense is read-side, RPC is wire — strict module isolation. The
        // Shell composition layer projects from the live model to the wire
        // schema; this package never imports the wire types.
        .target(
            name: "OSSenseKit",
            dependencies: ["AXSupport"],
            path: "Sources/OSSenseKit"
        ),
        .testTarget(
            name: "OSSenseKitTests",
            dependencies: ["OSSenseKit", "AXSupport"],
            path: "Tests/OSSenseKitTests"
        ),
        // ComputerUseKit — remaining app/window/snapshot/capture
        // foundation. App operation layers were removed; this target depends
        // only on AXSupport for shared AX primitives.
        .target(
            name: "ComputerUseKit",
            dependencies: ["AXSupport"],
            path: "Sources/ComputerUseKit",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "ComputerUseKitTests",
            dependencies: ["ComputerUseKit", "AXSupport"],
            path: "Tests/ComputerUseKitTests"
        ),
        // Terminal-only interface for calling the Computer Use core without
        // launching Shell. CLI parsing, output formatting, and permission
        // prompts live in the executable target; the reusable foundation stays
        // in ComputerUseKit.
        .executableTarget(
            name: "ComputerUseCLI",
            dependencies: ["ComputerUseKit"],
            path: "Sources/ComputerUseCLI"
        ),
        .executableTarget(
            name: "CoordinateTarget",
            path: "Sources/CoordinateTarget"
        ),
        .testTarget(
            name: "ComputerUseCLITests",
            dependencies: ["ComputerUseCLI", "ComputerUseKit"],
            path: "Tests/ComputerUseCLITests"
        ),
        // Shell — the macOS Notch UI executable. Depends on both library
        // targets; bundles Info.plist and NotchAgent.entitlements as resources via
        // `.copy(...)` so they're addressable from `Bundle.main.resourceURL`
        // when the .app bundle is assembled by Scripts/build-app.sh.
        // Shell `swift build` emits a bare Mach-O; the .app bundle layout
        // (including Info.plist and entitlements from Sources/ShellResources/)
        // is assembled by Scripts/build-app.sh — see docs/plans/.../§B. Those
        // files are intentionally NOT declared as SwiftPM resources because
        // SwiftPM forbids `.copy(...)` paths outside the target directory and
        // bundling them under .resources would put them inside the executable's
        // resource bundle rather than at Contents/Info.plist where macOS expects
        // them.
        .executableTarget(
            name: "Shell",
            dependencies: [
                "RPCSchema",
                "OSSenseKit",
                "ComputerUseKit",
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ],
            path: "Sources/Shell",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency=complete")
            ]
        ),
        .testTarget(
            name: "ShellTests",
            dependencies: ["Shell", "RPCSchema", "OSSenseKit", "ComputerUseKit"],
            path: "Tests/ShellTests"
        )
    ]
)
