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
    /// Asked when the backing view joins a window. Normal native attachment and SwiftUI updates
    /// use the 50 ms debounce; a pending park-on-open intent delivers a non-nil attachment at once.
    let deliversAttachEarly: () -> Bool
    private let attachmentIsCurrent: (NSWindow?) -> Bool
    private let allowsNonNilScheduling: () -> Bool

    fileprivate init(
        deliversAttachEarly: @escaping () -> Bool,
        attachmentIsCurrent: @escaping (NSWindow?) -> Bool,
        allowsNonNilScheduling: @escaping () -> Bool,
        callback: @escaping (NSWindow?) -> Void
    ) {
        self.deliversAttachEarly = deliversAttachEarly
        self.attachmentIsCurrent = attachmentIsCurrent
        self.allowsNonNilScheduling = allowsNonNilScheduling
        self.callback = callback
    }

    /// The only construction of this accessor for a window: pending park-on-open attaches immediately;
    /// otherwise native attachment and SwiftUI updates are delivered through the debounce.
    static func attaching(_ windowState: WindowState) -> WindowAccessor {
        let source = NSObject()
        return WindowAccessor(
            deliversAttachEarly: { windowState.holdsPendingParkIntent },
            attachmentIsCurrent: { windowState.accessorAttachmentIsCurrent($0, source: source) },
            allowsNonNilScheduling: { !windowState.isClosing },
            callback: { newWindow in
                windowState.attachWindow(newWindow, source: source)
            }
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            callback: callback,
            deliversAttachEarly: deliversAttachEarly,
            attachmentIsCurrent: attachmentIsCurrent,
            allowsNonNilScheduling: allowsNonNilScheduling
        )
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
        private let attachmentIsCurrent: (NSWindow?) -> Bool
        private let allowsNonNilScheduling: () -> Bool
        private weak var nativeWindow: NSWindow?
        private var hasNativeObservation = false
        private weak var swiftUICandidate: NSWindow?
        private var pendingCallback: DispatchWorkItem?
        private let callbackWorkGate = WorkItemGate()

        init(
            callback: @escaping (NSWindow?) -> Void,
            deliversAttachEarly: @escaping () -> Bool,
            attachmentIsCurrent: @escaping (NSWindow?) -> Bool,
            allowsNonNilScheduling: @escaping () -> Bool
        ) {
            self.callback = callback
            self.deliversAttachEarly = deliversAttachEarly
            self.attachmentIsCurrent = attachmentIsCurrent
            self.allowsNonNilScheduling = allowsNonNilScheduling
        }

        func backingViewMoved(to window: NSWindow?) {
            hasNativeObservation = true
            nativeWindow = window
            if let window, deliversAttachEarly() {
                deliverNow(window: window)
            } else {
                scheduleNativeDelivery()
            }
        }

        private func deliverNow(window: NSWindow) {
            cancelPendingCallback()
            guard !attachmentIsCurrent(window) else { return }
            callback(window)
        }

        func schedule(window: NSWindow?) {
            guard window == nil || allowsNonNilScheduling() else { return }
            guard !hasNativeObservation else { return }
            guard swiftUICandidate !== window || pendingCallback == nil else { return }
            swiftUICandidate = window
            scheduleDelivery()
        }

        private func scheduleNativeDelivery() {
            guard nativeWindow == nil || allowsNonNilScheduling() else { return }
            scheduleDelivery()
        }

        private func scheduleDelivery(delay: TimeInterval = 0.05) {
            cancelPendingCallback()
            pendingCallback = callbackWorkGate.schedule(after: delay) { [weak self] in
                guard let self else { return }
                pendingCallback = nil
                let window = hasNativeObservation ? nativeWindow : swiftUICandidate
                guard window != nil || hasNativeObservation else { return }
                guard !attachmentIsCurrent(window) else { return }
                callback(window)
            }
        }

        private func cancelPendingCallback() {
            pendingCallback?.cancel()
            pendingCallback = nil
            callbackWorkGate.cancel()
        }

        deinit {
            cancelPendingCallback()
        }
    }
}
