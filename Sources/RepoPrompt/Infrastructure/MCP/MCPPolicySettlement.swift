import Foundation

/// Decides whether a run's pending MCP connection policy may age out at its TTL.
///
/// Some runs spend time between `MCPBootstrapLease.acquire()`, which installs the policy, and their
/// agent's connection: Context Builder discover runs, and Antigravity agent-mode runs, whose
/// provider finishes `prepare()` before it spawns `agy`. Their policies are held until the run
/// settles and are removed only by one-shot consumption or by the lease's run-scoped cleanup.
enum MCPPolicySettlement {
    static func prunesOnlyAfterSettlement(clientName: String, purpose: MCPRunPurpose) -> Bool {
        purpose == .discoverRun
            || (purpose == .agentModeRun && clientName == AgentProviderKind.antigravityMCPClientID)
    }
}
