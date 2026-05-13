import AOSComputerUseKit
import Foundation

enum AppSessionPolicy: Sendable, Equatable {
    case oneShotEventCommands
    case persistentHost
}

extension ComputerUseCLI {
    static func runEventCommand<T>(
        policy: AppSessionPolicy,
        core: ComputerUseCoreClient,
        operation: () async throws -> T
    ) async throws -> T {
        switch policy {
        case .oneShotEventCommands:
            return try await runOneShotAppSessionCommand(core: core, operation: operation)
        case .persistentHost:
            return try await operation()
        }
    }

    static func runOneShotAppSessionCommand<T>(
        core: ComputerUseCoreClient,
        operation: () async throws -> T
    ) async throws -> T {
        let value: T
        do {
            value = try await operation()
        } catch let operationError {
            do {
                _ = try await core.stopAppSession()
            } catch let cleanupError where isAppSessionUnavailable(cleanupError) {
                throw operationError
            } catch {
                throw OneShotAppSessionCleanupError(operationError: operationError, cleanupError: error)
            }
            throw operationError
        }
        _ = try await core.stopAppSession()
        return value
    }

    static func isAppSessionUnavailable(_ error: Error) -> Bool {
        guard case ComputerUseError.appSessionUnavailable = error else {
            return false
        }
        return true
    }
}

struct OneShotAppSessionCleanupError: Error, CustomStringConvertible {
    let operationError: Error
    let cleanupError: Error

    var description: String {
        "one-shot app session cleanup failed after operation error: \(operationError); cleanup: \(cleanupError)"
    }
}
