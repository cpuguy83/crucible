import AppKit
import SwiftUI

@MainActor
final class LogWindowController: NSWindowController, NSWindowDelegate {
    private let store: LogStore
    private let onClose: () -> Void

    init(store: LogStore, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
        let view = LogsWindowView(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Crucible Logs"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
