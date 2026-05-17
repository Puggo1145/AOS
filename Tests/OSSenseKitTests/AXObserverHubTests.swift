import Testing
import Foundation
import ApplicationServices
@testable import OSSenseKit

@MainActor
@Suite("AXObserverHub — fan-out + lifecycle")
struct AXObserverHubTests {

    /// Helper: a pid+element pair that's stable for the duration of one test.
    /// Uses our own pid + AXUIElementCreateApplication so element identity is
    /// well-defined even when no AX permission is granted (we never actually
    /// register with AX in these tests — the synthetic seam bypasses that).
    private func selfTarget() -> (pid: pid_t, element: AXUIElement) {
        let pid = getpid()
        return (pid, AXUIElementCreateApplication(pid))
    }

    @Test("Two subscribers to the same triple share one AX registration")
    func fanOutSameTriple() {
        let hub = AXObserverHub()
        let target = selfTarget()
        let note = kAXSelectedTextChangedNotification as String

        var hits1 = 0, hits2 = 0
        let t1 = hub._subscribeWithoutAXForTesting(
            pid: target.pid, element: target.element, notification: note
        ) { hits1 += 1 }
        let t2 = hub._subscribeWithoutAXForTesting(
            pid: target.pid, element: target.element, notification: note
        ) { hits2 += 1 }

        // One AX-level registration, two handlers.
        #expect(hub.registrationCount == 1)
        #expect(hub.subscriptionCount == 2)

        hub._dispatchForTesting(
            pid: target.pid, element: target.element, notification: note
        )
        #expect(hits1 == 1)
        #expect(hits2 == 1)

        // Removing one keeps the other alive — and the AX-level registration
        // must persist so the surviving handler keeps receiving callbacks.
        hub.unsubscribe(t1)
        #expect(hub.registrationCount == 1)
        hub._dispatchForTesting(
            pid: target.pid, element: target.element, notification: note
        )
        #expect(hits1 == 1)         // already gone
        #expect(hits2 == 2)

        // Removing the last handler retires the registration.
        hub.unsubscribe(t2)
        #expect(hub.registrationCount == 0)
        #expect(hub.subscriptionCount == 0)
    }

    @Test("Distinct notifications on the same element form separate registrations")
    func distinctNotificationsAreSeparate() {
        let hub = AXObserverHub()
        let target = selfTarget()
        var textHits = 0, valueHits = 0

        _ = hub._subscribeWithoutAXForTesting(
            pid: target.pid,
            element: target.element,
            notification: kAXSelectedTextChangedNotification as String
        ) { textHits += 1 }
        _ = hub._subscribeWithoutAXForTesting(
            pid: target.pid,
            element: target.element,
            notification: kAXValueChangedNotification as String
        ) { valueHits += 1 }

        #expect(hub.registrationCount == 2)

        hub._dispatchForTesting(
            pid: target.pid,
            element: target.element,
            notification: kAXSelectedTextChangedNotification as String
        )
        #expect(textHits == 1)
        #expect(valueHits == 0)
    }

    @Test("detach(pid:) drops every registration and token for that pid")
    func detachClearsAllForPid() {
        let hub = AXObserverHub()
        let target = selfTarget()

        _ = hub._subscribeWithoutAXForTesting(
            pid: target.pid,
            element: target.element,
            notification: kAXSelectedTextChangedNotification as String
        ) { }
        _ = hub._subscribeWithoutAXForTesting(
            pid: target.pid,
            element: target.element,
            notification: kAXValueChangedNotification as String
        ) { }
        _ = hub._subscribeWithoutAXForTesting(
            pid: target.pid,
            element: target.element,
            notification: kAXFocusedWindowChangedNotification as String
        ) { }

        #expect(hub.registrationCount == 3)
        #expect(hub.subscriptionCount(forPid: target.pid) == 3)

        hub.detach(pid: target.pid)
        #expect(hub.registrationCount == 0)
        #expect(hub.subscriptionCount == 0)
    }

    @Test("Element identity uses CFEqual so re-reads of the same UI element coalesce")
    func elementIdentityViaCFEqual() {
        let hub = AXObserverHub()
        let pid = getpid()
        // Two independent AXUIElement references for the same target. They
        // are distinct CF objects but compare equal under CFEqual; the hub
        // must aggregate registrations across them.
        let e1 = AXUIElementCreateApplication(pid)
        let e2 = AXUIElementCreateApplication(pid)
        let note = kAXSelectedTextChangedNotification as String

        _ = hub._subscribeWithoutAXForTesting(
            pid: pid, element: e1, notification: note
        ) { }
        _ = hub._subscribeWithoutAXForTesting(
            pid: pid, element: e2, notification: note
        ) { }

        // Identity collapsed: still one AX-level registration, two handlers.
        #expect(hub.registrationCount == 1)
        #expect(hub.subscriptionCount == 2)
    }
}
