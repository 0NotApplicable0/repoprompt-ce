import Foundation

/// Immutable identity of the MCP connection that freshly created an agent session.
struct StarterConnectionStamp: Hashable {
    let connectionID: UUID
    let lifecycleGeneration: UInt64
}

/// The starting connection's self-declared client name, kept for display only. Any two values are
/// equal so the name can never take part in a fence, a match, or a wire value.
struct StarterClientLabel: Equatable {
    let name: String?

    static func == (_: Self, _: Self) -> Bool {
        true
    }
}
