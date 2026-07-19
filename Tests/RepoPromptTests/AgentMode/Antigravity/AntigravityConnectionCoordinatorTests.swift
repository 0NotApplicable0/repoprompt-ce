import Foundation
@testable import RepoPromptApp
import XCTest

@MainActor
final class AntigravityConnectionCoordinatorTests: XCTestCase {
    func testNewestManualMutationWinsAfterOlderMutationReleasesLane() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let oldMutationFence = TestReleaseFence(name: "older Antigravity mutation")
        defer { oldMutationFence.release() }
        let events = AntigravityConnectionEventLog()
        let oldGeneration = await fixture.coordinator.beginManualMutation()
        let oldTask = Task { () -> AntigravityConnectionCoordinator.Projection? in
            let execution = await fixture.coordinator.performMutation(for: oldGeneration) {
                await events.append("old-started")
                await oldMutationFence.enterAndWait()
                await events.append("old-finished")
                return false
            }
            guard case let .completed(isConnected) = execution else { return nil }
            return await fixture.coordinator.publishIfCurrent(
                generation: oldGeneration,
                isConnected: isConnected,
                errorMessage: "stale failure",
                hasOwnedMCPEntry: false
            )
        }

        let oldMutationEntered = await oldMutationFence.waitUntilEntered()
        XCTAssertTrue(oldMutationEntered)

        let newestGeneration = await fixture.coordinator.beginManualMutation()
        let newestTask = Task { () -> AntigravityConnectionCoordinator.Projection? in
            await events.append("new-requested")
            let execution = await fixture.coordinator.performMutation(for: newestGeneration) {
                await events.append("new-started")
                return true
            }
            guard case let .completed(isConnected) = execution else { return nil }
            return await fixture.coordinator.publishIfCurrent(
                generation: newestGeneration,
                isConnected: isConnected,
                errorMessage: nil,
                hasOwnedMCPEntry: true
            )
        }

        do {
            try await AsyncTestWait.waitUntil("newest Antigravity mutation requested") {
                await events.snapshot.contains("new-requested")
            }
        } catch {
            XCTFail(error.localizedDescription)
        }
        let eventsBeforeRelease = await events.snapshot
        XCTAssertEqual(eventsBeforeRelease, ["old-started", "new-requested"])

        oldMutationFence.release()
        let oldProjection = await oldTask.value
        let newestProjection = await newestTask.value
        let latestProjection = await fixture.coordinator.latestProjection()
        let finalEvents = await events.snapshot

