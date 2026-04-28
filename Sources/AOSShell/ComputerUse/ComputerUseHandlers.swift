import AOSComputerUseKit
import AOSOSSenseKit
import AOSRPCSchema
import AppKit
import CoreGraphics
import Foundation

// MARK: - ComputerUseHandlers
//
// Thin adapter between the wire `computerUse.*` schema in `AOSRPCSchema`
// and the in-process `ComputerUseService` façade. Per
// `docs/designs/computer-use.md` §"与 AOS 主进程的集成":
//
//   - Kit is linked into the Shell as a Swift dependency.
//   - Handlers are stateless; they read params, call the kit, project
//     the result back to the wire schema.
//   - Per-method timeout enforcement is the dispatcher's job (see
//     rpc-protocol.md §"Dispatcher 并发模型" and the per-method table).
//
// This file owns the projection between Kit-internal types
// (`AppInfo`, `WindowInfo`, `Screenshot`, `DoctorReport`) and their
// wire-schema counterparts (`ComputerUseAppInfo`, etc).
//
// Errors thrown by the kit are mapped onto wire RPC error codes via
// `mapError`. The sidecar agent loop reads `error.code` to decide
// whether to retry, ask the user, or surface to the LLM.

@MainActor
public final class ComputerUseHandlers {
    private let service: ComputerUseService
    private let permissions: PermissionsService

    public init(service: ComputerUseService, permissions: PermissionsService) {
        self.service = service
        self.permissions = permissions
    }

