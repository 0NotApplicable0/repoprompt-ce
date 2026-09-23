//
//  WindowContentView.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-03-24.
//

import SwiftUI

/// This view holds exactly one @StateObject WindowState, meaning
/// each new Window/Scene gets its own WindowState.
struct WindowContentView: View {
    @EnvironmentObject var versionManager: VersionManager
    @EnvironmentObject var windowStatesManager: WindowStatesManager
    @EnvironmentObject var sparkleManager: SparkleUpdaterManager
    @Environment(\.openWindow) private var openWindow

    /// The WindowState itself (your big manager of fileManager, promptManager, etc.)
    @StateObject private var windowState: WindowState

    /// Orchestration graph single-window policy; decides the root surface once per window.
    let policy: OrchestrationGraphWindowPolicy

    /// Owns the mounted root surface. A settings toggle hot-swaps the surface on this same
    /// window via `applyOrchestrationGraphEnabled`; the window itself never closes or reopens.
    @StateObject private var rootSurfaceModel: WindowRootSurfaceModel

    /// The settings store observed for the orchestration graph flag.
    private let settings: GlobalSettingsStore

    /// Whether the given window is the single orchestration graph host. Evaluated against the
    /// installed `windowState`, never captured at init time.
    private let isGraphHost: @MainActor (WindowState) -> Bool

    #if DEBUG
        /// DEBUG-only barrier for hosted tests: records lifecycle events as they occur.
        private let lifecycleProbe: (@MainActor (LifecycleEvent) -> Void)?
    #endif

    enum RootSurface: Equatable {
        case contentView
        case orchestrationGraphShell
    }

    #if DEBUG
        /// DEBUG-only lifecycle events emitted for hosted-test barriers. A branch event proves
        /// only that branch's lifecycle; the container events are recorded separately.
        enum LifecycleEvent: Equatable {
            case containerAppeared
            case containerDisappeared
            case surfaceAppeared(RootSurface)
            case surfaceDisappeared(RootSurface)
        }
    #endif

    @MainActor
    init() {
        self.init(policy: .production)
    }

    @MainActor
    init(policy: OrchestrationGraphWindowPolicy) {
        self.init(
            policy: policy,
            windowState: WindowState(domainRuntime: AppDomainRuntimeComposition.shared.runtime)
        )
    }

    // The internal designated initializer. Production callers use `init()` / `init(policy:)`
    // and take every default; tests inject a fixture `windowState`, an isolated `settings`
    // store, a deterministic `isGraphHost`, a retained `rootSurfaceModel`, and (DEBUG only) a
    // `lifecycleProbe` barrier. In release this initializer has no probe parameter.
    #if DEBUG
        @MainActor
        init(
            policy: OrchestrationGraphWindowPolicy,
            windowState: @autoclosure @escaping () -> WindowState,
            settings: GlobalSettingsStore = .shared,
            isGraphHost: @escaping @MainActor (WindowState) -> Bool = {
                WindowStatesManager.shared.allWindows.first === $0
            },
            rootSurfaceModel: WindowRootSurfaceModel? = nil,
            lifecycleProbe: (@MainActor (LifecycleEvent) -> Void)? = nil
        ) {
            self.policy = policy
            _windowState = StateObject(wrappedValue: windowState())
            self.settings = settings
            self.isGraphHost = isGraphHost
            _rootSurfaceModel = StateObject(
                wrappedValue: rootSurfaceModel ?? WindowRootSurfaceModel(initial: Self.rootSurface(policy: policy))
            )
            self.lifecycleProbe = lifecycleProbe
        }
    #else
        @MainActor
        init(
            policy: OrchestrationGraphWindowPolicy,
            windowState: @autoclosure @escaping () -> WindowState,
            settings: GlobalSettingsStore = .shared,
            isGraphHost: @escaping @MainActor (WindowState) -> Bool = {
                WindowStatesManager.shared.allWindows.first === $0
            },
            rootSurfaceModel: WindowRootSurfaceModel? = nil
        ) {
            self.policy = policy
            _windowState = StateObject(wrappedValue: windowState())
            self.settings = settings
            self.isGraphHost = isGraphHost
            _rootSurfaceModel = StateObject(
                wrappedValue: rootSurfaceModel ?? WindowRootSurfaceModel(initial: Self.rootSurface(policy: policy))
            )
        }
    #endif

    @MainActor
    static func rootSurface(policy: OrchestrationGraphWindowPolicy) -> RootSurface {
        policy.mountsGraphShell ? .orchestrationGraphShell : .contentView
    }

    /// Applies the orchestration graph flag to this window's mounted surface. Called from the
    /// settings-observing `.onReceive` below; a hosted test may also call it directly.
    func applyOrchestrationGraphEnabled(_ enabled: Bool) {
        rootSurfaceModel.apply(graphEnabled: enabled, isGraphHost: isGraphHost(windowState))
    }

    #if DEBUG
        /// The surface `body` currently switches on.
        var storedRootSurfaceForTesting: RootSurface {
            rootSurfaceModel.surface
        }
    #endif

