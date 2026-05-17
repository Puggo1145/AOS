import Testing
import Foundation
import AOSRPCSchema
@testable import AOSShell

// MARK: - ProviderServiceTests
//
// Covers the validation boundary inside `ProviderService.saveApiKey`:
// the service is the business edge, so a bad providerId or an OAuth
// provider must be rejected BEFORE any Keychain mutation. These tests
// instantiate ProviderService over a closed RPC pipe (no live counterparty)
// and use a Keychain pointed at a unique service id so failures don't
// pollute the developer's real Keychain.

@MainActor
@Suite("ProviderService API key validation")
struct ProviderServiceTests {

    private func makeService(providers: [ProviderService.Provider]) -> (ProviderService, KeychainService) {
        // Real RPCClient over a closed pipe — saveApiKey's pre-RPC
        // validation path never reaches the wire so this is safe.
        let inbound = Pipe()
        let outbound = Pipe()
        let rpc = RPCClient(
            inbound: inbound.fileHandleForReading,
            outbound: outbound.fileHandleForWriting
        )
        // Per-test Keychain service id so concurrent runs and re-runs
        // don't share state with the real app or each other.
        let serviceId = "com.aos.apikey.test.\(UUID().uuidString)"
        let keychain = KeychainService(service: serviceId)
        let svc = ProviderService(rpc: rpc, keychain: keychain)
        svc._testSetProviders(providers)
        svc._testSetStatusLoaded(true)
        return (svc, keychain)
    }

    @Test("saveApiKey rejects unknown providerId before touching Keychain")
    func rejectsUnknownProvider() async throws {
        let (svc, keychain) = makeService(providers: [
            ProviderService.Provider(id: "deepseek", name: "deepseek", authMethod: .apiKey, state: .unauthenticated),
        ])
        let bogusId = "nonexistent-\(UUID().uuidString)"
        do {
            try await svc.saveApiKey(providerId: bogusId, apiKey: "sk-should-not-persist")
            Issue.record("expected unknown provider error")
        } catch ProviderService.ActionError.unknownProvider(let providerId) {
            #expect(providerId == bogusId)
        } catch {
            Issue.record("expected unknownProvider, got \(error)")
        }
        // Keychain must remain empty for the bogus id — proves we returned
        // before `keychain.saveApiKey`.
        let stored = try keychain.loadApiKey(providerId: bogusId)
        #expect(stored == nil)
    }

    @Test("saveApiKey rejects OAuth providers before touching Keychain")
    func rejectsOAuthProvider() async throws {
        let (svc, keychain) = makeService(providers: [
            ProviderService.Provider(id: "chatgpt-plan", name: "chatgpt-plan", authMethod: .oauth, state: .unauthenticated),
        ])
        do {
            try await svc.saveApiKey(providerId: "chatgpt-plan", apiKey: "sk-should-not-persist")
            Issue.record("expected unsupported auth method error")
        } catch ProviderService.ActionError.unsupportedAuthMethod(let providerId) {
            #expect(providerId == "chatgpt-plan")
        } catch {
            Issue.record("expected unsupportedAuthMethod, got \(error)")
        }
        let stored = try keychain.loadApiKey(providerId: "chatgpt-plan")
        #expect(stored == nil)
    }

    @Test("saveApiKey rejects empty key with the canonical message")
    func rejectsEmptyKey() async {
        let (svc, _) = makeService(providers: [
            ProviderService.Provider(id: "deepseek", name: "deepseek", authMethod: .apiKey, state: .unauthenticated),
        ])
        do {
            try await svc.saveApiKey(providerId: "deepseek", apiKey: "   ")
            Issue.record("expected empty API key error")
        } catch ProviderService.ActionError.emptyApiKey {
        } catch {
            Issue.record("expected emptyApiKey, got \(error)")
        }
    }

    @Test("peekApiKey returns nil for a never-stored providerId")
    func peekReturnsNilWhenAbsent() throws {
        let (svc, _) = makeService(providers: [
            ProviderService.Provider(id: "deepseek", name: "deepseek", authMethod: .apiKey, state: .unauthenticated),
        ])
        let value = try svc.peekApiKey(providerId: "deepseek")
        #expect(value == nil)
    }
}