        XCTAssertNil(oldProjection, "the superseded mutation must not publish after it finishes")
        XCTAssertEqual(latestProjection, newestProjection)
        XCTAssertEqual(newestProjection?.isConnected, true)
        XCTAssertEqual(newestProjection?.hasOwnedMCPEntry, true)
        XCTAssertNil(newestProjection?.errorMessage)
        XCTAssertEqual(
            finalEvents,
            ["old-started", "new-requested", "old-finished", "new-started"],
            "the serialized lane must start the newest mutation only after the older mutation exits"
        )
        XCTAssertTrue(fixture.defaults.bool(forKey: Self.connectionHintKey))
    }

    func testCancelledQueuedMutationNeverRunsAndNextWaiterAcquiresLane() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let holderFence = TestReleaseFence(name: "Antigravity mutation lane holder")
        defer { holderFence.release() }
        let events = AntigravityConnectionEventLog()
        let generation = await fixture.coordinator.beginManualMutation()
        let holderTask = Task {
            await fixture.coordinator.performMutation(for: generation) {
                await events.append("holder-started")
                await holderFence.enterAndWait()
                await events.append("holder-finished")
                return "holder"
            }
        }
        let holderEntered = await holderFence.waitUntilEntered()
        XCTAssertTrue(holderEntered)

        let cancelledTask = Task {
            await fixture.coordinator.performMutation(for: generation) {
                await events.append("cancelled-started")
                return "cancelled"
            }
        }
        try await AsyncTestWait.waitUntil("cancelled Antigravity mutation queues") {
            let state = await fixture.coordinator.mutationLaneState()
            return state.waiterCount == 1
        }
        let followerTask = Task {
            await fixture.coordinator.performMutation(for: generation) {
                await events.append("follower-started")
                return "follower"
            }
        }
        try await AsyncTestWait.waitUntil("follower Antigravity mutation queues") {
            let state = await fixture.coordinator.mutationLaneState()
            return state.waiterCount == 2
        }

        cancelledTask.cancel()
        try await AsyncTestWait.waitUntil("cancelled Antigravity waiter is removed") {
            let state = await fixture.coordinator.mutationLaneState()
            return state.waiterCount == 1
        }
        let cancelledResult = await cancelledTask.value
        guard case .cancelled = cancelledResult else {
            XCTFail("queued cancelled mutation must return cancelled")
            return
        }

        holderFence.release()
        let holderResult = await holderTask.value
        let followerResult = await followerTask.value
        guard case let .completed(holderValue) = holderResult,
              case let .completed(followerValue) = followerResult
        else {
            XCTFail("holder and follower mutations should complete")
            return
        }
        let finalEvents = await events.snapshot
        let finalLaneState = await fixture.coordinator.mutationLaneState()

        XCTAssertEqual(holderValue, "holder")
        XCTAssertEqual(followerValue, "follower")
        XCTAssertEqual(finalEvents, ["holder-started", "holder-finished", "follower-started"])
        XCTAssertEqual(
            finalLaneState,
            .init(isOccupied: false, waiterCount: 0),
            "cancelling a queued waiter must not leak its continuation or transferred permit"
        )
    }

    func testCancelledQueuedConnectReconcilesOlderForgetOutcome() async throws {
        let fixture = try makeFixture(persistedConnectionHint: true)
        defer { fixture.cleanup() }
        let forgetFence = TestReleaseFence(name: "older Antigravity Forget mutation")
        defer { forgetFence.release() }
        let liveObservation = AntigravityConnectionObservationState(
            .init(
                configValidationFailureMessage: nil,
                hasRecordedOwnershipMarker: true
            )
        )
        let forgettingViewModel = makeViewModel(
            fixture: fixture,
            connectionObservation: { await liveObservation.read() },
            removal: {
                await forgetFence.enterAndWait()
                await liveObservation.set(
                    .init(
                        configValidationFailureMessage: "RepoPrompt MCP entry is absent.",
                        hasRecordedOwnershipMarker: false
                    )
                )
                return (.removed, false)
            }
        )
        let connectingViewModel = makeViewModel(
            fixture: fixture,
            connectionObservation: { await liveObservation.read() },
            manualVersionProbe: { 0 }
        )
        let connectedGeneration = await fixture.coordinator.beginManualMutation()
        _ = await fixture.coordinator.publishIfCurrent(
            generation: connectedGeneration,
            isConnected: true,
            errorMessage: nil,
            hasOwnedMCPEntry: true
        )
        await assertEventually("both Settings windows seed connected Antigravity state") {
            forgettingViewModel.isAntigravityConnected
                && connectingViewModel.isAntigravityConnected
                && forgettingViewModel.hasOwnedAntigravityMCPEntry
                && connectingViewModel.hasOwnedAntigravityMCPEntry
        }

        let forgetTask = Task { @MainActor in
            await forgettingViewModel.disconnectAntigravity()
        }
        let forgetEntered = await forgetFence.waitUntilEntered()
        XCTAssertTrue(forgetEntered)

        let connectTask = Task { @MainActor in
            do {
                _ = try await connectingViewModel.testAntigravityConnection()
                XCTFail("queued Connect should not complete after cancellation")
                return false
            } catch is CancellationError {
                return true
            } catch {
                XCTFail("unexpected queued Connect cancellation error: \(error)")
                return false
            }
        }
        try await AsyncTestWait.waitUntil("newer Antigravity Connect queues behind Forget") {
            let lane = await fixture.coordinator.mutationLaneState()
            return lane.waiterCount == 1
        }

        connectTask.cancel()
        forgetFence.release()
        _ = await forgetTask.value
        let connectWasCancelled = await connectTask.value

        XCTAssertTrue(connectWasCancelled)
        await assertEventually("cancelled Connect reconciles the completed Forget in every window") {
            !forgettingViewModel.isAntigravityConnected
                && !connectingViewModel.isAntigravityConnected
                && !forgettingViewModel.hasOwnedAntigravityMCPEntry
                && !connectingViewModel.hasOwnedAntigravityMCPEntry
                && forgettingViewModel.antigravityError == nil
                && connectingViewModel.antigravityError == nil
        }
        let projection = await fixture.coordinator.latestProjection()
        let lane = await fixture.coordinator.mutationLaneState()
        XCTAssertEqual(projection?.isConnected, false)
        XCTAssertEqual(projection?.hasOwnedMCPEntry, false)
        XCTAssertNil(projection?.errorMessage)
        XCTAssertFalse(fixture.defaults.bool(forKey: Self.connectionHintKey))
        XCTAssertEqual(lane, .init(isOccupied: false, waiterCount: 0))
    }

    func testFailedConnectWaitsForOlderForgetBeforePublishingOwnership() async throws {
        let fixture = try makeFixture(persistedConnectionHint: true)
        defer { fixture.cleanup() }
        let forgetFence = TestReleaseFence(name: "older Antigravity Forget mutation")
        defer { forgetFence.release() }
        let events = AntigravityConnectionEventLog()
        let failureMessage = "Antigravity version probe failed."
        let liveObservation = AntigravityConnectionObservationState(
            .init(
                configValidationFailureMessage: nil,
                hasRecordedOwnershipMarker: true
            )
        )
        let forgettingViewModel = makeViewModel(
            fixture: fixture,
            connectionObservation: { await liveObservation.read() },
            removal: {
                await forgetFence.enterAndWait()
                await liveObservation.set(
                    .init(
                        configValidationFailureMessage: "RepoPrompt MCP entry is absent.",
                        hasRecordedOwnershipMarker: false
                    )
                )
                return (.removed, false)
            }
        )
        let connectingViewModel = makeViewModel(
            fixture: fixture,
            connectionObservation: { await liveObservation.read() },
            manualVersionProbe: {
                await events.append("probe-failed")
                throw AIProviderError.invalidConfiguration(detail: failureMessage)
            }
        )
        let connectedGeneration = await fixture.coordinator.beginManualMutation()
        _ = await fixture.coordinator.publishIfCurrent(
            generation: connectedGeneration,
            isConnected: true,
            errorMessage: nil,
            hasOwnedMCPEntry: true
        )
        await assertEventually("both Settings windows seed connected Antigravity state") {
            forgettingViewModel.isAntigravityConnected
                && connectingViewModel.isAntigravityConnected
                && forgettingViewModel.hasOwnedAntigravityMCPEntry
                && connectingViewModel.hasOwnedAntigravityMCPEntry
        }

        let forgetTask = Task { @MainActor in
            await forgettingViewModel.disconnectAntigravity()
        }
        let forgetEntered = await forgetFence.waitUntilEntered()
        XCTAssertTrue(forgetEntered)

        let connectTask = Task { @MainActor in
            do {
                _ = try await connectingViewModel.testAntigravityConnection()
                XCTFail("failed Connect should throw")
            } catch {
                await events.append("connect-failed")
            }
        }
        try await AsyncTestWait.waitUntil("failed Connect reaches predecessor-settlement boundary") {
            let lane = await fixture.coordinator.mutationLaneState()
            let snapshot = await events.snapshot
            return lane.waiterCount == 1 || snapshot.contains("connect-failed")
        }
        let laneBeforeForgetRelease = await fixture.coordinator.mutationLaneState()
        let eventsBeforeForgetRelease = await events.snapshot

        XCTAssertEqual(laneBeforeForgetRelease.waiterCount, 1)
        XCTAssertEqual(eventsBeforeForgetRelease, ["probe-failed"])

        forgetFence.release()
        _ = await forgetTask.value
        await connectTask.value

        await assertEventually("failed Connect publishes ownership after Forget settles") {
            !forgettingViewModel.isAntigravityConnected
                && !connectingViewModel.isAntigravityConnected
                && !forgettingViewModel.hasOwnedAntigravityMCPEntry
                && !connectingViewModel.hasOwnedAntigravityMCPEntry
                && forgettingViewModel.antigravityError == failureMessage
                && connectingViewModel.antigravityError == failureMessage
        }
        let projection = await fixture.coordinator.latestProjection()
        let finalLane = await fixture.coordinator.mutationLaneState()
        XCTAssertEqual(projection?.isConnected, false)
        XCTAssertEqual(projection?.hasOwnedMCPEntry, false)
        XCTAssertEqual(projection?.errorMessage, failureMessage)
        XCTAssertFalse(fixture.defaults.bool(forKey: Self.connectionHintKey))
        XCTAssertEqual(finalLane, .init(isOccupied: false, waiterCount: 0))
    }

    func testSharedCoordinatorConvergesTwoViewModelsOnLatestProjection() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let firstViewModel = makeViewModel(fixture: fixture)
        let secondViewModel = makeViewModel(fixture: fixture)

        let staleGeneration = await fixture.coordinator.beginManualMutation()
        let newestGeneration = await fixture.coordinator.beginManualMutation()
        let newestProjection = await fixture.coordinator.publishIfCurrent(
            generation: newestGeneration,
            isConnected: true,
            errorMessage: nil,
            hasOwnedMCPEntry: true
        )
        let staleProjection = await fixture.coordinator.publishIfCurrent(
            generation: staleGeneration,
            isConnected: false,
            errorMessage: "stale failure",
            hasOwnedMCPEntry: false
        )

        XCTAssertNotNil(newestProjection)
        XCTAssertNil(staleProjection)
        await assertEventually("both Antigravity Settings consumers apply the latest projection") {
            firstViewModel.isAntigravityConnected
                && firstViewModel.hasOwnedAntigravityMCPEntry
                && firstViewModel.antigravityError == nil
                && secondViewModel.isAntigravityConnected
                && secondViewModel.hasOwnedAntigravityMCPEntry
                && secondViewModel.antigravityError == nil
        }

        let latestProjection = await fixture.coordinator.latestProjection()
        XCTAssertEqual(latestProjection, newestProjection)
        XCTAssertTrue(firstViewModel.contextBuilderVerifiedCLIProviders.contains(.antigravity))
        XCTAssertTrue(secondViewModel.contextBuilderVerifiedCLIProviders.contains(.antigravity))
        XCTAssertTrue(fixture.defaults.bool(forKey: Self.connectionHintKey))
    }

    func testBlockedStartupFailureIsDiscardedAfterManualGenerationChange() async throws {
        let fixture = try makeFixture(persistedConnectionHint: true)
        defer { fixture.cleanup() }
        let startupProbeFence = TestReleaseFence(name: "Antigravity startup probe")
        defer { startupProbeFence.release() }
        let viewModel = makeViewModel(
            fixture: fixture,
            cachedConnectionProbe: { shouldProbe in
                guard shouldProbe else { return .notRequested }
                await startupProbeFence.enterAndWait()
                return .failed("stale startup failure")
            },
            connectionObservation: {
                .init(
                    configValidationFailureMessage: nil,
                    hasRecordedOwnershipMarker: true
                )
            }
        )
        viewModel.isClaudeCodeConnected = false
        viewModel.isCodexConnected = false
        viewModel.isOpenCodeConnected = false
        viewModel.isCursorConnected = false

        let validationTask = Task { @MainActor in
            await viewModel.validateCachedContextBuilderProvidersIfNeeded()
        }
        let startupProbeEntered = await startupProbeFence.waitUntilEntered()
        XCTAssertTrue(startupProbeEntered)

        let manualGeneration = await fixture.coordinator.beginManualMutation()
        let persistedHintWhileBlocked = fixture.defaults.bool(forKey: Self.connectionHintKey)
        XCTAssertTrue(persistedHintWhileBlocked)

        startupProbeFence.release()
        await validationTask.value

        let generationIsCurrent = await fixture.coordinator.isCurrent(manualGeneration)
        let latestProjection = await fixture.coordinator.latestProjection()
        XCTAssertTrue(generationIsCurrent)
        XCTAssertNil(latestProjection, "the stale startup failure must not become shared state")
        XCTAssertFalse(viewModel.isAntigravityConnected)
        XCTAssertNil(viewModel.antigravityError)
        XCTAssertFalse(viewModel.hasOwnedAntigravityMCPEntry)
        XCTAssertFalse(viewModel.contextBuilderVerifiedCLIProviders.contains(.antigravity))
        XCTAssertTrue(viewModel.isContextBuilderProviderValidationComplete)
        XCTAssertTrue(
            fixture.defaults.bool(forKey: Self.connectionHintKey),
            "discarding stale startup work must not clear the unchanged persisted hint"
        )
    }

    func testManualProjectionSupersedesSameGenerationStartupSnapshotWithoutHintChange() async throws {
        let fixture = try makeFixture(persistedConnectionHint: true)
        defer { fixture.cleanup() }
        let firstViewModel = makeViewModel(fixture: fixture)
        let secondViewModel = makeViewModel(fixture: fixture)

        let manualGeneration = await fixture.coordinator.beginManualMutation()
        let staleStartupSnapshot = await fixture.coordinator.captureStartupValidation()
        XCTAssertEqual(staleStartupSnapshot.generation, manualGeneration)
        XCTAssertTrue(staleStartupSnapshot.persistedConnectionHint)

        let manualProjection = await fixture.coordinator.publishIfCurrent(
            generation: manualGeneration,
            isConnected: true,
            errorMessage: nil,
            hasOwnedMCPEntry: true
        )
        XCTAssertNotNil(manualProjection)
        await assertEventually("both Settings windows apply the manual Antigravity projection") {
            firstViewModel.isAntigravityConnected
                && firstViewModel.antigravityError == nil
                && firstViewModel.hasOwnedAntigravityMCPEntry
                && secondViewModel.isAntigravityConnected
                && secondViewModel.antigravityError == nil
                && secondViewModel.hasOwnedAntigravityMCPEntry
        }
        XCTAssertTrue(fixture.defaults.bool(forKey: Self.connectionHintKey))

        let staleStartupProjection = await fixture.coordinator.publishStartupProjectionIfCurrent(
            snapshot: staleStartupSnapshot,
            isConnected: false,
            errorMessage: "stale startup failure",
            hasOwnedMCPEntry: false
        )
        let latestProjection = await fixture.coordinator.latestProjection()

        XCTAssertNil(staleStartupProjection)
        XCTAssertEqual(latestProjection, manualProjection)
        XCTAssertTrue(firstViewModel.isAntigravityConnected)
        XCTAssertNil(firstViewModel.antigravityError)
        XCTAssertTrue(firstViewModel.hasOwnedAntigravityMCPEntry)
        XCTAssertTrue(secondViewModel.isAntigravityConnected)
        XCTAssertNil(secondViewModel.antigravityError)
        XCTAssertTrue(secondViewModel.hasOwnedAntigravityMCPEntry)
        XCTAssertTrue(fixture.defaults.bool(forKey: Self.connectionHintKey))
    }

    func testStartupProjectionIsDiscardedWhenPersistedHintDriftsWithoutGenerationChange() async throws {
        let fixture = try makeFixture(persistedConnectionHint: true)
        defer { fixture.cleanup() }
        let snapshot = await fixture.coordinator.captureStartupValidation()
        fixture.defaults.set(false, forKey: Self.connectionHintKey)

        let projection = await fixture.coordinator.publishStartupProjectionIfCurrent(
            snapshot: snapshot,
            isConnected: false,
            errorMessage: "stale startup failure",
            hasOwnedMCPEntry: true
        )
        let latestProjection = await fixture.coordinator.latestProjection()

        XCTAssertNil(projection)
        XCTAssertNil(latestProjection)
        XCTAssertFalse(fixture.defaults.bool(forKey: Self.connectionHintKey))
    }

    func testNewerStartupSnapshotSupersedesOlderSnapshot() async throws {
        let fixture = try makeFixture(persistedConnectionHint: true)
        defer { fixture.cleanup() }
        let firstSnapshot = await fixture.coordinator.captureStartupValidation()
        let secondSnapshot = await fixture.coordinator.captureStartupValidation()

        let secondProjection = await fixture.coordinator.publishStartupProjectionIfCurrent(
            snapshot: secondSnapshot,
            isConnected: true,
            errorMessage: nil,
            hasOwnedMCPEntry: true
        )
        let firstProjection = await fixture.coordinator.publishStartupProjectionIfCurrent(
            snapshot: firstSnapshot,
            isConnected: false,
            errorMessage: "stale startup failure",
            hasOwnedMCPEntry: false
        )
        let latestProjection = await fixture.coordinator.latestProjection()

        XCTAssertNil(firstProjection)
        XCTAssertNotNil(secondProjection)
        XCTAssertEqual(latestProjection, secondProjection)
        XCTAssertEqual(latestProjection?.hasOwnedMCPEntry, true)
    }

    func testUnpublishedNewerStartupSnapshotDoesNotInvalidateOlderLiveResult() async throws {
        let fixture = try makeFixture(persistedConnectionHint: true)
        defer { fixture.cleanup() }
        let olderSnapshot = await fixture.coordinator.captureStartupValidation()
        _ = await fixture.coordinator.captureStartupValidation()

        let olderProjection = await fixture.coordinator.publishStartupProjectionIfCurrent(
            snapshot: olderSnapshot,
            isConnected: true,
            errorMessage: nil,
            hasOwnedMCPEntry: true
        )
        let latestProjection = await fixture.coordinator.latestProjection()

        XCTAssertNotNil(olderProjection)
        XCTAssertEqual(latestProjection, olderProjection)
        XCTAssertTrue(fixture.defaults.bool(forKey: Self.connectionHintKey))
    }

    func testNewerStartupValidationSupersedesOlderBlockedValidation() async throws {
        let fixture = try makeFixture(persistedConnectionHint: true)
        defer { fixture.cleanup() }
        let olderProbeFence = TestReleaseFence(name: "older Antigravity startup validation")
        defer { olderProbeFence.release() }
        let olderViewModel = makeViewModel(
            fixture: fixture,
            cachedConnectionProbe: { shouldProbe in
                guard shouldProbe else { return .notRequested }
                await olderProbeFence.enterAndWait()
                return .failed("older startup failure")
            },
            connectionObservation: {
                .init(
                    configValidationFailureMessage: nil,
                    hasRecordedOwnershipMarker: true
                )
            }
        )
        let newerViewModel = makeViewModel(
            fixture: fixture,
            cachedConnectionProbe: { shouldProbe in
                shouldProbe ? .ready : .notRequested
            },
            connectionObservation: {
                .init(
                    configValidationFailureMessage: nil,
                    hasRecordedOwnershipMarker: true
                )
            }
        )
        isolateAntigravityValidation(olderViewModel, newerViewModel)

        let olderTask = Task { @MainActor in
            await olderViewModel.validateCachedContextBuilderProvidersIfNeeded()
        }
        let olderProbeEntered = await olderProbeFence.waitUntilEntered()
        XCTAssertTrue(olderProbeEntered)

        await newerViewModel.validateCachedContextBuilderProvidersIfNeeded()
        let newerProjection = await fixture.coordinator.latestProjection()
        XCTAssertEqual(newerProjection?.isConnected, true)
        XCTAssertNil(newerProjection?.errorMessage)

        olderProbeFence.release()
        await olderTask.value
        let finalProjection = await fixture.coordinator.latestProjection()

        XCTAssertEqual(finalProjection, newerProjection)
        await assertEventually("older Settings window receives the newer startup projection") {
            olderViewModel.isAntigravityConnected
                && olderViewModel.antigravityError == nil
                && olderViewModel.hasOwnedAntigravityMCPEntry
        }
        XCTAssertTrue(fixture.defaults.bool(forKey: Self.connectionHintKey))
    }

    func testTransientStartupFailureRetainsHintForLaterRetry() async throws {
        let fixture = try makeFixture(persistedConnectionHint: true)
        defer { fixture.cleanup() }
        let transientMessage = "temporary agy startup failure"
        let failingViewModel = makeViewModel(
            fixture: fixture,
            cachedConnectionProbe: { shouldProbe in
                shouldProbe ? .failed(transientMessage) : .notRequested
            },
            connectionObservation: {
                .init(
                    configValidationFailureMessage: nil,
                    hasRecordedOwnershipMarker: true
                )
            }
        )
        isolateAntigravityValidation(failingViewModel)

        await failingViewModel.validateCachedContextBuilderProvidersIfNeeded()

        XCTAssertFalse(failingViewModel.isAntigravityConnected)
        XCTAssertEqual(failingViewModel.antigravityError, transientMessage)
        XCTAssertTrue(failingViewModel.hasOwnedAntigravityMCPEntry)
        XCTAssertTrue(
            fixture.defaults.bool(forKey: Self.connectionHintKey),
            "transient startup failure must retain durable manual Connect intent"
        )

        let retryViewModel = makeViewModel(
            fixture: fixture,
            cachedConnectionProbe: { shouldProbe in
                shouldProbe ? .ready : .notRequested
            },
            connectionObservation: {
                .init(
                    configValidationFailureMessage: nil,
                    hasRecordedOwnershipMarker: true
                )
            }
        )
        isolateAntigravityValidation(retryViewModel)
        await retryViewModel.validateCachedContextBuilderProvidersIfNeeded()

        await assertEventually("later startup retry clears the transient failure in every window") {
            failingViewModel.isAntigravityConnected
                && failingViewModel.antigravityError == nil
                && retryViewModel.isAntigravityConnected
                && retryViewModel.antigravityError == nil
        }
        XCTAssertTrue(fixture.defaults.bool(forKey: Self.connectionHintKey))
    }

    func testCancelledStartupVersionProbePreservesProjectionAndDurableHint() async throws {
        let fixture = try makeFixture(persistedConnectionHint: true)
        defer { fixture.cleanup() }
        let generation = await fixture.coordinator.beginManualMutation()
        let existingProjection = await fixture.coordinator.publishIfCurrent(
            generation: generation,
            isConnected: true,
            errorMessage: nil,
            hasOwnedMCPEntry: true
        )
        let observationEvents = AntigravityConnectionEventLog()
        let viewModel = makeViewModel(
            fixture: fixture,
            cachedConnectionProbe: { shouldProbe in
                shouldProbe ? .cancelled : .notRequested
            },
            connectionObservation: {
                await observationEvents.append("observed")
                return .init(
                    configValidationFailureMessage: "must not publish",
                    hasRecordedOwnershipMarker: false
                )
            }
        )
        isolateAntigravityValidation(viewModel)
        await assertEventually("Settings window seeds existing Antigravity connection") {
            viewModel.isAntigravityConnected && viewModel.hasOwnedAntigravityMCPEntry
        }

        await viewModel.validateCachedContextBuilderProvidersIfNeeded()

        let finalProjection = await fixture.coordinator.latestProjection()
        let observationEventSnapshot = await observationEvents.snapshot
        XCTAssertEqual(finalProjection, existingProjection)
        XCTAssertEqual(observationEventSnapshot, [])
        XCTAssertTrue(viewModel.isAntigravityConnected)
        XCTAssertNil(viewModel.antigravityError)
        XCTAssertTrue(viewModel.hasOwnedAntigravityMCPEntry)
        XCTAssertTrue(fixture.defaults.bool(forKey: Self.connectionHintKey))
    }

    func testCancelledManualVersionProbePreservesProjectionAndDurableHint() async throws {
        let fixture = try makeFixture(persistedConnectionHint: true)
        defer { fixture.cleanup() }
        let generation = await fixture.coordinator.beginManualMutation()
        let existingProjection = await fixture.coordinator.publishIfCurrent(
            generation: generation,
            isConnected: true,
            errorMessage: nil,
            hasOwnedMCPEntry: true
        )
        let versionProbeFence = TestReleaseFence(name: "cancelled Antigravity version probe")
        defer { versionProbeFence.release() }
        let viewModel = makeViewModel(
            fixture: fixture,
            manualVersionProbe: {
                await versionProbeFence.enterAndWait()
                try Task.checkCancellation()
                return 0
            }
        )
        await assertEventually("Settings window seeds existing Antigravity connection") {
            viewModel.isAntigravityConnected && viewModel.hasOwnedAntigravityMCPEntry
        }

        let connectTask = Task { @MainActor in
            try await viewModel.testAntigravityConnection()
        }
        let versionProbeEntered = await versionProbeFence.waitUntilEntered()
        XCTAssertTrue(versionProbeEntered)
        connectTask.cancel()
        versionProbeFence.release()

        do {
            _ = try await connectTask.value
            XCTFail("cancelled version probe should throw CancellationError")
        } catch is CancellationError {
            // Expected: cancellation before config mutation is not a connection failure.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }

        let finalProjection = await fixture.coordinator.latestProjection()
        XCTAssertEqual(finalProjection, existingProjection)
        XCTAssertTrue(viewModel.isAntigravityConnected)
        XCTAssertNil(viewModel.antigravityError)
        XCTAssertTrue(viewModel.hasOwnedAntigravityMCPEntry)
        XCTAssertTrue(fixture.defaults.bool(forKey: Self.connectionHintKey))
    }

    func testFinalConfigDriftPreventsReadyStartupFromPublishingConnected() async throws {
        let fixture = try makeFixture(persistedConnectionHint: true)
        defer { fixture.cleanup() }
        let driftMessage = "Antigravity MCP config changed after the CLI probe."
        let viewModel = makeViewModel(
            fixture: fixture,
            cachedConnectionProbe: { shouldProbe in
                shouldProbe ? .ready : .notRequested
            },
            connectionObservation: {
                .init(
                    configValidationFailureMessage: driftMessage,
                    hasRecordedOwnershipMarker: true
                )
            }
        )
        isolateAntigravityValidation(viewModel)

        await viewModel.validateCachedContextBuilderProvidersIfNeeded()

        let projection = await fixture.coordinator.latestProjection()
        XCTAssertEqual(projection?.isConnected, false)
        XCTAssertEqual(projection?.errorMessage, driftMessage)
        XCTAssertEqual(projection?.hasOwnedMCPEntry, true)
        XCTAssertFalse(viewModel.isAntigravityConnected)
        XCTAssertEqual(viewModel.antigravityError, driftMessage)
        XCTAssertTrue(fixture.defaults.bool(forKey: Self.connectionHintKey))
    }

    func testHintFalseNoProbeStartupPreservesLatestErrorProjection() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let existingMessage = "Forget needs to be retried."
        let generation = await fixture.coordinator.beginManualMutation()
        let existingProjection = await fixture.coordinator.publishIfCurrent(
            generation: generation,
            isConnected: false,
            errorMessage: existingMessage,
            hasOwnedMCPEntry: true
        )
        let observationEvents = AntigravityConnectionEventLog()
        let viewModel = makeViewModel(
            fixture: fixture,
            cachedConnectionProbe: { shouldProbe in
                shouldProbe ? .ready : .notRequested
            },
            connectionObservation: {
                await observationEvents.append("observed")
                return .init(
                    configValidationFailureMessage: nil,
                    hasRecordedOwnershipMarker: false
                )
            }
        )
        isolateAntigravityValidation(viewModel)
        await assertEventually("Settings window seeds the existing Antigravity failure") {
            viewModel.antigravityError == existingMessage
                && viewModel.hasOwnedAntigravityMCPEntry
        }

        await viewModel.validateCachedContextBuilderProvidersIfNeeded()

        let finalProjection = await fixture.coordinator.latestProjection()
        let observationEventSnapshot = await observationEvents.snapshot
        XCTAssertEqual(finalProjection, existingProjection)
        XCTAssertEqual(viewModel.antigravityError, existingMessage)
        XCTAssertTrue(viewModel.hasOwnedAntigravityMCPEntry)
        XCTAssertEqual(observationEventSnapshot, [])
        XCTAssertFalse(fixture.defaults.bool(forKey: Self.connectionHintKey))
    }

    func testHintFalseStartupDiscoversRetainedOwnershipWithoutExistingProjection() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let observationEvents = AntigravityConnectionEventLog()
        let viewModel = makeViewModel(
            fixture: fixture,
            cachedConnectionProbe: { shouldProbe in
                shouldProbe ? .ready : .notRequested
            },
            connectionObservation: {
                await observationEvents.append("observed")
                return .init(
                    configValidationFailureMessage: nil,
                    hasRecordedOwnershipMarker: true
                )
            }
        )
        isolateAntigravityValidation(viewModel)

        await viewModel.validateCachedContextBuilderProvidersIfNeeded()

        let projection = await fixture.coordinator.latestProjection()
        let observedEvents = await observationEvents.snapshot
        XCTAssertEqual(observedEvents, ["observed"])
        XCTAssertEqual(projection?.isConnected, false)
        XCTAssertNil(projection?.errorMessage)
        XCTAssertEqual(projection?.hasOwnedMCPEntry, true)
        XCTAssertFalse(viewModel.isAntigravityConnected)
        XCTAssertTrue(viewModel.hasOwnedAntigravityMCPEntry)
        XCTAssertFalse(fixture.defaults.bool(forKey: Self.connectionHintKey))
    }

    func testForgetFailurePublishesErrorToAllWindowsAndPreservesOwnership() async throws {
        let fixture = try makeFixture(persistedConnectionHint: true)
        defer { fixture.cleanup() }
        let failureMessage = "Antigravity ownership store is busy."
        let firstViewModel = makeViewModel(
            fixture: fixture,
            removal: { (.failed(failureMessage), true) }
        )
        let secondViewModel = makeViewModel(fixture: fixture)
        let connectedGeneration = await fixture.coordinator.beginManualMutation()
        _ = await fixture.coordinator.publishIfCurrent(
            generation: connectedGeneration,
            isConnected: true,
            errorMessage: nil,
            hasOwnedMCPEntry: true
        )
        await assertEventually("both Settings windows seed connected Antigravity state") {
            firstViewModel.isAntigravityConnected && secondViewModel.isAntigravityConnected
        }

        let result = await firstViewModel.disconnectAntigravity()

        guard case let .failed(message) = result else {
            XCTFail("expected failed Forget result")
            return
        }
        XCTAssertEqual(message, failureMessage)
        await assertEventually("Forget failure reaches every Settings window") {
            !firstViewModel.isAntigravityConnected
                && firstViewModel.antigravityError == failureMessage
                && firstViewModel.hasOwnedAntigravityMCPEntry
                && !secondViewModel.isAntigravityConnected
                && secondViewModel.antigravityError == failureMessage
                && secondViewModel.hasOwnedAntigravityMCPEntry
        }
        XCTAssertFalse(fixture.defaults.bool(forKey: Self.connectionHintKey))
    }

    func testViewModelCreatedAfterProjectionSeedsLatestState() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let generation = await fixture.coordinator.beginManualMutation()
        let projection = await fixture.coordinator.publishIfCurrent(
            generation: generation,
            isConnected: true,
            errorMessage: nil,
            hasOwnedMCPEntry: true
        )
        XCTAssertNotNil(projection)

        let viewModel = makeViewModel(fixture: fixture)
        await assertEventually("late-created Antigravity Settings consumer seeds shared projection") {
            viewModel.isAntigravityConnected
                && viewModel.hasOwnedAntigravityMCPEntry
                && viewModel.antigravityError == nil
        }

        XCTAssertTrue(viewModel.contextBuilderVerifiedCLIProviders.contains(.antigravity))
    }

    private static let connectionHintKey = "AntigravityCLIConnected"

    private func makeFixture(
        persistedConnectionHint: Bool = false
    ) throws -> AntigravityConnectionTestFixture {
        let suiteName = "AntigravityConnectionCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(persistedConnectionHint, forKey: Self.connectionHintKey)
        let notificationCenter = NotificationCenter()
        return AntigravityConnectionTestFixture(
            suiteName: suiteName,
            defaults: defaults,
            notificationCenter: notificationCenter,
            coordinator: AntigravityConnectionCoordinator(
                notificationCenter: notificationCenter,
                userDefaults: defaults
            )
        )
    }

    private func makeViewModel(
        fixture: AntigravityConnectionTestFixture,
        cachedConnectionProbe: (@MainActor @Sendable (Bool) async -> APISettingsViewModel.CachedAntigravityConnectionProbeResult)? = nil,
        connectionObservation: (@Sendable () async -> MCPIntegrationHelper.AntigravityConnectionObservation)? = nil,
        removal: (@Sendable () async -> (MCPIntegrationHelper.AntigravityRemovalResult, Bool))? = nil,
        manualVersionProbe: (@MainActor @Sendable () async throws -> Int32)? = nil
    ) -> APISettingsViewModel {
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        return APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false,
            antigravityConnectionCoordinator: fixture.coordinator,
            notificationCenter: fixture.notificationCenter,
            antigravityCachedConnectionProbeOverride: cachedConnectionProbe,
            antigravityConnectionObservationOverride: connectionObservation,
            antigravityRemovalOverride: removal,
            antigravityManualVersionProbeOverride: manualVersionProbe
        )
    }

    private func isolateAntigravityValidation(_ viewModels: APISettingsViewModel...) {
        for viewModel in viewModels {
            viewModel.isClaudeCodeConnected = false
            viewModel.isCodexConnected = false
            viewModel.isOpenCodeConnected = false
            viewModel.isCursorConnected = false
        }
    }

    private func assertEventually(
        _ description: String,
        condition: @escaping @MainActor () -> Bool
    ) async {
        do {
            try await AsyncTestWait.waitUntil(description) {
                await condition()
            }
        } catch {
            XCTFail(error.localizedDescription)
        }
    }
}

private struct AntigravityConnectionTestFixture {
    let suiteName: String
    let defaults: UserDefaults
    let notificationCenter: NotificationCenter
    let coordinator: AntigravityConnectionCoordinator

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private actor AntigravityConnectionEventLog {
    private var events: [String] = []

    var snapshot: [String] {
        events
    }

    func append(_ event: String) {
        events.append(event)
    }
}

private actor AntigravityConnectionObservationState {
    private var observation: MCPIntegrationHelper.AntigravityConnectionObservation

    init(_ observation: MCPIntegrationHelper.AntigravityConnectionObservation) {
        self.observation = observation
    }

    func read() -> MCPIntegrationHelper.AntigravityConnectionObservation {
        observation
    }

    func set(_ observation: MCPIntegrationHelper.AntigravityConnectionObservation) {
        self.observation = observation
    }
}
