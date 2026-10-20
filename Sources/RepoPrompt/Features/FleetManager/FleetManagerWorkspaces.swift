import AppKit
import Combine
import RepoPromptDomainRuntime
import SwiftUI

@MainActor
final class FleetManagerWorkspaceActions {
    private let windows: @MainActor () -> [WindowState]
    private let openWindow: @MainActor () async throws -> WindowState
    private let revealWindow: @MainActor (WindowState) -> Void
    private let pickFolder: @MainActor (String, String) async -> URL?

    init(
        windows: @escaping @MainActor () -> [WindowState] = { WindowStatesManager.shared.allWindows },
        openWindow: @escaping @MainActor () async throws -> WindowState = {
            try await WindowStatesManager.shared.openNewMainWindow().window
        },
        revealWindow: @escaping @MainActor (WindowState) -> Void = { state in
            if MCPBackgroundModeCoordinator.shared.backgroundedWindowID == state.windowID {
                MCPBackgroundModeCoordinator.shared.restore()
            }
            state.revealWindow()
        },
        pickFolder: @escaping @MainActor (String, String) async -> URL? = { title, message in
            await OpenPanelService.shared.pickFolder(title: title, message: message)
        }
    ) {
        self.windows = windows
        self.openWindow = openWindow
        self.revealWindow = revealWindow
        self.pickFolder = pickFolder
    }

    func openRecentWorkspace(_ workspace: WorkspaceModel) async throws {
        if let existing = windows().first(where: { !$0.isClosing && $0.workspaceManager.activeWorkspaceID == workspace.id }) {
            revealWindow(existing)
            return
        }
        let destination = try await openWindow()
        await destination.workspaceManager.awaitInitialized()
        let result = await destination.workspaceManager.openWorkspaceFromLibrary(workspace)
        guard result.didSwitch else {
            throw NSError(domain: "FleetManagerWorkspaceOpen", code: 1, userInfo: [
                NSLocalizedDescriptionKey: result.message ?? "The workspace could not be opened."
            ])
        }
    }

    func addWorkspace() async throws {
        guard let folder = await pickFolder(
            "Open Folder",
            "Choose a folder to open. If it matches an existing workspace root, that workspace will reopen."
        ) else { return }
        let destination = try await openWindow()
        await destination.workspaceManager.awaitInitialized()
        try await destination.workspaceManager.openWorkspace(fromFolderURL: folder, behavior: .createNewWorkspace)
    }
}

@MainActor
final class FleetManagerWorkspaceCatalog: WorkspaceChooserSource {
    @Published private(set) var workspaceChooserPresentation: WorkspaceChooserPresentation = .loading
    private let store: DomainWorkspaceStore
    private var subscriptionTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var runID: UUID?
    private var lastSequence: UInt64 = 0
    private var projectionGeneration: UInt64 = 0
    private var cachedModels: [UUID: (digest: String, model: WorkspaceModel)] = [:]

    init(store: DomainWorkspaceStore = AppDomainRuntimeComposition.shared.runtime.workspaceStore) {
        self.store = store
    }

    deinit {
        subscriptionTask?.cancel()
        retryTask?.cancel()
    }

    func start() {
        guard subscriptionTask == nil else { return }
        let runID = UUID()
        self.runID = runID
        subscriptionTask = Task { [weak self, store] in
            let subscription = await store.subscribe()
            guard !Task.isCancelled, self?.runID == runID else { return }
            self?.apply(subscription.snapshot)
            for await event in subscription.events {
                guard !Task.isCancelled, self?.runID == runID else { return }
                guard event.sequence > (self?.lastSequence ?? 0) else { continue }
                let snapshot = await store.snapshot()
                guard !Task.isCancelled, self?.runID == runID else { return }
                self?.apply(snapshot)
            }
        }
    }

    func stop() {
        runID = nil
        subscriptionTask?.cancel()
        subscriptionTask = nil
        retryTask?.cancel()
        retryTask = nil
    }

