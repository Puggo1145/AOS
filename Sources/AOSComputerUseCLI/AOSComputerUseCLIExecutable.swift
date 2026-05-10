import Darwin
import Foundation

@main
struct AOSComputerUseCLIExecutable {
    static func main() async {
        let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        let result: ComputerUseCLIResult
        do {
            result = try await ComputerUseCLI.run(
                arguments: arguments,
                core: ComputerUseCoreAdapter()
            )
        } catch {
            FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
            exit(1)
        }

        if !result.stdout.isEmpty {
            FileHandle.standardOutput.write(Data(result.stdout.utf8))
        }
        if !result.stderr.isEmpty {
            FileHandle.standardError.write(Data(result.stderr.utf8))
        }
        exit(result.exitCode)
    }
}