    var body: some View {
        ZStack {
            rootSurfaceView
        }
        .safeAreaInset(edge: .top) { GlobalSettingsPersistenceBlockBanner(allowsSessionDismissal: true) }
        .environmentObject(windowState) // If your subviews need it
        .environmentObject(sparkleManager)
        .environmentObject(versionManager) // Pass versionManager to ContentView
        // Let SwiftUI own the window title. Without this, the scene re-applies the
        // default app-name title over the workspace name whenever it refreshes the
        // window chrome (visible in both window titles and native tab names).
        .navigationTitle(windowState.displayedWindowTitle)
        .removingSystemToolbarTitle()
        .background(
            WindowAccessor { newWindow in
                // IMPORTANT: do not mutate SwiftUI @State here.
                // Attach is internally guarded and safe even if called multiple times.
                windowState.attachWindow(newWindow)
            }
        )
        // Once the view appears, register it with WindowStatesManager. This container's
        // identity does not depend on the mounted surface, so a graph-flag hot-swap never
        // fires this again.
        .onAppear {
            windowStatesManager.registerWindowState(windowState)

            // Install the openWindow action into AppWindowOpener for programmatic window creation
            AppWindowOpener.shared.install {
                openWindow(id: "main")
            }
            #if DEBUG
                lifecycleProbe?(.containerAppeared)
            #endif
        }
        // Cleanup if the window goes away
        .onDisappear {
            #if DEBUG
                lifecycleProbe?(.containerDisappeared)
            #endif
            SettingsWindowCoordinator.shared.closeIfTargeting(windowState)

            // Stop focus/title side-effects early to avoid SwiftUI observation crashes during teardown.
            windowState.beginClose()

            // Save the current workspace state before closing, but avoid extra teardown work
            // or publish-heavy persistence once app termination has begun.
            if !windowStatesManager.isTerminating {
                windowState.workspaceManager.pollAndSaveState()
            }

            guard !windowStatesManager.isTerminating else {
                windowState.aiQueriesService.cancelQuery()
                return
            }

            windowStatesManager.unregisterWindowState(windowState)
            Task { await windowState.tearDown() }
        }
        // The graph flag can change while this window stays open; every writer (the Settings
        // toggle and the MCP settings tool) goes through the store, so observing it here covers
        // both. The read is synchronous: this setter publishes `objectWillChange` after mutating.
        .onReceive(settings.objectWillChange) { _ in
            applyOrchestrationGraphEnabled(settings.orchestrationGraphEnabled())
        }
        // Example sheets or popups
        .sheet(isPresented: $versionManager.shouldShowWelcomeView) {
            WelcomeView(isPresented: $versionManager.shouldShowWelcomeView, versionManager: versionManager)
        }
        .sheet(isPresented: $versionManager.shouldShowVersionPopup) {
            VersionPopupView(isPresented: $versionManager.shouldShowVersionPopup)
        }
    }

    @ViewBuilder
    private var rootSurfaceView: some View {
        switch rootSurfaceModel.surface {
        case .contentView:
            ContentView(windowState: windowState)
                .onAppear {
                    #if DEBUG
                        lifecycleProbe?(.surfaceAppeared(.contentView))
                    #endif
                }
                .onDisappear {
                    #if DEBUG
                        lifecycleProbe?(.surfaceDisappeared(.contentView))
                    #endif
                }
        case .orchestrationGraphShell:
            OrchestrationGraphShell(windowState: windowState)
                .onAppear {
                    #if DEBUG
                        lifecycleProbe?(.surfaceAppeared(.orchestrationGraphShell))
                    #endif
                }
                .onDisappear {
                    #if DEBUG
                        lifecycleProbe?(.surfaceDisappeared(.orchestrationGraphShell))
                    #endif
                }
        }
    }
}

/// Owns the mounted root surface for one window. Plain state, no subscription: `body` reads
/// `surface`; `applyOrchestrationGraphEnabled` is the only writer.
@MainActor
final class WindowRootSurfaceModel: ObservableObject {
    @Published private(set) var surface: WindowContentView.RootSurface

    init(initial: WindowContentView.RootSurface) {
        surface = initial
    }

    /// - `graphEnabled == true` and `isGraphHost == true`: swap to the graph shell.
    /// - `graphEnabled == true` and `isGraphHost == false`: no change (not the graph host).
    /// - `graphEnabled == false`: swap to the workspace content view.
    /// Setting the value it already holds does not publish.
    func apply(graphEnabled: Bool, isGraphHost: Bool) {
        let newSurface: WindowContentView.RootSurface
        if graphEnabled {
            guard isGraphHost else { return }
            newSurface = .orchestrationGraphShell
        } else {
            newSurface = .contentView
        }
        guard newSurface != surface else { return }
        surface = newSurface
    }
}

private extension View {
    @ViewBuilder
    func removingSystemToolbarTitle() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .title)
        } else {
            self
        }
    }
}
