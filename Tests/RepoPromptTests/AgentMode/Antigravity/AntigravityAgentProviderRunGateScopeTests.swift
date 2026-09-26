import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

/// Contract: every `AntigravityAgentProvider` (production builds one per run) owns its own run
/// gate, so one Antigravity run never parks another run's launch.
final class AntigravityAgentProviderRunGateScopeTests: XCTestCase {
    func testProvidersHaveIndependentRunGates() async throws {
        let gateA = try makeAntigravityProvider().runGateForTesting
        let gateB = try makeAntigravityProvider().runGateForTesting

        XCTAssertFalse(gateA === gateB)
        try await assertCompletes(within: 1) { try await gateA.lock() }
        try await assertCompletes(within: 1) { try await gateB.lock() }

        await gateB.unlock()
        await gateA.unlock()
    }

    func testNoSharedRunGateSymbol() throws {
        let antigravitySources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Antigravity
            .deletingLastPathComponent() // AgentMode
            .deletingLastPathComponent() // RepoPromptTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("Sources/RepoPrompt/Infrastructure/AI/Providers/Antigravity")
        let gateSource = try String(
            contentsOf: antigravitySources.appendingPathComponent("AntigravityRunGate.swift"),
            encoding: .utf8
        )
        let providerSource = try String(
            contentsOf: antigravitySources.appendingPathComponent("AntigravityAgentProvider.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(gateSource.contains("static let shared"))
        XCTAssertFalse(providerSource.contains("AntigravityRunGate.shared"))
    }

    func testRunBAcquiresItsGateWhileRunAHoldsItsOwn() async throws {
        let gateA = try makeAntigravityProvider().runGateForTesting
        let gateB = try makeAntigravityProvider().runGateForTesting

        // Run A holds its permit, as it does while its cleanup is stalled inside
        // releaseRunGateAfterCleanup.
        try await gateA.lock()

        try await assertCompletes(within: 1) {
            try await AntigravityAgentProvider.acquireRunGate(gateB)
        }
        let aLocked = await gateA.isLocked
        let aWaiters = await gateA.waiterCount
        let bLocked = await gateB.isLocked
        XCTAssertTrue(aLocked)
        XCTAssertEqual(aWaiters, 0)
        XCTAssertTrue(bLocked)

        await gateB.unlock()
        await gateA.unlock()
    }

    private func makeAntigravityProvider() throws -> AntigravityAgentProvider {
        let provider = AgentRuntimeProviderService.shared.makeProvider(
            for: .antigravity,
            modelString: "gemini-placeholder",
            antigravityPermissionLevel: .safeManagedUnavailable
        )
        return try XCTUnwrap(provider as? AntigravityAgentProvider)
    }

    /// Fails instead of hanging when `operation` parks longer than `seconds`.
    private func assertCompletes(
        within seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let finished = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await operation()
                return true
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(finished, "operation parked for more than \(seconds) s", file: file, line: line)
    }
}