    /// Register every `computerUse.*` method with the RPC client. Called
    /// once during Shell composition (after the sidecar handshake but
    /// before the agent starts issuing tool calls).
    public func register(on client: RPCClient) {
        client.registerRequestHandler(
            method: RPCMethod.computerUseListApps,
            as: ComputerUseListAppsParams.self,
            resultType: ComputerUseListAppsResult.self
        ) { [service] _ in
            let apps = await service.listApps()
            return ComputerUseListAppsResult(apps: apps.map(Self.projectAppInfo))
        }

        client.registerRequestHandler(
            method: RPCMethod.computerUseListWindows,
            as: ComputerUseListWindowsParams.self,
            resultType: ComputerUseListWindowsResult.self
        ) { [service] params in
            let windows = await service.listWindows(pid: pid_t(params.pid))
            return ComputerUseListWindowsResult(
                windows: windows.map { (info, onCurrent) in
                    Self.projectWindowInfo(info, onCurrentSpace: onCurrent)
                }
            )
        }

        client.registerRequestHandler(
            method: RPCMethod.computerUseGetAppState,
            as: ComputerUseGetAppStateParams.self,
            resultType: ComputerUseGetAppStateResult.self
        ) { [service] params in
            do {
                let mode = try Self.parseCaptureMode(params.captureMode)
                let bundle = try await service.getAppState(
                    pid: pid_t(params.pid),
                    windowId: CGWindowID(params.windowId),
                    captureMode: mode,
                    maxImageDimension: params.maxImageDimension ?? 0
                )
                return ComputerUseGetAppStateResult(
                    stateId: bundle.stateId?.raw,
                    bundleId: bundle.bundleId,
                    appName: bundle.appName,
                    axTree: bundle.treeMarkdown,
                    elementCount: bundle.elementCount,
                    screenshot: bundle.screenshot.map(Self.projectScreenshot)
                )
            } catch let err as ComputerUseError {
                throw RPCErrorThrowable(Self.mapError(err))
            } catch let err as SnapshotError {
                throw RPCErrorThrowable(Self.mapSnapshotError(err))
            }
        }

        // Element-mode click. Required: stateId + elementIndex (the model
        // must hold a fresh snapshot). Wire shape forbids coord fields, so
        // there's no way to dispatch into the wrong arm.
        client.registerRequestHandler(
            method: RPCMethod.computerUseClickByElement,
            as: ComputerUseClickByElementParams.self,
            resultType: ComputerUseClickResult.self
        ) { [service] params in
            do {
                let result = try await service.clickByElement(
                    pid: pid_t(params.pid),
                    windowId: CGWindowID(params.windowId),
                    stateId: StateID(params.stateId),
                    elementIndex: params.elementIndex,
                    action: params.action ?? "AXPress"
                )
                return ComputerUseClickResult(success: result.success, method: result.method)
            } catch let err as ComputerUseError {
                throw RPCErrorThrowable(Self.mapError(err))
            }
        }

        // Coordinate-mode click. Required: x + y in window-local pixels.
        // No stateId/elementIndex on the wire — cannot accidentally hit
        // the StateCache / produce stateStale.
        client.registerRequestHandler(
            method: RPCMethod.computerUseClickByCoords,
            as: ComputerUseClickByCoordsParams.self,
            resultType: ComputerUseClickResult.self
        ) { [service] params in
            do {
                let result = try await service.clickByCoords(
                    pid: pid_t(params.pid),
                    windowId: CGWindowID(params.windowId),
                    x: params.x, y: params.y,
                    count: params.count ?? 1,
                    modifiers: params.modifiers ?? []
                )
                return ComputerUseClickResult(success: result.success, method: result.method)
            } catch let err as ComputerUseError {
                throw RPCErrorThrowable(Self.mapError(err))
            }
        }

        client.registerRequestHandler(
            method: RPCMethod.computerUseDrag,
            as: ComputerUseDragParams.self,
            resultType: ComputerUseDragResult.self
        ) { [service] params in
            do {
                let success = try await service.drag(
                    pid: pid_t(params.pid),
                    windowId: CGWindowID(params.windowId),
                    from: CGPoint(x: params.from.x, y: params.from.y),
                    to: CGPoint(x: params.to.x, y: params.to.y)
                )
                return ComputerUseDragResult(success: success)
            } catch let err as ComputerUseError {
                throw RPCErrorThrowable(Self.mapError(err))
            }
        }

        client.registerRequestHandler(
            method: RPCMethod.computerUseTypeText,
            as: ComputerUseTypeTextParams.self,
            resultType: ComputerUseTypeTextResult.self
        ) { [service] params in
            do {
                let success = try await service.typeText(
                    pid: pid_t(params.pid),
                    windowId: CGWindowID(params.windowId),
                    text: params.text
                )
                return ComputerUseTypeTextResult(success: success)
            } catch let err as ComputerUseError {
                throw RPCErrorThrowable(Self.mapError(err))
            }
        }

        client.registerRequestHandler(
            method: RPCMethod.computerUsePressKey,
            as: ComputerUsePressKeyParams.self,
            resultType: ComputerUsePressKeyResult.self
        ) { [service] params in
            do {
                let success = try await service.pressKey(
                    pid: pid_t(params.pid),
                    windowId: CGWindowID(params.windowId),
                    key: params.key,
                    modifiers: params.modifiers ?? []
                )
                return ComputerUsePressKeyResult(success: success)
            } catch let err as ComputerUseError {
                throw RPCErrorThrowable(Self.mapError(err))
            }
        }

        client.registerRequestHandler(
            method: RPCMethod.computerUseScroll,
            as: ComputerUseScrollParams.self,
            resultType: ComputerUseScrollResult.self
        ) { [service] params in
            do {
                let success = try await service.scroll(
                    pid: pid_t(params.pid),
                    windowId: CGWindowID(params.windowId),
                    x: params.x, y: params.y,
                    dx: params.dx, dy: params.dy
                )
                return ComputerUseScrollResult(success: success)
            } catch let err as ComputerUseError {
                throw RPCErrorThrowable(Self.mapError(err))
            }
        }

        client.registerRequestHandler(
            method: RPCMethod.computerUseDoctor,
            as: ComputerUseDoctorParams.self,
            resultType: ComputerUseDoctorResult.self
        ) { [service, permissions] _ in
            let granted = await MainActor.run {
                !permissions.state.denied.contains(.screenRecording)
            }
            let report = await service.doctor(screenRecordingGranted: granted)
            return ComputerUseDoctorResult(
                accessibility: report.accessibility,
                screenRecording: report.screenRecording,
                automation: report.automation,
                skyLightSPI: ComputerUseSkyLightStatus(
                    postToPid: report.skyLightSPI.postToPid,
                    authMessage: report.skyLightSPI.authMessage,
                    focusWithoutRaise: report.skyLightSPI.focusWithoutRaise,
                    windowLocation: report.skyLightSPI.windowLocation,
                    spaces: report.skyLightSPI.spaces,
                    getWindow: report.skyLightSPI.getWindow
                )
            )
        }
    }

