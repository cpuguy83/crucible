import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var viewModel: TrayViewModel?
    private static var explicitQuitRequested = false
    private var shouldTerminate = false

    static func requestQuit() {
        explicitQuitRequested = true
        NSApplication.shared.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !Self.explicitQuitRequested, let window = sender.keyWindow ?? sender.mainWindow {
            window.close()
            return .terminateCancel
        }

        guard !shouldTerminate, let viewModel = Self.viewModel else { return .terminateNow }

        Task { @MainActor in
            await viewModel.shutdownForTermination()
            shouldTerminate = true
            sender.terminate(nil)
        }
        return .terminateLater
    }
}
