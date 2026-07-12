@testable import RepoPromptApp
import XCTest

/// Contract: `AntigravityRunGate` enforces the single-run-at-a-time invariant that agy conversation-DB
/// attribution depends on. A second `lock()` must park while the gate is held and proceed only after
/// the holder `unlock()`s (FIFO), and the gate must be reusable afterward.
final class AntigravityRunGateTests: XCTestCase {
    private actor EventLog {
        private(set) var events: [String] = []
        func append(_ event: String) {
            events.append(event)
        }
    }

    func testSecondAcquirerParksUntilUnlock() async {
        let gate = AntigravityRunGate()
        await gate.lock() // first holder owns the gate

        let log = EventLog()
        let second = Task {
            await gate.lock()
            await log.append("acquired")
            await gate.unlock()
        }

        // Deterministically wait until `second` is parked on the gate (no sleep): observe the
        // actual waiter count rather than guessing a delay.
        while await gate.waiterCount == 0 {
            await Task.yield()
        }

        // Holder still owns the gate, so the waiter must not have acquired yet.
        let beforeRelease = await log.events
        XCTAssertEqual(beforeRelease, [], "second acquirer must park while the gate is held")

        await log.append("released")
        await gate.unlock() // wake the parked waiter
        await second.value

        let finalEvents = await log.events
        XCTAssertEqual(
            finalEvents,
            ["released", "acquired"],
            "the waiter must proceed only after the holder releases"
        )

        // Gate is reusable after the waiter cycle completes (no permanent lock).
        await gate.lock()
        let parkedAfterReuse = await gate.waiterCount
        await gate.unlock()
        XCTAssertEqual(parkedAfterReuse, 0, "an uncontended re-lock must acquire immediately")
    }
}
