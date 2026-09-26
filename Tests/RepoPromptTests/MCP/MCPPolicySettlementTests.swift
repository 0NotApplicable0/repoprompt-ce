import Darwin
import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptShared
import XCTest

/// Contract: Antigravity agent-mode MCP policies are held until their run settles, other
/// agent-mode policies still age out at their TTL, and concurrent same-client policies are matched
/// by each run's expected agent PID.
final class MCPPolicySettlementTests: XCTestCase {
    func testSameClientAntigravityPoliciesMatchByRunPID() async throws {
        #if DEBUG
            let manager = ServerNetworkManager(
                domainHost: AppDomainRuntimeComposition.shared.runtime.domainHost
            )
            let clientName = AgentProviderKind.antigravityMCPClientID
            let windowID = 987_655
            let runA = UUID()
            let runB = UUID()
            let childA = try Self.launchSleeper()
            defer { Self.stop(childA) }
            let childB = try Self.launchSleeper()
            defer { Self.stop(childB) }
            await manager.registerExpectedAgentPID(childA.processIdentifier, for: clientName, runID: runA)
            await manager.registerExpectedAgentPID(childB.processIdentifier, for: clientName, runID: runB)
            for runID in [runA, runB] {
                await manager.installClientConnectionPolicy(
                    for: clientName,
                    windowID: windowID,
                    restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                    oneShot: true,
                    reason: "MCPPolicySettlementTests",
                    ttl: 60,
                    tabID: UUID(),
                    runID: runID,
                    purpose: .agentModeRun,
                    requiresExpectedAgentPID: true,
                    prunesOnlyAfterSettlement: true
                )
            }
            let connectionID = UUID()
            await manager.debugInstallDirectAdmissionConnectionForTesting(
                connectionID: connectionID,
                connection: SettlementTestConnection(),
                pendingClientID: clientName
            )

            let started = Date()
            let applied = await manager.debugApplyPendingPolicy(
                clientName: clientName,
                connectionID: connectionID,
                clientPid: Int(childB.processIdentifier),
                pidGateTimeout: 2.0,
                requireRunRouting: false
            )
            let elapsed = Date().timeIntervalSince(started)

            XCTAssertEqual(applied.outcome, "applied")
            XCTAssertEqual(applied.runID, runB)
            XCTAssertLessThan(elapsed, 1.0, "B's helper must not wait out the 2 s unmatched hold")
            let remaining = await manager.debugPendingPolicySnapshot(for: clientName)
            XCTAssertTrue(remaining.contains { $0.runID == runA })
            XCTAssertFalse(remaining.contains { $0.runID == runB })

            await manager.clearExpectedAgentPID(childA.processIdentifier, for: clientName, runID: runA)
            await manager.clearExpectedAgentPID(childB.processIdentifier, for: clientName, runID: runB)
            await manager.clearClientConnectionPolicy(for: clientName, windowID: windowID, runID: runA)
            await manager.removeConnection(connectionID)
        #endif
    }

    func testSettlementHoldAuthority() {
        let antigravity = AgentProviderKind.antigravityMCPClientID
        XCTAssertTrue(MCPPolicySettlement.prunesOnlyAfterSettlement(clientName: antigravity, purpose: .agentModeRun))
        XCTAssertTrue(MCPPolicySettlement.prunesOnlyAfterSettlement(clientName: antigravity, purpose: .discoverRun))
        XCTAssertFalse(MCPPolicySettlement.prunesOnlyAfterSettlement(clientName: antigravity, purpose: .unknown))
        for other in [
            AgentProviderKind.codexMCPClientID,
            AgentProviderKind.claudeMCPClientID,
            AgentProviderKind.grokMCPClientID
        ] {
            XCTAssertFalse(
                MCPPolicySettlement.prunesOnlyAfterSettlement(clientName: other, purpose: .agentModeRun),
                other
            )
            XCTAssertTrue(
                MCPPolicySettlement.prunesOnlyAfterSettlement(clientName: other, purpose: .discoverRun),
                other
            )
        }
    }

