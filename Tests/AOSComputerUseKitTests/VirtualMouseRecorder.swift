@testable import AOSComputerUseKit
import Foundation

actor VirtualMouseRecorder {
    private var recordedEvents: [VirtualMouseEvent] = []

    var events: [VirtualMouseEvent] {
        recordedEvents
    }

    func record(_ event: VirtualMouseEvent) {
        recordedEvents.append(event)
    }
}
