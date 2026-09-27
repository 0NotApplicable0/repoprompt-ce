#if DEBUG
import Foundation
import XCTest
@testable import RepoPromptApp

final class WorkspaceRootUnloadCodemapFlightBoundTests: XCTestCase {
    func testStarvedFlightDoesNotStallUnload() async throws {
        let store = WorkspaceFileContextStore()
        defer { Task { await store.setCodemapCleanupFlightUnloadBoundForTesting(nil) } }
        await store.setCodemapCleanupFlightUnloadBoundForTesting(.milliseconds(500))
        let rootURL = try makeTestDirectory(name: "StarvedCodemapFlight")
        let root = try await store.loadRoot(path: rootURL.path)
        let gate = CodemapCleanupFlightGate()
        let didInstallFlight = await store.installCodemapCleanupFlightForTesting(rootID: root.id) {
            await gate.wait()
        }
        XCTAssertTrue(didInstallFlight)

        let completion = CompletionFlag()
        let unload = Task {
            await store.unloadRoot(id: root.id)
            await completion.finish()
        }
        let didFinish = await waitForCompletion(completion, within: .seconds(2.5))
        if !didFinish {
            XCTFail("Unload did not finish before the codemap-flight bound")
            await gate.release()
            await unload.value
            return
        }

        let unloadingPaths = await store.unloadingRootPathsForTesting()
        let hasHeldFlight = await store.hasCodemapCleanupFlightForTesting(rootID: root.id)
        XCTAssertFalse(root.standardizedFullPath.isEmpty)
        XCTAssertFalse(unloadingPaths.contains(root.standardizedFullPath))
        XCTAssertTrue(hasHeldFlight)

        let successor = try await loadRoot(store, path: rootURL.path, within: .seconds(2.5))
        XCTAssertNotEqual(successor.id, root.id)
        await gate.release()
        await unload.value
        await waitForFlightRemoval(store, rootID: root.id, within: .seconds(2))
        let hasFlight = await store.hasCodemapCleanupFlightForTesting(rootID: root.id)
        XCTAssertFalse(hasFlight)
    }

    func testManyStarvedFlightsShareOneDeadline() async throws {
        let store = WorkspaceFileContextStore()
        defer { Task { await store.setCodemapCleanupFlightUnloadBoundForTesting(nil) } }
        await store.setCodemapCleanupFlightUnloadBoundForTesting(.milliseconds(500))
        let gates = (0 ..< 6).map { _ in CodemapCleanupFlightGate() }
        var roots: [WorkspaceRootRecord] = []
        for (index, gate) in gates.enumerated() {
            let rootURL = try makeTestDirectory(name: "ManyStarvedCodemapFlights-\(index)")
            let root = try await store.loadRoot(path: rootURL.path)
            let didInstallFlight = await store.installCodemapCleanupFlightForTesting(rootID: root.id) {
                await gate.wait()
            }
            XCTAssertTrue(didInstallFlight)
            roots.append(root)
        }

        let completion = CompletionFlag()
        let unload = Task {
            await store.unloadRoots(ids: roots.map(\.id))
            await completion.finish()
        }
        let didFinish = await waitForCompletion(completion, within: .seconds(2))
        if !didFinish {
            XCTFail("Unload did not finish within one shared codemap-flight bound")
        }
        for gate in gates {
            await gate.release()
        }
        await unload.value

        let unloadingPaths = await store.unloadingRootPathsForTesting()
        for root in roots {
            XCTAssertFalse(unloadingPaths.contains(root.standardizedFullPath))
        }
    }

    func testNormalFlightStillCompletesBeforeUnloadReturns() async throws {
        let store = WorkspaceFileContextStore()
        defer { Task { await store.setCodemapCleanupFlightUnloadBoundForTesting(nil) } }
        let rootURL = try makeTestDirectory(name: "NormalCodemapFlight")
        let root = try await store.loadRoot(path: rootURL.path)
        let didInstallFlight = await store.installCodemapCleanupFlightForTesting(rootID: root.id) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(didInstallFlight)

        await store.unloadRoot(id: root.id)

        let hasFlight = await store.hasCodemapCleanupFlightForTesting(rootID: root.id)
        XCTAssertFalse(hasFlight)
    }

    func testTimerIsCancelledWhenFlightCompletes() async throws {
        let store = WorkspaceFileContextStore()
        defer { Task { await store.setCodemapCleanupFlightUnloadBoundForTesting(nil) } }
        let rootURL = try makeTestDirectory(name: "ImmediateCodemapFlight")
        let root = try await store.loadRoot(path: rootURL.path)
        let didInstallFlight = await store.installCodemapCleanupFlightForTesting(rootID: root.id) {}
        XCTAssertTrue(didInstallFlight)

        await store.unloadRoot(id: root.id)

        try? await Task.sleep(for: .milliseconds(200))
        let deadline = ContinuousClock.now + .seconds(1)
        while await store.liveCodemapCleanupFlightWaitTimerCountForTesting() != 0,
              ContinuousClock.now < deadline
        {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let timerCount = await store.liveCodemapCleanupFlightWaitTimerCountForTesting()
        XCTAssertEqual(timerCount, 0)
    }

    private func waitForCompletion(_ completion: CompletionFlag, within duration: Duration) async -> Bool {
        let deadline = ContinuousClock.now + duration
        while await !completion.isFinished(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await completion.isFinished()
    }

    private func loadRoot(
        _ store: WorkspaceFileContextStore,
        path: String,
        within duration: Duration
    ) async throws -> WorkspaceRootRecord {
        let completion = CompletionFlag()
        let load = Task { () -> WorkspaceRootRecord? in
            defer { Task { await completion.finish() } }
            return try? await store.loadRoot(path: path)
        }
        let didFinish = await waitForCompletion(completion, within: duration)
        if !didFinish {
            XCTFail("Successor root load did not finish before the codemap-flight bound")
        }
        let root = await load.value
        return try XCTUnwrap(root)
    }

    private func waitForFlightRemoval(
        _ store: WorkspaceFileContextStore,
        rootID: UUID,
        within duration: Duration
    ) async {
        let deadline = ContinuousClock.now + duration
        while await store.hasCodemapCleanupFlightForTesting(rootID: rootID),
              ContinuousClock.now < deadline
        {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor CodemapCleanupFlightGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}

private actor CompletionFlag {
    private var finished = false

    func finish() {
        finished = true
    }

    func isFinished() -> Bool {
        finished
    }
}

#endif
