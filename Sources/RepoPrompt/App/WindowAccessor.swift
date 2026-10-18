//
//  WindowAccessor.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2024-12-21.
//

import AppKit
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow?) -> Void
    /// Asked when the backing view joins a window. Only while it answers true is that window handed to
    /// `callback` at once; otherwise delivery waits for the SwiftUI update through the 50 ms debounce.
    let deliversAttachEarly: () -> Bool

    fileprivate init(deliversAttachEarly: @escaping () -> Bool, callback: @escaping (NSWindow?) -> Void) {
        self.deliversAttachEarly = deliversAttachEarly
        self.callback = callback
    }

    /// The only construction of this accessor for a window: attach is delivered at the native attach
    /// while the window still holds a pending park intent, and through the SwiftUI update otherwise.
    static func attaching(_ windowState: WindowState) -> WindowAccessor {
        WindowAccessor(deliversAttachEarly: { windowState.holdsPendingParkIntent }) { newWindow in
            windowState.attachWindow(newWindow)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(callback: callback, deliversAttachEarly: deliversAttachEarly)
    }

    func makeNSView(context: Context) -> NSView {
        let view = AttachObservingView(frame: .zero)
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.backingViewMoved(to: window)
        }
        context.coordinator.schedule(window: view.window)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.schedule(window: nsView.window)
    }

    final class AttachObservingView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }

    final class Coordinator {
        private let callback: (NSWindow?) -> Void
        private let deliversAttachEarly: () -> Bool
        private weak var lastWindow: NSWindow?
        private var tokens: [NSObjectProtocol] = []
        private var pendingCallback: DispatchWorkItem?
        private let callbackWorkGate = WorkItemGate()

        init(callback: @escaping (NSWindow?) -> Void, deliversAttachEarly: @escaping () -> Bool) {
            self.callback = callback
            self.deliversAttachEarly = deliversAttachEarly
        }

        func backingViewMoved(to window: NSWindow?) {
            guard let window, deliversAttachEarly() else { return }
            deliverNow(window: window)
        }

        private func deliverNow(window: NSWindow) {
            guard lastWindow !== window else { return }
            lastWindow = window
            installObservers(for: window) // also cancels any obsolete queued legacy delivery
            callback(window)
        }

        func schedule(window: NSWindow?) {
            guard lastWindow !== window else { return }
            lastWindow = window
            installObservers(for: window)
            fireCallbackDebounced(for: window)
        }

        private func fireCallbackDebounced(for window: NSWindow?, delay: TimeInterval = 0.05) {
            pendingCallback?.cancel()
            callbackWorkGate.cancel()
            pendingCallback = callbackWorkGate.schedule(after: delay) { [weak self, weak window] in
                guard let self else { return }
                callback(window)
            }
        }

        private func installObservers(for window: NSWindow?) {
            removeObservers()
            guard window != nil else { return }
            // Intentionally no extra observers; WindowState handles focus/title updates.
        }

        private func removeObservers() {
            for t in tokens {
                NotificationCenter.default.removeObserver(t)
            }
            tokens.removeAll()
            pendingCallback?.cancel()
            pendingCallback = nil
            callbackWorkGate.cancel()
        }

        deinit {
            removeObservers()
        }
    }
}