    func retryWorkspaceChooser() {
        guard retryTask == nil, let runID else { return }
        retryTask = Task { [weak self, store] in
            await store.reloadExternalChanges()
            let snapshot = await store.snapshot()
            guard !Task.isCancelled, self?.runID == runID else { return }
            self?.apply(snapshot)
            self?.retryTask = nil
        }
        if var failure = workspaceChooserPresentation.failure {
            failure.recovery = .retrying(UUID())
            if case let .ready(catalog, _) = workspaceChooserPresentation {
                workspaceChooserPresentation = .ready(catalog, refresh: .failed(failure))
            } else {
                workspaceChooserPresentation = .failed(failure)
            }
        }
    }

    private func apply(_ snapshot: DomainWorkspaceCatalogSnapshot) {
        guard snapshot.publicationSequence >= lastSequence else { return }
        lastSequence = snapshot.publicationSequence
        guard snapshot.isBootstrapped else {
            reportFailure(.notBootstrapped, snapshot: snapshot)
            return
        }
        let records = snapshot.workspaces
        guard Set(records.map(\.document.workspaceID)).count == records.count else {
            reportFailure(.modelProjection("duplicate_record_id"), snapshot: snapshot)
            return
        }
        do {
            var nextCache: [UUID: (digest: String, model: WorkspaceModel)] = [:]
            let models = try records.map { record in
                let id = record.document.workspaceID
                let digest = record.document.contentDigest
                let model = try cachedModels[id].flatMap { $0.digest == digest ? $0.model : nil }
                    ?? WorkspaceManagerViewModel.decodeDomainWorkspaceCatalogRecordBytes(record)
                nextCache[id] = (digest, model)
                return model
            }
            cachedModels = nextCache
            projectionGeneration &+= 1
            let failure = snapshot.unavailableWorkspaceIDs.isEmpty ? nil : makeFailure(
                .unavailableMembers(snapshot.unavailableWorkspaceIDs), snapshot: snapshot
            )
            let catalog = WorkspaceChooserCatalog(workspaces: models, source: .authority(.init(
                publicationSequence: snapshot.publicationSequence,
                catalogRevision: snapshot.catalogRevision,
                reconciliationGeneration: projectionGeneration,
                isComplete: failure == nil
            )))
            workspaceChooserPresentation = .ready(catalog, refresh: failure.map(WorkspaceChooserRefresh.failed) ?? .current)
        } catch {
            reportFailure(.modelProjection("workspace_decode_failed"), snapshot: snapshot)
        }
    }

    private func makeFailure(_ kind: WorkspaceChooserFailure.Kind, snapshot: DomainWorkspaceCatalogSnapshot) -> WorkspaceChooserFailure {
        let previousID = workspaceChooserPresentation.failure.flatMap { $0.kind == kind ? $0.id : nil }
        return WorkspaceChooserFailure(
            id: previousID ?? UUID(),
            kind: kind,
            publicationSequence: snapshot.publicationSequence,
            catalogRevision: snapshot.catalogRevision
        )
    }

    private func reportFailure(_ kind: WorkspaceChooserFailure.Kind, snapshot: DomainWorkspaceCatalogSnapshot) {
        let failure = makeFailure(kind, snapshot: snapshot)
        if case let .ready(catalog, _) = workspaceChooserPresentation {
            workspaceChooserPresentation = .ready(catalog, refresh: .failed(failure))
        } else {
            workspaceChooserPresentation = .failed(failure)
        }
    }
}

struct FleetManagerWorkspacesView<Source: WorkspaceChooserSource>: View {
    @ObservedObject var workspaceManager: Source
    let actions: FleetManagerWorkspaceActions
    @State private var isOpening = false
    @State private var openError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkspaceChooserResultsView(
                workspaceManager: workspaceManager,
                query: .compact(maxRecent: 5),
                onOpenWorkspace: { workspace in
                    Task { await performOpen { try await actions.openRecentWorkspace(workspace) } }
                }
            )
            Button {
                Task { await performOpen { try await actions.addWorkspace() } }
            } label: {
                Label("Add Workspace", systemImage: "plus")
            }
            .buttonStyle(CustomButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(isOpening)
        .alert("Unable to Open Workspace", isPresented: Binding(
            get: { openError != nil },
            set: { if !$0 { openError = nil } }
        )) {
            Button("OK") { openError = nil }
        } message: {
            Text(openError ?? "")
        }
    }

    private func performOpen(_ action: () async throws -> Void) async {
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        do {
            try await action()
        } catch {
            openError = error.localizedDescription
        }
    }
}
