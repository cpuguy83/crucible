import SwiftUI
import BuildKitCore
import BuildKitContainerization
import BuildKitContainerCLI
import Darwin

@main
struct CrucibleApp: App {
    @StateObject private var viewModel: TrayViewModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)

        let vm = TrayViewModel()
        _viewModel = StateObject(wrappedValue: vm)
        AppDelegate.viewModel = vm

        // The framework's host-side unix/vsock relay can write to a socket
        // after a build client closes its end. Darwin's default behavior for
        // that is process termination via SIGPIPE, which makes the app/VM
        // disappear immediately after a build completes. Ignore it globally;
        // write calls still fail with EPIPE and relay code can clean up.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        MenuBarExtra {
            TrayMenu(viewModel: viewModel)
        } label: {
            // SF Symbol; will swap for a custom template image later.
            Image(systemName: viewModel.statusSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}