    // MARK: - Projections
    //
    // Static helpers are `nonisolated` so they can be called from inside
    // the request handler closures (which run on the RPCClient's
    // detached Task, off the MainActor). The class is MainActor only
    // because it needs to read `permissionsService.state` synchronously.

    nonisolated private static func projectAppInfo(_ info: AppInfo) -> ComputerUseAppInfo {
        ComputerUseAppInfo(
            pid: Int32(info.pid),
            bundleId: info.bundleId,
            name: info.name,
            active: info.active
        )
    }

    nonisolated private static func projectWindowInfo(
        _ info: WindowInfo, onCurrentSpace: Bool
    ) -> ComputerUseWindowInfo {
        ComputerUseWindowInfo(
            windowId: UInt32(info.id),
            title: info.title,
            bounds: ComputerUseWindowBounds(
                x: info.bounds.x, y: info.bounds.y,
                width: info.bounds.width, height: info.bounds.height
            ),
            isOnScreen: info.isOnScreen,
            onCurrentSpace: onCurrentSpace,
            layer: info.layer
        )
    }

    nonisolated private static func projectScreenshot(_ shot: Screenshot) -> ComputerUseScreenshot {
        ComputerUseScreenshot(
            imageBase64: shot.imageData.base64EncodedString(),
            format: shot.format.rawValue,
            width: shot.width,
            height: shot.height,
            scaleFactor: shot.scaleFactor,
            originalWidth: shot.originalWidth,
            originalHeight: shot.originalHeight
        )
    }

    /// `nil` falls back to `.som` (the documented default). A non-nil
    /// unknown string fails loudly with `invalidParams` instead of
    /// silently picking `.som` — silent fallback was hiding malformed
    /// model output and quietly upgrading `ax`-only requests into full
    /// AX+screenshot captures, which both wastes work and burns the
    /// payload budget enforced above.
    nonisolated static func parseCaptureMode(_ raw: String?) throws -> CaptureMode {
        guard let raw else { return .som }
        switch raw.lowercased() {
        case "som":    return .som
        case "vision": return .vision
        case "ax":     return .ax
        default:
            throw RPCErrorThrowable(RPCError(
                code: RPCErrorCode.invalidParams,
                message: "captureMode \"\(raw)\" not recognized — expected \"som\", \"vision\", or \"ax\""
            ))
        }
    }

    // MARK: - Error mapping

