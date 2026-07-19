@testable import RepoPromptApp
import XCTest

/// Contract: `AntigravityRunGate` and the request coordinator enforce the single-run-at-a-time
/// invariant that agy conversation-DB attribution depends on. A second `lock()` must park FIFO, and
/// cancellation/replacement/disposal must either atomically transfer ownership to a registered
/// producer or release the gate without launching stale work.
final class AntigravityRunGateTests: XCTestCase {
    private actor EventLog {
        private(set) var events: [String] = []
        func append(_ event: String) {
            events.append(event)
        }
    }

    private actor AsyncBarrier {
        private(set) var isPaused = false
        private var isReleased = false
        private var continuation: CheckedContinuation<Void, Never>?

        func pause() async {
            isPaused = true
            guard !isReleased else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            isReleased = true
            continuation?.resume()
            continuation = nil
        }
    }

    func testSecondAcquirerParksUntilUnlock() async throws {
        let gate = AntigravityRunGate()
        try await gate.lock() // first holder owns the gate

        let log = EventLog()
        let second = Task {
            try await gate.lock()
            await log.append("acquired")
            await gate.unlock()
        }

        // Deterministically wait until `second` is parked on the gate (no sleep): observe the
        // actual waiter count rather than guessing a delay.
        try await AsyncTestWait.waitUntil("second Antigravity run queued") {
            await gate.waiterCount == 1
        }

        // Holder still owns the gate, so the waiter must not have acquired yet.
        let beforeRelease = await log.events
        XCTAssertEqual(beforeRelease, [], "second acquirer must park while the gate is held")

        await log.append("released")
        await gate.unlock() // wake the parked waiter
        try await second.value

        let finalEvents = await log.events
        XCTAssertEqual(
            finalEvents,
            ["released", "acquired"],
            "the waiter must proceed only after the holder releases"
        )

        // Gate is reusable after the waiter cycle completes (no permanent lock).
        try await gate.lock()
        let parkedAfterReuse = await gate.waiterCount
        await gate.unlock()
        XCTAssertEqual(parkedAfterReuse, 0, "an uncontended re-lock must acquire immediately")
    }

    func testCancelledWaiterIsRemovedWithoutReleasingHolder() async throws {
        let gate = AntigravityRunGate()
        try await gate.lock()

        let cancellationFinished = expectation(description: "queued acquisition cancelled")
        let waiter = Task { () -> String in
            defer { cancellationFinished.fulfill() }
            do {
                try await gate.lock()
                await gate.unlock()
                return "acquired"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "unexpected: \(error.localizedDescription)"
            }
        }

        try await AsyncTestWait.waitUntil("cancelled Antigravity run queued") {
            await gate.waiterCount == 1
        }
        waiter.cancel()
        await fulfillment(of: [cancellationFinished], timeout: 1)

        let waiterCountAfterCancellation = await gate.waiterCount
        let isLockedAfterCancellation = await gate.isLocked
        XCTAssertEqual(waiterCountAfterCancellation, 0, "cancelled work must leave the FIFO queue promptly")
        XCTAssertTrue(isLockedAfterCancellation, "cancelling a waiter must not release the current holder")

        await gate.unlock()
        let waiterResult = await waiter.value
        let isLockedAfterUnlock = await gate.isLocked
        XCTAssertEqual(waiterResult, "cancelled")
        XCTAssertFalse(isLockedAfterUnlock)

        try await gate.lock()
        let isLockedAfterReuse = await gate.isLocked
        XCTAssertTrue(isLockedAfterReuse, "the gate must remain reusable after waiter cancellation")
        await gate.unlock()
    }

