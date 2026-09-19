import Foundation

struct AgentTaskRoutingEnvelopeBuilder {
    enum Rejection: Error, Equatable {
        case empty
        case tooManyCharacters
        case tooManyBytes
        case unsupportedContent
        case invalidCandidateCount
    }

    static let maximumCharacters = 4000
    static let maximumUTF8Bytes = 16 * 1024

    func build(
        requestID: UUID,
        text: String,
        candidates: [AgentTaskRoutingCandidateDescriptor],
        containsAttachments: Bool = false,
        containsTaggedPaths: Bool = false,
        invokesWorkflowOrSlashCommand: Bool = false
    ) throws -> AgentTaskRoutingRequest {
        let task = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { throw Rejection.empty }
        guard task.count <= Self.maximumCharacters else { throw Rejection.tooManyCharacters }
        guard task.utf8.count <= Self.maximumUTF8Bytes else { throw Rejection.tooManyBytes }
        guard !containsAttachments, !containsTaggedPaths, !invokesWorkflowOrSlashCommand else {
            throw Rejection.unsupportedContent
        }
        guard (2 ... 4).contains(candidates.count) else { throw Rejection.invalidCandidateCount }
        return AgentTaskRoutingRequest(
            requestID: requestID,
            contractVersion: AgentTaskRoutingRequest.currentContractVersion,
            task: task,
            candidates: candidates
        )
    }
}