    /// Map kit errors to wire-level RPC errors per the design's error
    /// table. `error.data` carries structured context the agent can read
    /// before retrying.
    nonisolated static func mapError(_ err: ComputerUseError) -> RPCError {
        switch err {
        case .windowMismatch(let pid, let windowId, let ownerPid, let expectedWindowId):
            // Wire shape per docs/designs/rpc-protocol.md "错误模型":
            //   { pid, windowId, expected?: { pid, windowId } }
            // The nested `expected` carries whichever side is known —
            // `ownerPid` from `validateOwnership`, `expectedWindowId`
            // (and the matching pid) from the StateCache stateId scan.
            // Keep `expected` only when at least one half is present so
            // the field's presence stays a meaningful signal to the
            // sidecar's recovery branch.
            var data: [String: AOSRPCSchema.JSONValue] = [
                "pid": .int(Int(pid)),
                "windowId": .int(Int(windowId))
            ]
            if ownerPid != nil || expectedWindowId != nil {
                var expected: [String: AOSRPCSchema.JSONValue] = [:]
                if let owner = ownerPid {
                    expected["pid"] = .int(Int(owner))
                }
                if let expectedWid = expectedWindowId {
                    expected["windowId"] = .int(Int(expectedWid))
                }
                data["expected"] = .object(expected)
            }
            return RPCError(
                code: RPCErrorCode.windowMismatch,
                message: err.description,
                data: .object(data)
            )
        case .windowOffSpace(let cur, let ws):
            return RPCError(
                code: RPCErrorCode.windowOffSpace,
                message: err.description,
                data: .object([
                    "currentSpaceID": .int(Int(cur)),
                    "windowSpaceIDs": .array(ws.map { .int(Int($0)) })
                ])
            )
        case .stateStale(let reason, let stateId):
            return RPCError(
                code: RPCErrorCode.stateStale,
                message: err.description,
                data: .object([
                    "reason": AOSRPCSchema.JSONValue.string(reason),
                    "stateId": AOSRPCSchema.JSONValue.string(stateId)
                ])
            )
        case .invalidElementIndex(let stateId, let elementIndex):
            // Distinct from stateStale: the snapshot is intact, the index
            // is bad. Surfaces as `invalidParams` so the model treats it
            // as "fix your arguments" instead of "refresh state and retry".
            return RPCError(
                code: RPCErrorCode.invalidParams,
                message: err.description,
                data: .object([
                    "stateId": AOSRPCSchema.JSONValue.string(stateId),
                    "elementIndex": AOSRPCSchema.JSONValue.int(elementIndex)
                ])
            )
        case .operationFailed(let layers):
            let layerData: [AOSRPCSchema.JSONValue] = layers.map { layer in
                AOSRPCSchema.JSONValue.object([
                    "name": .string(layer.name),
                    "status": .string(layer.status)
                ])
            }
            return RPCError(
                code: RPCErrorCode.operationFailed,
                message: err.description,
                data: .object(["layers": .array(layerData)])
            )
        case .captureUnavailable, .windowNotFound, .noElement:
            return RPCError(
                code: RPCErrorCode.internalError,
                message: err.description
            )
        case .payloadTooLarge(let bytes, let limit):
            return RPCError(
                code: RPCErrorCode.payloadTooLarge,
                message: err.description,
                data: .object([
                    "bytes": .int(bytes),
                    "limit": .int(limit)
                ])
            )
        case .coordOutOfBounds(let point, let width, let height, let label):
            var data: [String: AOSRPCSchema.JSONValue] = [
                "label": .string(label),
                "x": .double(point.x),
                "y": .double(point.y),
            ]
            if width > 0, height > 0 {
                data["width"] = .int(width)
                data["height"] = .int(height)
            }
            return RPCError(
                code: RPCErrorCode.invalidParams,
                message: err.description,
                data: .object(data)
            )
        case .noScreenshotReference(let pid, let windowId):
            return RPCError(
                code: RPCErrorCode.invalidParams,
                message: err.description,
                data: .object([
                    "pid": .int(Int(pid)),
                    "windowId": .int(Int(windowId)),
                    "remedy": .string("call computer_use_get_app_state with captureMode 'som' or 'vision' first")
                ])
            )
        case .axNotAuthorized:
            return RPCError(
                code: RPCErrorCode.permissionDenied,
                message: err.description
            )
        }
    }

    nonisolated static func mapSnapshotError(_ err: SnapshotError) -> RPCError {
        switch err {
        case .notAuthorized:
            return RPCError(code: RPCErrorCode.permissionDenied, message: err.description)
        case .appNotFound:
            return RPCError(code: RPCErrorCode.internalError, message: err.description)
        }
    }
}
