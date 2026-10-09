import Foundation

/// App-wide ordering and projection authority for Antigravity connection mutations.
///
/// Every Settings window owns its own `APISettingsViewModel`, while `agy` has one global MCP
/// document. A generation makes the newest manual Connect/Forget intent authoritative, and the
/// mutation lane prevents an older filesystem operation from running after a newer one merely
/// because its preflight work took longer.
actor AntigravityConnectionCoordinator {
    struct Generation: Hashable {
        fileprivate let rawValue: UInt64
    }

    struct Projection: Equatable {
        let generation: Generation
        let revision: UInt64
        let isConnected: Bool
        let errorMessage: String?
        let hasOwnedMCPEntry: Bool
    }

    struct StartupValidationSnapshot: Equatable {
        let generation: Generation
        let epoch: UInt64
        let projectionRevision: UInt64
        let persistedConnectionHint: Bool
    }

    struct CancellationReconciliationObservation: Equatable {
        let configValidationFailureMessage: String?
        let hasOwnedMCPEntry: Bool
    }

    enum MutationExecution<Value: Sendable> {
        case completed(Value)
        case superseded
        case cancelled
    }

    struct MutationLaneState: Equatable {
        let isOccupied: Bool
        let waiterCount: Int
    }

    private struct MutationLaneWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    static let shared = AntigravityConnectionCoordinator()

    private let notificationCenter: NotificationCenter
    private let userDefaults: UserDefaults
    private var generationValue: UInt64 = 0
    private var startupValidationEpochValue: UInt64 = 0
    private var latestPublishedStartupEpochValue: UInt64 = 0
    private var projectionRevisionValue: UInt64 = 0
    private var latestConnectionProjection: Projection?
    private var mutationLaneIsOccupied = false
    private var mutationLaneWaiters: [MutationLaneWaiter] = []
    private var hasUnpublishedMutationCompletion = false
    private var currentGenerationNeedsPredecessorReconciliation = false

    init(
        notificationCenter: NotificationCenter = .default,
        userDefaults: UserDefaults = .standard
    ) {
        self.notificationCenter = notificationCenter
        self.userDefaults = userDefaults
    }

    func beginManualMutation() -> Generation {
        // A newer intent can invalidate an operation that is already changing disk, or one whose
        // durable result has returned to the coordinator but has not yet been published by its
        // caller. If the newer intent then terminates before its own mutation starts, it must settle
        // and reconcile that predecessor instead of leaving an older observation authoritative.
        currentGenerationNeedsPredecessorReconciliation = mutationLaneIsOccupied
            || hasUnpublishedMutationCompletion
        generationValue &+= 1
        return Generation(rawValue: generationValue)
    }

    func currentGeneration() -> Generation {
        Generation(rawValue: generationValue)
    }

    func captureStartupValidation() -> StartupValidationSnapshot {
        startupValidationEpochValue &+= 1
        return StartupValidationSnapshot(
            generation: currentGeneration(),
            epoch: startupValidationEpochValue,
            projectionRevision: projectionRevisionValue,
            persistedConnectionHint: userDefaults.bool(forKey: "AntigravityCLIConnected")
        )
    }

    /// Pre-publication freshness fence for terminal paths that can fail before `performMutation`.
    /// If this intent superseded an active mutation, wait behind the mutation lane before its caller
    /// observes durable ownership. The generation is checked on both sides of the suspension so a
    /// still-newer intent prevents stale publication.
    func isCurrent(_ generation: Generation) async -> Bool {
        guard generationIsCurrent(generation) else { return false }
        if currentGenerationNeedsPredecessorReconciliation {
            await acquireMutationLaneIgnoringCancellation()
            releaseMutationLane()
        }
        return generationIsCurrent(generation)
    }

    /// Runs one off-main-actor mutation at a time. The caller supplies the asynchronous work so
    /// production can use a detached filesystem operation and tests can install a deterministic
    /// barrier. A queued operation is discarded when a newer manual intent has already begun.
    func performMutation<Value: Sendable>(
        for generation: Generation,
        operation: @escaping @Sendable () async -> Value
    ) async -> MutationExecution<Value> {
        guard await acquireMutationLane() else { return .cancelled }
        defer { releaseMutationLane() }

        // Cancellation while queued relinquishes the transferred permit before any filesystem
        // operation can begin. Once an operation starts, its durable result must still be returned
        // so callers can reconcile partial success instead of misreporting it as cancellation.
        guard !Task.isCancelled else { return .cancelled }
        guard generationIsCurrent(generation) else { return .superseded }
        let value = await operation()
        hasUnpublishedMutationCompletion = true
        return .completed(value)
    }

    func mutationLaneState() -> MutationLaneState {
        MutationLaneState(
            isOccupied: mutationLaneIsOccupied,
            waiterCount: mutationLaneWaiters.count
        )
    }

    /// Commits an authoritative projection only for the newest manual intent, persists its hint,
    /// and broadcasts it so every window can converge on the same state.
    @discardableResult
    func publishIfCurrent(
        generation: Generation,
        isConnected: Bool,
        errorMessage: String?,
        hasOwnedMCPEntry: Bool
    ) -> Projection? {
        guard generationIsCurrent(generation) else { return nil }
        hasUnpublishedMutationCompletion = false
        currentGenerationNeedsPredecessorReconciliation = false
        return commitProjection(
            generation: generation,
            isConnected: isConnected,
            errorMessage: errorMessage,
            hasOwnedMCPEntry: hasOwnedMCPEntry,
            persistConnectionHint: true
        )
    }

    /// Reconciles a durable predecessor after the current manual intent is cancelled before its
    /// own filesystem mutation starts. The observation joins the same lane without inheriting the
    /// caller's cancellation, so it runs after the predecessor and cannot race another in-process
    /// Connect/Forget mutation. Config validity alone does not prove that `agy` is runnable, so the
    /// conservative projection remains disconnected while retaining ownership/error visibility.
    @discardableResult
    func reconcileCancelledMutationIfNeeded(
        for generation: Generation,
        observation: @escaping @Sendable () async -> CancellationReconciliationObservation
    ) async -> Projection? {
        guard generationIsCurrent(generation), currentGenerationNeedsPredecessorReconciliation else {
            return nil
        }

        await acquireMutationLaneIgnoringCancellation()
        defer { releaseMutationLane() }
        guard generationIsCurrent(generation) else { return nil }

        let currentObservation = await observation()
        guard generationIsCurrent(generation) else { return nil }

        hasUnpublishedMutationCompletion = false
        currentGenerationNeedsPredecessorReconciliation = false
        return commitProjection(
            generation: generation,
            isConnected: false,
            errorMessage: currentObservation.hasOwnedMCPEntry
                ? currentObservation.configValidationFailureMessage
                : nil,
            hasOwnedMCPEntry: currentObservation.hasOwnedMCPEntry,
            persistConnectionHint: true
        )
    }

    /// Atomically validates a startup observation against the newest startup result already
    /// published, manual-mutation generation, projection revision, and the persisted hint it
    /// originally read. Merely capturing a newer snapshot does not invalidate an older live probe:
    /// the newer window may close or be cancelled before producing any result. Startup is
    /// projection-only, so a transient revalidation failure never rewrites durable Connect/Forget
    /// intent or replaces a manual projection committed after capture.
    @discardableResult
    func publishStartupProjectionIfCurrent(
        snapshot: StartupValidationSnapshot,
        isConnected: Bool,
        errorMessage: String?,
        hasOwnedMCPEntry: Bool
    ) -> Projection? {
        guard snapshot.epoch > latestPublishedStartupEpochValue,
              generationIsCurrent(snapshot.generation),
              projectionRevisionValue == snapshot.projectionRevision,
              userDefaults.bool(forKey: "AntigravityCLIConnected") == snapshot.persistedConnectionHint
        else {
            return nil
        }
        latestPublishedStartupEpochValue = snapshot.epoch
        return commitProjection(
            generation: snapshot.generation,
            isConnected: isConnected,
            errorMessage: errorMessage,
            hasOwnedMCPEntry: hasOwnedMCPEntry,
            persistConnectionHint: false
        )
    }

    func latestProjection() -> Projection? {
        latestConnectionProjection
    }

    private func generationIsCurrent(_ generation: Generation) -> Bool {
        generation.rawValue == generationValue
    }

    private func commitProjection(
        generation: Generation,
        isConnected: Bool,
        errorMessage: String?,
        hasOwnedMCPEntry: Bool,
        persistConnectionHint: Bool
    ) -> Projection {
        projectionRevisionValue &+= 1
        let projection = Projection(
            generation: generation,
            revision: projectionRevisionValue,
            isConnected: isConnected,
            errorMessage: errorMessage,
            hasOwnedMCPEntry: hasOwnedMCPEntry
        )
        latestConnectionProjection = projection
        if persistConnectionHint {
            userDefaults.set(isConnected, forKey: "AntigravityCLIConnected")
        }
        notificationCenter.post(name: .antigravityConnectionChanged, object: nil)
        return projection
    }

    private func acquireMutationLane() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard mutationLaneIsOccupied else {
            mutationLaneIsOccupied = true
            return true
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                mutationLaneWaiters.append(
                    MutationLaneWaiter(id: waiterID, continuation: continuation)
                )
            }
        } onCancel: {
            Task { await self.cancelMutationLaneWaiter(id: waiterID) }
        }
    }

    private func acquireMutationLaneIgnoringCancellation() async {
        guard mutationLaneIsOccupied else {
            mutationLaneIsOccupied = true
            return
        }

        let _: Bool = await withCheckedContinuation { continuation in
            mutationLaneWaiters.append(
                MutationLaneWaiter(id: UUID(), continuation: continuation)
            )
        }
    }

    private func cancelMutationLaneWaiter(id: UUID) {
        guard let index = mutationLaneWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = mutationLaneWaiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func releaseMutationLane() {
        guard !mutationLaneWaiters.isEmpty else {
            mutationLaneIsOccupied = false
            return
        }
        mutationLaneWaiters.removeFirst().continuation.resume(returning: true)
    }
}
