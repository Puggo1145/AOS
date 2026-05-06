import AppKit
import CoreGraphics
import AOSComputerUseKit

// MARK: - DevComputerUseWindowRow

struct DevComputerUseWindowRow: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
    let bounds: WindowBounds
    let isOnScreen: Bool
    let onCurrentSpace: Bool
    let layer: Int
    let zIndex: Int

    init(info: WindowInfo, onCurrentSpace: Bool) {
        self.id = info.id
        self.title = info.title
        self.bounds = info.bounds
        self.isOnScreen = info.isOnScreen
        self.onCurrentSpace = onCurrentSpace
        self.layer = info.layer
        self.zIndex = info.zIndex
    }
}

// MARK: - DevComputerUseWorkbench

@MainActor
@Observable
final class DevComputerUseWorkbench {
    @ObservationIgnored let service: ComputerUseService
    @ObservationIgnored let doctorService: ComputerUseDoctorService

    var apps: [AppInfo] = []
    var windows: [DevComputerUseWindowRow] = []
    var appListMode: AppListMode = .running
    var selectedAppIdentity: String? {
        didSet {
            guard oldValue != selectedAppIdentity else { return }
            clearWindowSelection()
        }
    }
    var selectedWindowId: CGWindowID? {
        didSet {
            guard oldValue != selectedWindowId else { return }
            clearCapturedState()
        }
    }
    var captureMode: CaptureMode = .som
    var maxImageDimension: String = ""

    var stateId: StateID?
    var axTree: String?
    var screenshot: Screenshot?
    var stateSummary: String?

    var elementIndex: String = ""
    var axAction: String = "AXPress"

    var x: String = "10"
    var y: String = "10"
    var clickCount: Int = 1
    var modifiers: String = ""

    var scrollX: String = "10"
    var scrollY: String = "10"
    var scrollDX: String = "0"
    var scrollDY: String = "-5"

    var dragFromX: String = "10"
    var dragFromY: String = "10"
    var dragToX: String = "100"
    var dragToY: String = "100"

    var coordinateReliabilityScript: String = """
    80,80
    160,120
    240,180
    320,240
    """
    var coordinateReliabilityTolerance: String = "4"
    var coordinateReliabilityResults: [DevCoordinateReliabilityResult] = []
    var coordinateReliabilitySummary: String?
    @ObservationIgnored let coordinateReliabilityStore = DevCoordinateReliabilityStore()
    @ObservationIgnored let coordinateReliabilityTarget = DevCoordinateReliabilityTargetProcess()

    var textToType: String = ""
    var key: String = "return"
    var keyModifiers: String = ""

    var lastResult: String?
    var lastError: String?
    var isRunning: Bool = false

    init(service: ComputerUseService, doctorService: ComputerUseDoctorService) {
        self.service = service
        self.doctorService = doctorService
    }

    var hasTarget: Bool {
        selectedPid != nil && selectedWindowId != nil
    }

    var selectedApp: AppInfo? {
        guard let selectedAppIdentity else { return nil }
        return apps.first { $0.identity == selectedAppIdentity }
    }

    var selectedPid: pid_t? {
        selectedApp?.pid
    }

    var canClickElement: Bool {
        hasTarget && stateId != nil
    }

    var screenshotImage: NSImage? {
        guard let screenshot else { return nil }
        return NSImage(data: screenshot.imageData)
    }

    func clearWindowSelection() {
        windows = []
        selectedWindowId = nil
        clearCapturedState()
    }

    func clearCapturedState() {
        stateId = nil
        axTree = nil
        screenshot = nil
        stateSummary = nil
        coordinateReliabilityResults = []
        coordinateReliabilitySummary = nil
    }
}

enum DevComputerUseInputError: Error, CustomStringConvertible {
    case missingTarget(String)
    case invalid(label: String, value: String)

    var description: String {
        switch self {
        case .missingTarget(let field):
            return "missing \(field)"
        case .invalid(let label, let value):
            return "invalid \(label): \(value)"
        }
    }
}