    func testAgentModeDefaultInstallerHoldsAntigravityPolicyPastTTL() async throws {
        #if DEBUG
            let manager = ServerNetworkManager.shared
            let windowID = 987_654
            let antigravityRunID = UUID()
            let codexRunID = UUID()
            let claudeRunID = UUID()
            addTeardownBlock {
                for (clientName, runID) in [
                    (AgentProviderKind.antigravityMCPClientID, antigravityRunID),
                    (AgentProviderKind.codexMCPClientID, codexRunID),
                    (AgentProviderKind.claudeMCPClientID, claudeRunID)
                ] {
                    await manager.clearClientConnectionPolicy(for: clientName, windowID: windowID, runID: runID)
                }
            }
            for (clientName, runID) in [
                (AgentProviderKind.antigravityMCPClientID, antigravityRunID),
                (AgentProviderKind.codexMCPClientID, codexRunID),
                (AgentProviderKind.claudeMCPClientID, claudeRunID)
            ] {
                await AgentModeViewModel.defaultConnectionPolicyInstaller(
                    clientName: clientName,
                    windowID: windowID,
                    restrictedTools: AgentModeMCPToolPolicy.restrictedTools,
                    oneShot: true,
                    reason: "MCPPolicySettlementTests",
                    ttl: 0.05,
                    tabID: UUID(),
                    runID: runID,
                    additionalTools: nil,
                    purpose: .agentModeRun
                )
            }
            try await Task.sleep(nanoseconds: 300_000_000)

            let antigravityRows = await manager.debugPendingPolicySnapshot(for: AgentProviderKind.antigravityMCPClientID)
            let codexRows = await manager.debugPendingPolicySnapshot(for: AgentProviderKind.codexMCPClientID)
            let claudeRows = await manager.debugPendingPolicySnapshot(for: AgentProviderKind.claudeMCPClientID)
            XCTAssertTrue(
                antigravityRows.contains { $0.runID == antigravityRunID },
                "An Antigravity agent-mode policy must survive past its TTL until the run settles"
            )
            XCTAssertFalse(
                codexRows.contains { $0.runID == codexRunID },
                "A Codex agent-mode policy must still age out at its TTL"
            )
            XCTAssertFalse(
                claudeRows.contains { $0.runID == claudeRunID },
                "A Claude agent-mode policy must still age out at its TTL"
            )

            await manager.revokeClientConnectionPolicy(
                for: AgentProviderKind.antigravityMCPClientID,
                windowID: windowID,
                runID: antigravityRunID
            )
            let afterRevoke = await manager.debugPendingPolicySnapshot(for: AgentProviderKind.antigravityMCPClientID)
            XCTAssertFalse(afterRevoke.contains { $0.runID == antigravityRunID })
        #endif
    }

    private static func launchSleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    private static func stop(_ process: Process) {
        process.terminate()
        process.waitUntilExit()
    }
}

#if DEBUG
    private actor SettlementTestConnection: MCPServerConnection {
        nonisolated var isFilesystemBacked: Bool {
            false
        }

        nonisolated var connectionFolderURL: URL? {
            nil
        }

        nonisolated var capabilityToken: String? {
            nil
        }

        func start(approvalHandler _: @escaping (MCP.Client.Info) async -> Bool) async throws {}
        func stop() async {}
        func abortForExecutionWatchdog(context _: MCPExecutionWatchdogTerminalContext) async {}
        func notifyToolListChanged() async {}
        func connectionState() -> ConnectionStateSnapshot {
            .ready
        }

        func isViableForRetention() -> Bool {
            true
        }

        func secondsSinceLastActivity() async -> TimeInterval {
            0
        }

        func transportIngressSnapshot() async -> MCPTransportIngressSnapshot? {
            nil
        }

        func responseDeliverySnapshot() async -> MCPResponseDeliverySnapshot? {
            nil
        }

        func terminate(reason _: TerminationReason, message _: String?) async {}
        func sendProgress(
            tool _: String,
            kind _: RepoPromptProgressKind,
            stage _: String,
            message _: String
        ) async {}
    }
#endif
