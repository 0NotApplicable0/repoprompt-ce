import AppKit

@MainActor
final class DockMenuController: NSObject {
    private let activateApplication: @MainActor () -> Void
    private let requestNewWindow: @MainActor () -> Void
    private let openFleetManager: @MainActor () -> Void

    init(
        activateApplication: @escaping @MainActor () -> Void = {
            NSApplication.shared.activate(ignoringOtherApps: true)
        },
        requestNewWindow: @escaping @MainActor () -> Void = {
            AppWindowOpener.shared.requestMainWindowFromDock()
        },
        openFleetManager: @escaping @MainActor () -> Void = {
            FleetParkingCoordinator.shared.openFleetManager()
        }
    ) {
        self.activateApplication = activateApplication
        self.requestNewWindow = requestNewWindow
        self.openFleetManager = openFleetManager
        super.init()
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let newWindowItem = NSMenuItem(
            title: "New Window",
            action: #selector(openNewWindow(_:)),
            keyEquivalent: ""
        )
        newWindowItem.target = self
        menu.addItem(newWindowItem)

        let fleetManagerItem = NSMenuItem(
            title: "Fleet Manager",
            action: #selector(showFleetManager(_:)),
            keyEquivalent: ""
        )
        fleetManagerItem.target = self
        menu.addItem(fleetManagerItem)
        return menu
    }

    @objc private func openNewWindow(_ sender: Any?) {
        requestNewWindow()
        activateApplication()
    }

    @objc private func showFleetManager(_ sender: Any?) {
        openFleetManager()
        activateApplication()
    }
}
