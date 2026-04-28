import SwiftUI
import AppKit
import BuildKitCore

struct TrayMenu: View {
    @ObservedObject var viewModel: TrayViewModel

    var body: some View {
        Text(viewModel.statusText)

        Divider()

        Button("Start", action: viewModel.startFromMenu)
            .disabled(!viewModel.canStart)
        Button("Stop", action: viewModel.stop)
            .disabled(!viewModel.canStop)
        Button("Restart", action: viewModel.restart)
            .disabled(!viewModel.canRestart)

        Divider()

        Button("Open Logs…", action: viewModel.openLogsWindow)
        Button("Settings…", action: viewModel.openSettingsWindow)

        if let ep = viewModel.endpoint {
            Divider()
            Button("Copy socket path") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(ep.socketPath, forType: .string)
            }
        }

        Divider()

        if let err = viewModel.lastError {
            Text("Error:")
                .font(.caption.bold())
            // Truncate visually but full text is one click away.
            Text(err.prefix(140) + (err.count > 140 ? "…" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Copy error to clipboard", action: viewModel.copyLastErrorToPasteboard)
        }

        Divider()
        Button("Quit Crucible") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
