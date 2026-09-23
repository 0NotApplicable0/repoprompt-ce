import Cocoa
import MCP
@testable import RepoPromptApp
@testable import RepoPromptDomainRuntime
import SwiftUI
import XCTest

#if DEBUG
    /// OG-12 / DW-3: turning the orchestration graph flag on or off hot-swaps the already-open
    /// window's mounted surface, in place, on the same `WindowState`. No new window opens, no
    /// running session is disturbed, and the window never closes.
    @MainActor
    final class OrchestrationGraphHotswapTests: XCTestCase {
        private var originalWindows: [WindowState] = []
        private var storageRoot: URL!
        private var runtime: MCPDomainRuntime!
        private var addedWindows: [WindowState] = []
        private var hostedWindows: [NSWindow] = []
        /// Constructed once for the whole test class: `SPUStandardUpdaterController` and
        /// `DockMenuController` are process-wide singletons-in-spirit, so repeatedly constructing
        /// and releasing an `AppDelegate` per test crashes during teardown. Never torn down.
        private static let sharedAppDelegate = AppDelegate()
        private var sparkleManager: SparkleUpdaterManager!
        private var settingsDefaultsSuiteName: String!
        private var settingsFileURL: URL!
        private var isolatedSettings: GlobalSettingsStore!

        override func setUp() async throws {
            try await super.setUp()
            AppWindowOpener.shared.resetForTesting()
            AppWindowOpener.shared.policy = .production
            originalWindows = WindowStatesManager.shared.allWindows
            WindowStatesManager.shared.allWindows = []

            storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("OrchestrationGraphHotswapTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            let agentWorkspaceRoot = storageRoot.appendingPathComponent("AgentWorkspaces", isDirectory: true)
            let chatWorkspaceRoot = storageRoot.appendingPathComponent("ChatWorkspaces", isDirectory: true)
            try FileManager.default.createDirectory(at: agentWorkspaceRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: chatWorkspaceRoot, withIntermediateDirectories: true)
            await AgentSessionDataService.shared.test_setWorkspaceRootOverride(agentWorkspaceRoot)
            await ChatDataService.test_setWorkspaceRootOverride(chatWorkspaceRoot)
            runtime = MCPDomainRuntime(configuration: .init(
                mode: .app,
                profileIdentifier: "orchestration-graph-hotswap-\(UUID().uuidString)",
                storageDirectory: storageRoot.appendingPathComponent("runtime-state", isDirectory: true),
                workspaceStorageDirectory: storageRoot,
                eventDirectory: storageRoot.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storageRoot.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil
            ))
            try await runtime.start()

            settingsDefaultsSuiteName = "OrchestrationGraphHotswapTests-\(UUID().uuidString)"
            settingsFileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("json")
            let defaults = try XCTUnwrap(UserDefaults(suiteName: settingsDefaultsSuiteName))
            isolatedSettings = GlobalSettingsStore(
                defaults: defaults,
                fileStore: GlobalSettingsFileStore(fileURL: settingsFileURL)
            )

            sparkleManager = Self.sharedAppDelegate.sparkleManager
        }

        override func tearDown() async throws {
            // Suppress WindowContentView's own onDisappear unregister+tearDown while the hosted
            // windows close: production runs that cleanup as a fire-and-forget `Task`, which
            // would race the explicit `window.tearDown()` below on the same `WindowState` and
            // double-release it (the teardown SIGSEGV). `isTerminating` short-circuits onDisappear
            // to just `cancelQuery()`, leaving unregister+tearDown solely to this loop.
            WindowStatesManager.shared.setTerminatingForTesting(true)
            for window in hostedWindows.reversed() {
                window.contentView = nil
                window.close()
            }
            hostedWindows.removeAll()
            WindowStatesManager.shared.setTerminatingForTesting(false)
            for window in addedWindows.reversed() {
                WindowStatesManager.shared.unregisterWindowState(window)
                await window.tearDown()
            }
            addedWindows.removeAll()
            WindowStatesManager.shared.allWindows = originalWindows
            AppWindowOpener.shared.resetForTesting()
            AppWindowOpener.shared.policy = .production
            if let runtime {
                _ = await runtime.shutdown()
            }
            runtime = nil
            await AgentSessionDataService.shared.test_setWorkspaceRootOverride(nil)
            await ChatDataService.test_setWorkspaceRootOverride(nil)
            if let storageRoot {
                try? FileManager.default.removeItem(at: storageRoot)
            }
            if let settingsDefaultsSuiteName {
                UserDefaults(suiteName: settingsDefaultsSuiteName)?.removePersistentDomain(forName: settingsDefaultsSuiteName)
            }
            if let settingsFileURL {
                try? FileManager.default.removeItem(at: settingsFileURL)
            }
            isolatedSettings = nil
            sparkleManager = nil
            try await super.tearDown()
        }

        // MARK: - Tests

        func testExistingWindowSwapsToGraphAndBackOnTheSameWindowState() async {
            let fixture = makeFixtureWindow()
            let recorder = HotswapLifecycleRecorder()
            let step0 = recorder.expect("containerAppeared", when: isEvent(.containerAppeared))
            let hosted = hostWindow(policy: policy(graphEnabled: false), windowState: fixture, settings: isolatedSettings, recorder: recorder)
            await fulfillment(of: [step0], timeout: 5)

            let stepCount = WindowStatesManager.shared.allWindows.count
            var openCount = 0
            AppWindowOpener.shared.install { openCount += 1 }

            XCTAssertEqual(hosted.model.surface, .contentView)

            let step1Appear = recorder.expect("surfaceAppeared graph", when: isEvent(.surfaceAppeared(.orchestrationGraphShell)))
            let step1Disappear = recorder.expect("surfaceDisappeared content", when: isEvent(.surfaceDisappeared(.contentView)))
            // Drive the same `applyOrchestrationGraphEnabled` entry point the settings observer
            // uses (3.2). Calling the method directly on a detached, uninstalled copy of the
            // hosted view struct is unsafe with this SDK's @StateObject enforcement (it crashes
            // the test process), so the isolated store is the trigger here too.
            isolatedSettings.setOrchestrationGraphEnabled(true, commit: false)
            await fulfillment(of: [step1Appear, step1Disappear], timeout: 5)
            XCTAssertEqual(hosted.model.surface, .orchestrationGraphShell)

            let step2Appear = recorder.expect("surfaceAppeared content", when: isEvent(.surfaceAppeared(.contentView)))
            let step2Disappear = recorder.expect("surfaceDisappeared graph", when: isEvent(.surfaceDisappeared(.orchestrationGraphShell)))
            isolatedSettings.setOrchestrationGraphEnabled(false, commit: false)
            await fulfillment(of: [step2Appear, step2Disappear], timeout: 5)
            XCTAssertEqual(hosted.model.surface, .contentView)

            XCTAssertTrue(WindowStatesManager.shared.allWindows.contains { $0 === fixture })
            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, stepCount)
            XCTAssertFalse(fixture.isClosing)
            XCTAssertEqual(openCount, 0)
            XCTAssertFalse(recorder.events.contains(WindowContentView.LifecycleEvent.containerDisappeared))
        }

        func testHotswapLeavesInstalledRunStateRunning() async {
            let fixture = makeFixtureWindow()
            let recorder = HotswapLifecycleRecorder()
            let step0 = recorder.expect("containerAppeared", when: isEvent(.containerAppeared))
            _ = hostWindow(policy: policy(graphEnabled: false), windowState: fixture, settings: isolatedSettings, recorder: recorder)
            await fulfillment(of: [step0], timeout: 5)

            let tab = AgentTabSession(tabID: UUID())
            tab.runState = .running
            fixture.agentModeViewModel.test_installLiveSession(tab)
            XCTAssertEqual(tab.runState, .running)

            let step1 = recorder.expect("surfaceAppeared graph", when: isEvent(.surfaceAppeared(.orchestrationGraphShell)))
            isolatedSettings.setOrchestrationGraphEnabled(true, commit: false)
            await fulfillment(of: [step1], timeout: 5)

            let step2 = recorder.expect("surfaceAppeared content", when: isEvent(.surfaceAppeared(.contentView)))
            isolatedSettings.setOrchestrationGraphEnabled(false, commit: false)
            await fulfillment(of: [step2], timeout: 5)

            XCTAssertEqual(tab.runState, .running)
        }

        func testSettingsToggleSwapsTheOpenWindow() async {
            let fixture = makeFixtureWindow()
            let recorder = HotswapLifecycleRecorder()
            let step0 = recorder.expect("containerAppeared", when: isEvent(.containerAppeared))
            let hosted = hostWindow(policy: policy(graphEnabled: false), windowState: fixture, settings: isolatedSettings, recorder: recorder)
            await fulfillment(of: [step0], timeout: 5)
            let stepCount = WindowStatesManager.shared.allWindows.count

            let step1 = recorder.expect("surfaceAppeared graph", when: isEvent(.surfaceAppeared(.orchestrationGraphShell)))
            isolatedSettings.setOrchestrationGraphEnabled(true, commit: false)
            await fulfillment(of: [step1], timeout: 5)
            XCTAssertEqual(hosted.model.surface, .orchestrationGraphShell)

            let step2 = recorder.expect("surfaceAppeared content", when: isEvent(.surfaceAppeared(.contentView)))
            isolatedSettings.setOrchestrationGraphEnabled(false, commit: false)
            await fulfillment(of: [step2], timeout: 5)
            XCTAssertEqual(hosted.model.surface, .contentView)

            XCTAssertTrue(WindowStatesManager.shared.allWindows.contains { $0 === fixture })
            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, stepCount)
            XCTAssertFalse(fixture.isClosing)
        }

        func testToggleOnSwapsOnlyTheGraphHostWindow() async {
            let hostFixture = makeFixtureWindow()
            let hostRecorder = HotswapLifecycleRecorder()
            let hostStep0 = hostRecorder.expect("host containerAppeared", when: isEvent(.containerAppeared))
            let hostHosted = hostWindow(
                policy: policy(graphEnabled: false),
                windowState: hostFixture,
                settings: isolatedSettings,
                recorder: hostRecorder
            )
            await fulfillment(of: [hostStep0], timeout: 5)

            let otherFixture = makeFixtureWindow()
            let otherRecorder = HotswapLifecycleRecorder()
            let otherStep0 = otherRecorder.expect("other containerAppeared", when: isEvent(.containerAppeared))
            let otherHosted = hostWindow(
                policy: policy(graphEnabled: false),
                windowState: otherFixture,
                settings: isolatedSettings,
                recorder: otherRecorder
            )
            await fulfillment(of: [otherStep0], timeout: 5)

            XCTAssertTrue(WindowStatesManager.shared.allWindows.first === hostFixture)
            // Baseline after both windows have mounted: each records its own initial
            // `.surfaceAppeared(.contentView)` at first render, which is not a swap.
            let otherEventCountBeforeToggle = otherRecorder.events.count

            let hostStep1 = hostRecorder.expect("host surfaceAppeared graph", when: isEvent(.surfaceAppeared(.orchestrationGraphShell)))
            isolatedSettings.setOrchestrationGraphEnabled(true, commit: false)
            await fulfillment(of: [hostStep1], timeout: 5)

            XCTAssertEqual(hostHosted.model.surface, .orchestrationGraphShell)
            XCTAssertEqual(otherHosted.model.surface, .contentView)
            XCTAssertEqual(otherRecorder.events.count, otherEventCountBeforeToggle)

            let hostStep2 = hostRecorder.expect("host surfaceAppeared content", when: isEvent(.surfaceAppeared(.contentView)))
            isolatedSettings.setOrchestrationGraphEnabled(false, commit: false)
            await fulfillment(of: [hostStep2], timeout: 5)

            XCTAssertEqual(hostHosted.model.surface, .contentView)
            XCTAssertEqual(otherHosted.model.surface, .contentView)
        }

        func testSurfaceSwapDoesNotCloseTheWindow() async {
            let fixture = makeFixtureWindow()
            let recorder = HotswapLifecycleRecorder()
            let step0 = recorder.expect("containerAppeared", when: isEvent(.containerAppeared))
            _ = hostWindow(policy: policy(graphEnabled: false), windowState: fixture, settings: isolatedSettings, recorder: recorder)
            await fulfillment(of: [step0], timeout: 5)
            let stepCount = WindowStatesManager.shared.allWindows.count

            let step1Appear = recorder.expect("surfaceAppeared graph", when: isEvent(.surfaceAppeared(.orchestrationGraphShell)))
            let step1Disappear = recorder.expect("surfaceDisappeared content", when: isEvent(.surfaceDisappeared(.contentView)))
            isolatedSettings.setOrchestrationGraphEnabled(true, commit: false)
            await fulfillment(of: [step1Appear, step1Disappear], timeout: 5)

            let step2Appear = recorder.expect("surfaceAppeared content", when: isEvent(.surfaceAppeared(.contentView)))
            let step2Disappear = recorder.expect("surfaceDisappeared graph", when: isEvent(.surfaceDisappeared(.orchestrationGraphShell)))
            isolatedSettings.setOrchestrationGraphEnabled(false, commit: false)
            await fulfillment(of: [step2Appear, step2Disappear], timeout: 5)

            let containerAppearedCount = recorder.events.count(where: { $0 == WindowContentView.LifecycleEvent.containerAppeared })
            let containerDisappearedCount = recorder.events.count(where: { $0 == WindowContentView.LifecycleEvent.containerDisappeared })
            XCTAssertEqual(containerAppearedCount, 1)
            XCTAssertEqual(containerDisappearedCount, 0)

            let surfaceEvents: [WindowContentView.LifecycleEvent] = recorder.events.filter { event in
                switch event {
                case .surfaceAppeared, .surfaceDisappeared: true
                case .containerAppeared, .containerDisappeared: false
                }
            }
            let expectedSurfaceEvents: [WindowContentView.LifecycleEvent] = [
                .surfaceAppeared(.contentView),
                .surfaceAppeared(.orchestrationGraphShell),
                .surfaceDisappeared(.contentView),
                .surfaceAppeared(.contentView),
                .surfaceDisappeared(.orchestrationGraphShell)
            ]
            XCTAssertEqual(surfaceEvents, expectedSurfaceEvents)

            XCTAssertTrue(WindowStatesManager.shared.allWindows.contains { $0 === fixture })
            XCTAssertEqual(WindowStatesManager.shared.allWindows.count, stepCount)
            XCTAssertFalse(fixture.isClosing)
        }

        // MARK: - Helpers

        private func policy(graphEnabled: Bool) -> OrchestrationGraphWindowPolicy {
            OrchestrationGraphWindowPolicy(isGraphEnabled: { graphEnabled })
        }

        private func isEvent(
            _ event: WindowContentView.LifecycleEvent
        ) -> (WindowContentView.LifecycleEvent) -> Bool {
            { $0 == event }
        }

        @discardableResult
        private func makeFixtureWindow() -> WindowState {
            let window = WindowState(domainRuntime: runtime)
            addedWindows.append(window)
            return window
        }

        /// Hosts `WindowContentView` in a real `NSWindow` so `.onAppear` / `.onDisappear` fire (a
        /// bare `NSHostingView` host does not). The window is kept alive by `hostedWindows` until
        /// `tearDown`.
        private func hostWindow(
            policy: OrchestrationGraphWindowPolicy,
            windowState: WindowState,
            settings: GlobalSettingsStore,
            recorder: HotswapLifecycleRecorder
        ) -> HostedWindow {
            let model = WindowRootSurfaceModel(initial: WindowContentView.rootSurface(policy: policy))
            let view = WindowContentView(
                policy: policy,
                windowState: windowState,
                settings: settings,
                rootSurfaceModel: model,
                lifecycleProbe: { [recorder] (event: WindowContentView.LifecycleEvent) in recorder.record(event) }
            )
            let hosted = view
                .environmentObject(VersionManager())
                .environmentObject(WindowStatesManager.shared)
                .environmentObject(sparkleManager!)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            // AppKit defaults a programmatically-created window to release itself on close;
            // `hostedWindows` is the sole ARC owner here, so a second release from `close()`
            // over-releases the window (the teardown SIGSEGV in `objc_release`).
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: hosted)
            window.makeKeyAndOrderFront(nil)
            hostedWindows.append(window)
            return HostedWindow(window: window, model: model, view: view)
        }
    }

    /// Named result of hosting a `WindowContentView` for one test, avoiding tuple-pattern
    /// destructuring at call sites.
    @MainActor
    private struct HostedWindow {
        let window: NSWindow
        let model: WindowRootSurfaceModel
        let view: WindowContentView
    }

    /// Records `WindowContentView.LifecycleEvent`s in order and lets a test wait for a specific
    /// event with an `XCTestExpectation`, satisfying it immediately if the event already occurred.
    @MainActor
    private final class HotswapLifecycleRecorder {
        private(set) var events: [WindowContentView.LifecycleEvent] = []
        private var waiters: [(predicate: (WindowContentView.LifecycleEvent) -> Bool, expectation: XCTestExpectation)] = []

        func record(_ event: WindowContentView.LifecycleEvent) {
            events.append(event)
            waiters.removeAll { waiter in
                guard waiter.predicate(event) else { return false }
                waiter.expectation.fulfill()
                return true
            }
        }

        func expect(
            _ description: String,
            when predicate: @escaping (WindowContentView.LifecycleEvent) -> Bool
        ) -> XCTestExpectation {
            let expectation = XCTestExpectation(description: description)
            if events.contains(where: predicate) {
                expectation.fulfill()
            } else {
                waiters.append((predicate, expectation))
            }
            return expectation
        }
    }
#endif
