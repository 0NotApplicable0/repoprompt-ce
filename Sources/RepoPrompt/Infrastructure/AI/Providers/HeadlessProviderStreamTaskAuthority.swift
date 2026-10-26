import Foundation

/// Exact-task lifecycle authority shared by the legacy headless CLI providers. Replacement waits
/// for every predecessor's joined cleanup before launching, while disposal permanently closes the
/// authority, cancels every retained task, and returns those exact tasks for a quiescence barrier.
actor HeadlessProviderStreamTaskAuthority {
    struct Handle {
        let task: Task<Void, Never>
    }

    private var generation: UInt64 = 0
    private var tasks: [UInt64: Task<Void, Never>] = [:]
    private var isDisposed = false

    func start(
        onDiscarded: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async -> Void
    ) -> Handle? {
        guard !isDisposed, !Task.isCancelled else { return nil }

        generation &+= 1
        let token = generation
        let predecessors = Array(tasks.values)
        for predecessor in predecessors {
            predecessor.cancel()
        }

        let task = Task { [weak self] in
            for predecessor in predecessors {
                await predecessor.value
            }
            guard !Task.isCancelled, await self?.isCurrent(token) == true else {
                onDiscarded()
                await self?.taskDidFinish(token)
                return
            }
            await operation()
            await self?.taskDidFinish(token)
        }
        tasks[token] = task
        return Handle(task: task)
    }

    func beginDisposal() -> [Task<Void, Never>] {
        guard !isDisposed else { return Array(tasks.values) }
        isDisposed = true
        generation &+= 1
        let retainedTasks = Array(tasks.values)
        for task in retainedTasks {
            task.cancel()
        }
        return retainedTasks
    }

    nonisolated static func installTerminationHandler(
        on continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation,
        producerTask: Task<Void, Never>
    ) {
        continuation.onTermination = { termination in
            handleTermination(termination, producerTask: producerTask)
        }
    }

    nonisolated static func handleTermination(
        _ termination: AsyncThrowingStream<AIStreamResult, Error>.Continuation.Termination,
        producerTask: Task<Void, Never>
    ) {
        guard case .cancelled = termination else { return }
        producerTask.cancel()
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        !isDisposed && token == generation
    }

    private func taskDidFinish(_ token: UInt64) {
        tasks[token] = nil
    }
}
