@testable import ComputerUseKit
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

actor WindowHighlightRecorder {
    private var recordedEvents: [WindowHighlightEvent] = []

    var events: [WindowHighlightEvent] {
        recordedEvents
    }

    func record(_ event: WindowHighlightEvent) {
        recordedEvents.append(event)
    }
}