    func testCancellationAfterGateHandoffReleasesPermitBeforeStreamTransfer() async throws {
        let gate = AntigravityRunGate()
        try await gate.lock()
        let beforeCancellationCheck = AsyncBarrier()

        let acquirer = Task { () -> Bool in
            do {
                try await AntigravityAgentProvider.acquireRunGate(
                    gate,
                    beforeCancellationCheck: { await beforeCancellationCheck.pause() }
                )
                await gate.unlock()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        try await AsyncTestWait.waitUntil("Antigravity stream acquisition queued") {
            await gate.waiterCount == 1
        }
        await gate.unlock()
        try await AsyncTestWait.waitUntil("Antigravity stream acquired gate before cancellation check") {
            await beforeCancellationCheck.isPaused
        }

        acquirer.cancel()
        await beforeCancellationCheck.release()

        let acquisitionWasCancelled = await acquirer.value
        let isLockedAfterCancellation = await gate.isLocked
        XCTAssertTrue(acquisitionWasCancelled, "cancellation after FIFO handoff must abort stream creation")
        XCTAssertFalse(isLockedAfterCancellation, "the cancelled acquirer must release its transferred permit")

        try await gate.lock()
        let isLockedAfterReuse = await gate.isLocked
        XCTAssertTrue(isLockedAfterReuse, "the gate must remain reusable after transfer cancellation")
        await gate.unlock()
    }

    func testNewerStreamRequestSupersedesWaiterAndReleasesHandoffPermit() async throws {
        let gate = AntigravityRunGate()
        let requests = AntigravityStreamRequestCoordinator()
        try await gate.lock()
        let pendingRequest = await requests.begin()

        let waiter = Task { () -> Bool in
            do {
                try await AntigravityAgentProvider.acquireRunGate(
                    gate,
                    requestIsCurrent: {
                        await requests.isCurrent(pendingRequest)
                    }
                )
                await gate.unlock()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        do {
            try await AsyncTestWait.waitUntil("pending Antigravity stream creation queued") {
                await gate.waiterCount == 1
            }
        } catch {
            waiter.cancel()
            await gate.unlock()
            _ = await waiter.value
            throw error
        }

        let replacementRequest = await requests.begin()
        let pendingIsCurrent = await requests.isCurrent(pendingRequest)
        let replacementIsCurrent = await requests.isCurrent(replacementRequest)
        XCTAssertFalse(pendingIsCurrent)
        XCTAssertTrue(replacementIsCurrent)
        await gate.unlock()

        let pendingWasSuperseded = await waiter.value
        let gateIsLockedAfterSupersession = await gate.isLocked
        XCTAssertTrue(pendingWasSuperseded)
        XCTAssertFalse(gateIsLockedAfterSupersession, "the stale waiter must release the handed-off permit")

        try await gate.lock()
        let gateIsLockedAfterReuse = await gate.isLocked
        XCTAssertTrue(gateIsLockedAfterReuse, "the replacement must be able to acquire immediately")
        await gate.unlock()
    }

    func testReplacementCannotAcquireUntilPriorRunCleanupFinishes() async throws {
        let gate = AntigravityRunGate()
        try await gate.lock()
        let cleanupBarrier = AsyncBarrier()
        let log = EventLog()

        let releaseTask = Task {
            await AntigravityAgentProvider.releaseRunGateAfterCleanup(gate) {
                await log.append("cleanup-started")
                await cleanupBarrier.pause()
                await log.append("cleanup-finished")
            }
        }
        try await AsyncTestWait.waitUntil("Antigravity cleanup paused while holding gate") {
            await cleanupBarrier.isPaused
        }

        let replacement = Task {
            try await gate.lock()
            await log.append("replacement-acquired")
            await gate.unlock()
        }
        try await AsyncTestWait.waitUntil("replacement Antigravity run queued during cleanup") {
            await gate.waiterCount == 1
        }
        let eventsWhileCleanupPaused = await log.events
        XCTAssertEqual(eventsWhileCleanupPaused, ["cleanup-started"])

        await cleanupBarrier.release()
        await releaseTask.value
        try await replacement.value

        let finalEvents = await log.events
        XCTAssertEqual(
            finalEvents,
            ["cleanup-started", "cleanup-finished", "replacement-acquired"],
            "gate handoff must occur only after all predecessor cleanup"
        )
    }

    func testReplacementDuringProducerActivationPreventsLateLaunchAndReleasesPermit() async throws {
        let gate = AntigravityRunGate()
        let requests = AntigravityStreamRequestCoordinator()
        let activationBarrier = AsyncBarrier()
        let log = EventLog()
        try await gate.lock()
        let pendingRequest = await requests.begin()

        let activation = Task { () -> Bool in
            do {
                _ = try await AntigravityAgentProvider.activateProducer(
                    requests: requests,
                    request: pendingRequest,
                    runGate: gate,
                    beforeActivation: { await activationBarrier.pause() }
                ) {
                    await log.append("stale-producer-launched")
                    await gate.unlock()
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        do {
            try await AsyncTestWait.waitUntil("Antigravity producer activation paused") {
                await activationBarrier.isPaused
            }
        } catch {
            activation.cancel()
            await activationBarrier.release()
            _ = await activation.value
            if await gate.isLocked { await gate.unlock() }
            throw error
        }

        let replacementRequest = await requests.begin()
        await activationBarrier.release()

        let activationWasCancelled = await activation.value
        let events = await log.events
        let pendingIsCurrent = await requests.isCurrent(pendingRequest)
        let replacementIsCurrent = await requests.isCurrent(replacementRequest)
        let gateIsLocked = await gate.isLocked
        XCTAssertTrue(activationWasCancelled)
        XCTAssertEqual(events, [])
        XCTAssertFalse(pendingIsCurrent)
        XCTAssertTrue(replacementIsCurrent)
        XCTAssertFalse(gateIsLocked, "stale activation must release the permit it never transferred")

        try await gate.lock()
        await gate.unlock()
    }

    func testInvalidationDuringProducerActivationPreventsLateLaunchAndReleasesPermit() async throws {
        let gate = AntigravityRunGate()
        let requests = AntigravityStreamRequestCoordinator()
        let activationBarrier = AsyncBarrier()
        let log = EventLog()
        try await gate.lock()
        let pendingRequest = await requests.begin()

        let activation = Task { () -> Bool in
            do {
                _ = try await AntigravityAgentProvider.activateProducer(
                    requests: requests,
                    request: pendingRequest,
                    runGate: gate,
                    beforeActivation: { await activationBarrier.pause() }
                ) {
                    await log.append("disposed-producer-launched")
                    await gate.unlock()
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        do {
            try await AsyncTestWait.waitUntil("Antigravity producer activation paused before invalidation") {
                await activationBarrier.isPaused
            }
        } catch {
            activation.cancel()
            await activationBarrier.release()
            _ = await activation.value
            if await gate.isLocked { await gate.unlock() }
            throw error
        }

        let producerAtInvalidation = await requests.invalidate()
        XCTAssertNil(producerAtInvalidation, "a pending activation must not pretend to own a producer")
        await activationBarrier.release()

        let activationWasCancelled = await activation.value
        let events = await log.events
        let gateIsLocked = await gate.isLocked
        XCTAssertTrue(activationWasCancelled)
        XCTAssertEqual(events, [])
        XCTAssertFalse(gateIsLocked, "disposal invalidation must make the pending owner release its permit")

        try await gate.lock()
        await gate.unlock()
    }

    func testCallerCancellationDuringProducerActivationPreventsLateLaunchAndReleasesPermit() async throws {
        let gate = AntigravityRunGate()
        let requests = AntigravityStreamRequestCoordinator()
        let activationBarrier = AsyncBarrier()
        let log = EventLog()
        try await gate.lock()
        let pendingRequest = await requests.begin()

        let activation = Task { () -> Bool in
            do {
                _ = try await AntigravityAgentProvider.activateProducer(
                    requests: requests,
                    request: pendingRequest,
                    runGate: gate,
                    beforeActivation: { await activationBarrier.pause() }
                ) {
                    await log.append("cancelled-producer-launched")
                    await gate.unlock()
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        do {
            try await AsyncTestWait.waitUntil("Antigravity producer activation paused before caller cancellation") {
                await activationBarrier.isPaused
            }
        } catch {
            activation.cancel()
            await activationBarrier.release()
            _ = await activation.value
            if await gate.isLocked { await gate.unlock() }
            throw error
        }

        activation.cancel()
        await activationBarrier.release()

        let activationWasCancelled = await activation.value
        let events = await log.events
        let gateIsLocked = await gate.isLocked
        XCTAssertTrue(activationWasCancelled)
        XCTAssertEqual(events, [])
        XCTAssertFalse(gateIsLocked, "cancelled activation must release the permit it never transferred")

        try await gate.lock()
        await gate.unlock()
    }

    func testInvalidationCancelsAndJoinsRegisteredProducerCleanup() async throws {
        let gate = AntigravityRunGate()
        let requests = AntigravityStreamRequestCoordinator()
        let log = EventLog()
        try await gate.lock()
        let request = await requests.begin()

        let producer = try await AntigravityAgentProvider.activateProducer(
            requests: requests,
            request: request,
            runGate: gate
        ) {
            await log.append("producer-started")
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {}
            await log.append("producer-cleaned")
            await gate.unlock()
        }
        do {
            try await AsyncTestWait.waitUntil("registered Antigravity producer started") {
                await log.events == ["producer-started"]
            }
        } catch {
            let producerAtFailure = await requests.invalidate()
            await producerAtFailure?.value
            await producer.value
            if await gate.isLocked { await gate.unlock() }
            throw error
        }

        let producerAtInvalidation = await requests.invalidate()
        XCTAssertNotNil(producerAtInvalidation)
        await producerAtInvalidation?.value

        let events = await log.events
        let gateIsLocked = await gate.isLocked
        XCTAssertEqual(events, ["producer-started", "producer-cleaned"])
        XCTAssertFalse(gateIsLocked, "joined producer cleanup must release its transferred permit")
        await producer.value

        try await gate.lock()
        await gate.unlock()
    }

    func testCallerCancellationAfterProducerActivationCancelsAndJoinsProducer() async throws {
        let gate = AntigravityRunGate()
        let requests = AntigravityStreamRequestCoordinator()
        let afterActivation = AsyncBarrier()
        let log = EventLog()
        try await gate.lock()
        let request = await requests.begin()

        let activation = Task { () -> Bool in
            do {
                _ = try await AntigravityAgentProvider.activateProducer(
                    requests: requests,
                    request: request,
                    runGate: gate,
                    afterActivation: { await afterActivation.pause() }
                ) {
                    await log.append("producer-started")
                    do {
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                    } catch {}
                    await log.append("producer-cleaned")
                    await gate.unlock()
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        do {
            try await AsyncTestWait.waitUntil("Antigravity producer registered before caller cancellation") {
                let isPaused = await afterActivation.isPaused
                let events = await log.events
                return isPaused && events == ["producer-started"]
            }
        } catch {
            activation.cancel()
            await afterActivation.release()
            let disposalTasks = await requests.beginDisposal()
            await Self.join(disposalTasks)
            _ = await activation.value
            if await gate.isLocked { await gate.unlock() }
            throw error
        }

        activation.cancel()
        let disposalTasks = await requests.beginDisposal()
        await afterActivation.release()
        let activationWasCancelled = await activation.value
        await Self.join(disposalTasks)

        let events = await log.events
        let gateIsLocked = await gate.isLocked
        XCTAssertTrue(activationWasCancelled)
        XCTAssertEqual(events, ["producer-started", "producer-cleaned"])
        XCTAssertFalse(gateIsLocked)
    }

    func testDisposalCancelsAndJoinsRequestQueuedAtRunGate() async throws {
        let gate = AntigravityRunGate()
        let requests = AntigravityStreamRequestCoordinator()
        try await gate.lock() // unrelated holder keeps the request queued

        let request = await requests.startRequest { token in
            try await AntigravityAgentProvider.acquireRunGate(
                gate,
                requestIsCurrent: { await requests.isCurrent(token) }
            )
            await gate.unlock()
            return Self.finishedStream()
        }
        XCTAssertNotNil(request)

        do {
            try await AsyncTestWait.waitUntil("Antigravity request queued before disposal") {
                await gate.waiterCount == 1
            }
        } catch {
            let disposalTasks = await requests.beginDisposal()
            await Self.join(disposalTasks)
            await gate.unlock()
            throw error
        }

        let disposalTasks = await requests.beginDisposal()
        await Self.join(disposalTasks)

        let waiterCount = await gate.waiterCount
        let holderStillOwnsGate = await gate.isLocked
        XCTAssertEqual(waiterCount, 0, "disposal must cancel the exact queued gate waiter")
        XCTAssertTrue(holderStillOwnsGate, "cancelling the queued request must not release another holder")
        await gate.unlock()
    }

    func testDisposalCancelsAndJoinsRequestDuringGateHandoff() async throws {
        let gate = AntigravityRunGate()
        let requests = AntigravityStreamRequestCoordinator()
        let handoffBarrier = AsyncBarrier()
        try await gate.lock()

        let request = await requests.startRequest { token in
            try await AntigravityAgentProvider.acquireRunGate(
                gate,
                beforeCancellationCheck: { await handoffBarrier.pause() },
                requestIsCurrent: { await requests.isCurrent(token) }
            )
            await gate.unlock()
            return Self.finishedStream()
        }
        XCTAssertNotNil(request)

        do {
            try await AsyncTestWait.waitUntil("Antigravity disposal handoff request queued") {
                await gate.waiterCount == 1
            }
            await gate.unlock()
            try await AsyncTestWait.waitUntil("Antigravity disposal request owns handoff permit") {
                await handoffBarrier.isPaused
            }
        } catch {
            await handoffBarrier.release()
            let disposalTasks = await requests.beginDisposal()
            await Self.join(disposalTasks)
            if await gate.isLocked { await gate.unlock() }
            throw error
        }

        let disposalTasks = await requests.beginDisposal()
        await handoffBarrier.release()
        await Self.join(disposalTasks)

        let gateIsLocked = await gate.isLocked
        XCTAssertFalse(gateIsLocked, "cancelled handoff owner must release its transferred permit")
        try await gate.lock()
        await gate.unlock()
    }

    func testTerminationCancelsOnlyItsExactProducerAndOnlyWhenConsumerCancels() async {
        let firstProducer = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let replacementProducer = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }

        AntigravityAgentProvider.handleTermination(.cancelled, producerTask: firstProducer)

        XCTAssertTrue(firstProducer.isCancelled)
        XCTAssertFalse(replacementProducer.isCancelled, "an old continuation must not cancel its replacement")

        AntigravityAgentProvider.handleTermination(.finished(nil), producerTask: replacementProducer)
        XCTAssertFalse(replacementProducer.isCancelled, "producer completion must not self-cancel and start cancellation cleanup")

        replacementProducer.cancel()
        await firstProducer.value
        await replacementProducer.value
    }

    private static func finishedStream() -> AsyncThrowingStream<AIStreamResult, Error> {
        let (stream, continuation) = AsyncThrowingStream<AIStreamResult, Error>.makeStream()
        continuation.finish()
        return stream
    }

    private static func join(_ disposalTasks: AntigravityStreamRequestCoordinator.DisposalTasks) async {
        for requestTask in disposalTasks.requests {
            _ = await requestTask.result
        }
        for producerTask in disposalTasks.producers {
            await producerTask.value
        }
    }
}
