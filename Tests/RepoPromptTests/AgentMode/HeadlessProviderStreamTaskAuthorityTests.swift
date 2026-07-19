@testable import RepoPromptApp
import XCTest

final class HeadlessProviderStreamTaskAuthorityTests: XCTestCase {
    private actor EventLog {
        private(set) var events: [String] = []

        func append(_ event: String) {
            events.append(event)
        }
    }

    private actor Barrier {
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

    func testReplacementWaitsForExactPredecessorCleanupBeforeLaunching() async throws {
        let authority = HeadlessProviderStreamTaskAuthority()
        let cleanupBarrier = Barrier()
        let log = EventLog()

        let first = await authority.start(onDiscarded: {}) {
            await log.append("first-started")
            await cleanupBarrier.pause()
            await log.append("first-cleaned")
        }
        let firstHandle = try XCTUnwrap(first)
        do {
            try await AsyncTestWait.waitUntil("first headless producer started") {
                await log.events == ["first-started"]
            }
        } catch {
            await cleanupBarrier.release()
            firstHandle.task.cancel()
            await firstHandle.task.value
            throw error
        }

        let second = await authority.start(onDiscarded: {}) {
            await log.append("second-started")
        }
        let secondHandle = try XCTUnwrap(second)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        let eventsBeforeCleanup = await log.events
        XCTAssertEqual(eventsBeforeCleanup, ["first-started"])

        await cleanupBarrier.release()
        await firstHandle.task.value
        await secondHandle.task.value

        let finalEvents = await log.events
        XCTAssertEqual(finalEvents, ["first-started", "first-cleaned", "second-started"])
    }

    func testReplacementWaitsForCancellationObservedCleanupBeforeLaunching() async throws {
        let authority = HeadlessProviderStreamTaskAuthority()
        let cleanupBarrier = Barrier()
        let log = EventLog()

        let first = await authority.start(onDiscarded: {}) {
            await log.append("first-started")
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                await log.append("first-cancel-observed")
            }
            await cleanupBarrier.pause()
            await log.append("first-cleaned")
        }
        let firstHandle = try XCTUnwrap(first)
        do {
            try await AsyncTestWait.waitUntil("first headless producer started before cancellation") {
                await log.events == ["first-started"]
            }
        } catch {
            firstHandle.task.cancel()
            await cleanupBarrier.release()
            await firstHandle.task.value
            throw error
        }

        let second = await authority.start(onDiscarded: {}) {
            await log.append("second-started")
        }
        let secondHandle = try XCTUnwrap(second)
        do {
            try await AsyncTestWait.waitUntil("first headless producer entered structured cancellation cleanup") {
                await cleanupBarrier.isPaused
            }
        } catch {
            await cleanupBarrier.release()
            await firstHandle.task.value
            await secondHandle.task.value
            throw error
        }

        let eventsDuringCleanup = await log.events
        XCTAssertEqual(eventsDuringCleanup, ["first-started", "first-cancel-observed"])

        await cleanupBarrier.release()
        await firstHandle.task.value
        await secondHandle.task.value

        let finalEvents = await log.events
        XCTAssertEqual(
            finalEvents,
            ["first-started", "first-cancel-observed", "first-cleaned", "second-started"]
        )
    }

    func testDisposalCancelsAndJoinsAllRetainedTasksAndRejectsRestart() async throws {
        let authority = HeadlessProviderStreamTaskAuthority()
        let log = EventLog()

        let producer = await authority.start(onDiscarded: {}) {
            await log.append("started")
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {}
            await log.append("cleaned")
        }
        let producerHandle = try XCTUnwrap(producer)
        do {
            try await AsyncTestWait.waitUntil("headless producer started before disposal") {
                await log.events == ["started"]
            }
        } catch {
            producerHandle.task.cancel()
            await producerHandle.task.value
            throw error
        }

        let disposalTasks = await authority.beginDisposal()
        for task in disposalTasks {
            await task.value
        }
        let replacement = await authority.start(onDiscarded: {}) {
            await log.append("unexpected-restart")
        }

        let events = await log.events
        XCTAssertEqual(events, ["started", "cleaned"])
        XCTAssertNil(replacement)
    }

    func testTerminationCancelsOnlyCapturedProducerAndIgnoresNormalFinish() async {
        let firstProducer = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let replacementProducer = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }

        HeadlessProviderStreamTaskAuthority.handleTermination(.cancelled, producerTask: firstProducer)
        XCTAssertTrue(firstProducer.isCancelled)
        XCTAssertFalse(replacementProducer.isCancelled)

        HeadlessProviderStreamTaskAuthority.handleTermination(
            .finished(nil),
            producerTask: replacementProducer
        )
        XCTAssertFalse(replacementProducer.isCancelled)

        replacementProducer.cancel()
        await firstProducer.value
        await replacementProducer.value
    }
}
