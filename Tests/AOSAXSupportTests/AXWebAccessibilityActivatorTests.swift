import ApplicationServices
import Foundation
import Testing
@testable import AOSAXSupport

@Suite("AXWebAccessibilityActivator")
struct AXWebAccessibilityActivatorTests {

    @Test("Successful enablement writes mark the pid activated")
    func successfulWritesMarkPidActivated() async {
        let writer: AXAttributeWriter = { _, _, _ in .success }
        let activator = AXWebAccessibilityActivator(
            negativeCacheTTL: 30,
            writeAttribute: writer,
            observerRegistrar: .disabledForTesting,
            webContentProbe: { _ in true }
        )
        let pid = getpid()
        let root = AXUIElementCreateApplication(pid)

        let activated = await activator.activate(pid: pid, root: root)

        #expect(activated)
        #expect(await activator.isActivated(pid: pid))
        #expect(!(await activator.isKnownNonActivatable(pid: pid)))
    }

    @Test("Failed enablement writes are negative cached until TTL expires")
    func failedWritesAreNegativeCachedUntilTTLExpires() async throws {
        let writer: AXAttributeWriter = { _, _, _ in .failure }
        let activator = AXWebAccessibilityActivator(
            negativeCacheTTL: 0.1,
            writeAttribute: writer,
            observerRegistrar: .disabledForTesting,
            webContentProbe: { _ in false }
        )
        let pid = getpid()
        let root = AXUIElementCreateApplication(pid)

        let activated = await activator.activate(pid: pid, root: root)

        #expect(!activated)
        #expect(await activator.isKnownNonActivatable(pid: pid))
        try await Task.sleep(for: .milliseconds(200))
        #expect(!(await activator.isKnownNonActivatable(pid: pid)))
    }

    @Test("Activated pids re-write enablement without re-registering observers")
    func activatedPidsRewriteEnablementWithoutReRegisteringObservers() async {
        actor Counts {
            var writes = 0
            var registrations = 0

            func recordWrite() { writes += 1 }
            func recordRegistration() { registrations += 1 }
        }

        let counts = Counts()
        let writer: AXAttributeWriter = { _, _, _ in
            Task { await counts.recordWrite() }
            return .success
        }
        let registrar = AXWebAccessibilityObserverRegistrar { _, _ in
            Task { await counts.recordRegistration() }
            return nil
        }
        let activator = AXWebAccessibilityActivator(
            negativeCacheTTL: 30,
            writeAttribute: writer,
            observerRegistrar: registrar,
            webContentProbe: { _ in true }
        )
        let pid = getpid()
        let root = AXUIElementCreateApplication(pid)

        _ = await activator.activate(pid: pid, root: root)
        _ = await activator.activate(pid: pid, root: root)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await counts.writes == 4)
        #expect(await counts.registrations == 1)
    }

    @Test("Cancelled activation stops waiting for web content")
    func cancelledActivationStopsWaitingForWebContent() async {
        final class LockedCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0

            func increment() {
                lock.withLock {
                    value += 1
                }
            }

            func read() -> Int {
                lock.withLock { value }
            }
        }

        let probeCalls = LockedCounter()
        let activator = AXWebAccessibilityActivator(
            negativeCacheTTL: 30,
            writeAttribute: { _, _, _ in .success },
            observerRegistrar: .disabledForTesting,
            webContentProbe: { _ in
                probeCalls.increment()
                return false
            }
        )
        let pid = getpid()
        let root = AXUIElementCreateApplication(pid)

        let task = Task {
            await activator.activate(pid: pid, root: root)
        }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()
        _ = await task.value

        #expect(probeCalls.read() < 10)
    }
}
