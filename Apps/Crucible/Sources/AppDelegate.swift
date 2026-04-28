import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var viewModel: TrayViewModel?
    private var shouldTerminate = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !shouldTerminate, let viewModel = Self.viewModel else { return .terminateNow }

        Task { @MainActor in
            await viewModel.shutdownForTermination()
            shouldTerminate = true
            sender.terminate(nil)
        }
        return .terminateLater
    }
}
