import Testing
@testable import AOSShell

@MainActor
@Suite("SidecarSupervisor")
struct SidecarSupervisorTests {
    @Test("unexpected exit after launch enters fatal state and calls handler")
    func unexpectedExitAfterLaunchIsFatal() {
        let supervisor = SidecarSupervisor()
        var messages: [String] = []
        supervisor.setFatalHandler { messages.append($0) }

        supervisor.beginLaunch()
        supervisor.didLaunch()
        supervisor.handleUnexpectedExit(status: 9)

        #expect(supervisor.state == .fatal("Sidecar exited unexpectedly with status 9. Restart AOS to reconnect the agent."))
        #expect(messages == ["Sidecar exited unexpectedly with status 9. Restart AOS to reconnect the agent."])
    }

    @Test("expected termination suppresses fatal state")
    func expectedTerminationIsNotFatal() {
        let supervisor = SidecarSupervisor()
        var messages: [String] = []
        supervisor.setFatalHandler { messages.append($0) }

        supervisor.beginLaunch()
        supervisor.didLaunch()
        supervisor.expectTermination()
        supervisor.handleUnexpectedExit(status: 15)

        #expect(supervisor.state == .stopping)
        #expect(messages.isEmpty)
    }
}
