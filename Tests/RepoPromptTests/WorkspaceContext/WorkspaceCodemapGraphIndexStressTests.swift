import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    @MainActor
    final class WorkspaceCodemapGraphIndexStressTests: XCTestCase {
        func testLateCancelDoesNotResumeRestartedWaiter() async throws {
            let deadline = Date().addingTimeInterval(30)
            let policies = PolicySites()
            defer { policies.restore() }
            for enabled in [true, false] {
                policies.set(enabled: enabled)
                let scenario = try await makeScenario(rootCount: 1)
                addTeardownBlock { await scenario.cleanup() }
                let root = scenario.roots[0]
                let gate = await scenario.engine.debugInstallGraphIndexCancellationGate(rootEpoch: root) {
                    scenario.recorder.record(.gateHeld)
                }
                scenario.gate = gate
                let firstEnqueue = scenario.recorder.expect("W0 enqueued") { $0.enqueuedWaiters.count == 1 }
                let launch = await scenario.engine.scheduleGraphIndex(rootEpoch: root)
                XCTAssertEqual(launch, .handedOff)
                await wait(for: firstEnqueue, until: deadline)
                let w0 = try XCTUnwrap(scenario.recorder.events.enqueuedWaiters.first)
                let held = scenario.recorder.expect("W0 callback held before actor entry") { $0.contains(.gateHeld) }
                let restarted = scenario.recorder.expect("real finish and W1 enqueue") { events in
                    events.workerFinishCount(for: w0.jobID) >= 1 &&
                        events.workerStartCount(for: w0.jobID) >= 2 &&
                        events.enqueuedWaiters.count >= 2
                }
                let requested = await scenario.engine.debugRequestQueuedGraphIndexWorkerRestart(rootEpoch: root)
                XCTAssertTrue(requested)
                await wait(for: held, until: deadline)
                await wait(for: restarted, until: deadline)
                let w1 = try XCTUnwrap(scenario.recorder.events.enqueuedWaiters.dropFirst().first)
                XCTAssertEqual(w0.jobID, w1.jobID, "real restart must reuse job ID")
                XCTAssertNotEqual(w0.waiterID, w1.waiterID)
                XCTAssertEqual(scenario.recorder.events.resumeCount(for: w0.waiterID), 1)
                XCTAssertEqual(scenario.recorder.events.resumeCount(for: w1.waiterID), 0)
                let callbackApplied = scenario.recorder.expect("W0 callback applied") {
                    $0.contains(.engine(.cancellationCallbackApplied(waiterID: w0.waiterID, jobID: w0.jobID)))
                }
                await gate.release()
                await wait(for: callbackApplied, until: deadline)
                let w1ResumeCount = scenario.recorder.events.resumeCount(for: w1.waiterID)
                XCTAssertEqual(w1ResumeCount, 0, "policy=\(enabled): W0 late cancellation resumed W1")
                let w1Queued = await scenario.engine.debugGraphIndexAdmissionWaiterIsQueued(w1.waiterID)
                XCTAssertTrue(w1Queued, "policy=\(enabled): W1 was detached by W0 callback")
                await scenario.releaseHolds()
                let w1Resumed = scenario.recorder.expect("W1 terminal resume") {
                    $0.resumeCount(for: w1.waiterID) == 1
                }
                await wait(for: w1Resumed, until: deadline)
                XCTAssertEqual(scenario.recorder.events.resumeCount(for: w0.waiterID), 1)
                XCTAssertEqual(scenario.recorder.events.resumeCount(for: w1.waiterID), 1)
                await scenario.cleanup()
            }
        }

        func testShutdownResumesQueuedWaiters() async throws {
            let deadline = Date().addingTimeInterval(30)
            let policies = PolicySites()
            defer { policies.restore() }
            for enabled in [true, false] {
                policies.set(enabled: enabled)
                let scenario = try await makeScenario(rootCount: 2)
                addTeardownBlock { await scenario.cleanup() }
                let queued = scenario.recorder.expect("two rooted waiters enqueued") {
                    $0.enqueuedWaiters.count == 2
                }
                for root in scenario.roots {
                    let launch = await scenario.engine.scheduleGraphIndex(rootEpoch: root)
                    XCTAssertEqual(launch, .handedOff)
                }
                await wait(for: queued, until: deadline)
                let waiters = scenario.recorder.events.enqueuedWaiters
                XCTAssertEqual(waiters.count, 2)
                XCTAssertNotEqual(waiters[0].jobID, waiters[1].jobID)
                XCTAssertNotEqual(waiters[0].waiterID, waiters[1].waiterID)
                let resumed = scenario.recorder.expect("both shutdown resumes observed") { events in
                    waiters.allSatisfy { events.resumeCount(for: $0.waiterID) == 1 }
                }
                let shutdown = Task { await scenario.engine.shutdown() }
                await wait(for: resumed, until: deadline)
                let events = scenario.recorder.events
                for waiter in waiters {
                    XCTAssertEqual(events.resumeCount(for: waiter.waiterID), 1)
                    XCTAssertEqual(
                        events.resumeDisposition(for: waiter.waiterID),
                        .threwCancellation,
                        "policy=\(enabled): shutdown did not throw CancellationError for waiter \(waiter.waiterID)"
                    )
                }
                await shutdown.value
                await scenario.cleanup()
            }
        }

        private func makeScenario(rootCount: Int) async throws -> Scenario {
            let repository = try ReviewGitRepositoryFixture(name: #function)
            let fixture = try CodemapStoreFixture(name: #function)
            let engine = try fixture.runtime().bindingEngine()
            let scenario = Scenario(repository: repository, fixture: fixture, engine: engine)
            await engine.debugSetGraphIndexAdmissionObserver { [recorder = scenario.recorder] event in
                recorder.record(.engine(event))
            }
            for index in 0 ..< rootCount {
                let url = try repository.makeRepository(
                    named: "root-\(index)",
                    files: ["Sources/Item.swift": "struct Item\(index) {}\n"]
                )
                let root = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
                let registration = WorkspaceCodemapBindingRootRegistration(
                    rootID: root.rootID,
                    rootLifetimeID: root.rootLifetimeID,
                    loadedRootURL: url,
                    catalogGeneration: 1,
                    ingressGeneration: 1
                )
                switch await engine.registerRoot(registration) {
                case .registered, .exactDuplicate: break
                default:
                    XCTFail("root \(index) registration failed")
                    throw StressSetupError.registrationFailed
                }
                scenario.roots.append(root)
                let acquired = await engine.debugAcquireGraphIndexAdmissionHold(
                    rootEpoch: root,
                    expiresAfterMilliseconds: 60000
                )
                let hold = try XCTUnwrap(acquired)
                scenario.holds.append((hold.holdID, root))
            }
            return scenario
        }

        private func wait(for expectation: XCTestExpectation, until deadline: Date) async {
            await fulfillment(of: [expectation], timeout: max(0, deadline.timeIntervalSinceNow))
        }
    }

    @MainActor
    private final class PolicySites {
        let routing = WindowRoutingService(
            windowStates: WindowStatesManager.shared,
            networkMgr: ServerNetworkManager.shared
        )
        let routingOriginal: OrchestrationGraphWindowPolicy
        let networkOriginal: OrchestrationGraphWindowPolicy
        let openerOriginal: OrchestrationGraphWindowPolicy

        init() {
            routingOriginal = routing.policy
            networkOriginal = ServerNetworkManager.shared.graphPolicy
            openerOriginal = AppWindowOpener.shared.policy
        }

        func set(enabled: Bool) {
            let policy = OrchestrationGraphWindowPolicy(isGraphEnabled: { enabled })
            routing.policy = policy
            ServerNetworkManager.shared.graphPolicy = policy
            AppWindowOpener.shared.policy = policy
        }

        func restore() {
            routing.policy = routingOriginal
            ServerNetworkManager.shared.graphPolicy = networkOriginal
            AppWindowOpener.shared.policy = openerOriginal
        }
    }

    private final class Scenario: @unchecked Sendable {
        let repository: ReviewGitRepositoryFixture
        let fixture: CodemapStoreFixture
        let engine: WorkspaceCodemapBindingEngine
        let recorder = GraphIndexEventRecorder()
        var roots: [WorkspaceCodemapRootEpoch] = []
        var holds: [(UUID, WorkspaceCodemapRootEpoch)] = []
        var gate: WorkspaceCodemapGraphIndexCancellationGate?

        init(repository: ReviewGitRepositoryFixture, fixture: CodemapStoreFixture, engine: WorkspaceCodemapBindingEngine) {
            self.repository = repository
            self.fixture = fixture
            self.engine = engine
        }

        func releaseHolds() async {
            let owned = holds
            holds.removeAll()
            for (holdID, root) in owned {
                _ = await engine.debugReleaseGraphIndexAdmissionHold(holdID, rootEpoch: root)
            }
        }

        func cleanup() async {
            await gate?.release()
            await releaseHolds()
            for root in roots {
                await engine.debugClearGraphIndexCancellationGate(rootEpoch: root)
            }
            await engine.debugSetGraphIndexAdmissionObserver(nil)
            await engine.shutdown()
            repository.cleanup()
        }
    }

    private enum StressSetupError: Error { case registrationFailed }

    private enum Observed: Equatable {
        case gateHeld
        case engine(WorkspaceCodemapGraphIndexAdmissionDebugEvent)
    }

    private final class GraphIndexEventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Observed] = []
        private var pending: [(XCTestExpectation, @Sendable ([Observed]) -> Bool)] = []

        var events: [Observed] {
            lock.withLock { stored }
        }

        func record(_ event: Observed) {
            lock.withLock {
                stored.append(event)
                pending.removeAll { expectation, predicate in
                    guard predicate(stored) else { return false }
                    expectation.fulfill()
                    return true
                }
            }
        }

        func expect(_ description: String, when predicate: @escaping @Sendable ([Observed]) -> Bool) -> XCTestExpectation {
            let expectation = XCTestExpectation(description: description)
            lock.withLock {
                if predicate(stored) { expectation.fulfill() }
                else { pending.append((expectation, predicate)) }
            }
            return expectation
        }
    }

    private extension [Observed] {
        var enqueuedWaiters: [(waiterID: UUID, jobID: UUID)] {
            compactMap {
                guard case let .engine(.enqueued(waiterID, jobID)) = $0 else { return nil }
                return (waiterID, jobID)
            }
        }

        func workerStartCount(for jobID: UUID) -> Int {
            count {
                guard case let .engine(.workerStarted(id, _)) = $0 else { return false }
                return id == jobID
            }
        }

        func workerFinishCount(for jobID: UUID) -> Int {
            count {
                guard case let .engine(.workerFinished(id, _)) = $0 else { return false }
                return id == jobID
            }
        }

        func resumeCount(for waiterID: UUID) -> Int {
            count {
                guard case let .engine(.resumed(id, _, _)) = $0 else { return false }
                return id == waiterID
            }
        }

        func resumeDisposition(for waiterID: UUID) -> WorkspaceCodemapGraphIndexAdmissionDebugDisposition? {
            for event in self {
                guard case let .engine(.resumed(id, _, disposition)) = event, id == waiterID else { continue }
                return disposition
            }
            return nil
        }
    }
#endif
