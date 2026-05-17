// MARK: - Onboarding + provider selection reconciliation

extension NotchViewModel {
    /// Both onboard prerequisites first satisfied while config has
    /// loaded and the latch is still false — i.e., the moment to flip
    /// `hasCompletedOnboarding` for good.
    public var shouldMarkOnboardingDone: Bool {
        configService.loaded
            && !configService.hasCompletedOnboarding
            && permissionsService.onboardingPermissionsComplete
            && providerService.hasReadyProvider
    }

    /// Stable signal that flips whenever any provider's readiness changes.
    /// Used as the `task(id:)` key so reconciliation re-runs at the right
    /// moments without firing on unrelated re-renders.
    public var providerReadyKey: String {
        providerService.providers
            .map { "\($0.id):\($0.state == .ready ? 1 : 0)" }
            .joined(separator: ",")
    }

    public func markOnboardingCompletedIfNeeded() async {
        guard shouldMarkOnboardingDone else { return }
        await configService.markOnboardingCompleted()
    }

    public func reconcileSelectionIfNeeded() async {
        let cs = configService
        let ps = providerService
        guard ps.statusLoaded, cs.selection == nil else { return }
        guard let sel = cs.effectiveSelection else { return }
        let currentReady = ps.providers.contains { $0.id == sel.providerId && $0.state == .ready }
        if currentReady { return }
        guard let ready = ps.providers.first(where: { $0.state == .ready }),
              let entry = cs.provider(id: ready.id) else { return }
        await cs.selectModel(providerId: ready.id, modelId: entry.defaultModelId)
    }
}
