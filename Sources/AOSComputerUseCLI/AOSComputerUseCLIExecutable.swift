import AOSComputerUseKit
import Darwin
import Dispatch
import Foundation

@main
struct AOSComputerUseCLIExecutable {
    static func main() async {
        let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        let result = await run(arguments: arguments)

        if !result.stdout.isEmpty {
            FileHandle.standardOutput.write(Data(result.stdout.utf8))
        }
        if !result.stderr.isEmpty {
            FileHandle.standardError.write(Data(result.stderr.utf8))
        }
        exit(result.exitCode)
    }

    static func run(arguments: [String]) async -> ComputerUseCLIResult {
        let normalizedArguments = arguments.isEmpty ? ["interactive"] : arguments
        guard isAllowedStandaloneInvocation(normalizedArguments) else {
            return ComputerUseCLIResult(
                stdout: "",
                stderr: "standalone commands were removed; run AOSComputerUseCLI interactive.\n",
                exitCode: 64
            )
        }

        do {
            let core = ComputerUseCore()
            let signalCleanup = normalizedArguments == ["interactive"]
                ? ProcessSignalAppSessionCleanup(core: core)
                : nil
            signalCleanup?.install()
            return try await ComputerUseCLI.run(
                arguments: normalizedArguments,
                core: core
            )
        } catch {
            return ComputerUseCLIResult(stdout: "", stderr: String(describing: error) + "\n", exitCode: 1)
        }
    }

    private static func isAllowedStandaloneInvocation(_ arguments: [String]) -> Bool {
        arguments == ["interactive"]
            || arguments == ["help"]
            || arguments == ["--help"]
            || arguments == ["-h"]
    }
}

private final class ProcessSignalAppSessionCleanup: @unchecked Sendable {
    private let core: ComputerUseCoreClient
    private var sources: [DispatchSourceSignal] = []

    init(core: ComputerUseCoreClient) {
        self.core = core
    }

    func install() {
        install(signal: SIGINT, exitCode: 130)
        install(signal: SIGTERM, exitCode: 143)
    }

    private func install(signal signalNumber: Int32, exitCode: Int32) {
        Darwin.signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler { [core] in
            Task {
                try? await ComputerUseCLI.stopActiveAppSessionIfAvailable(core: core)
                exit(exitCode)
            }
        }
        source.resume()
        sources.append(source)
    }
}
