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

        Menu("Storage") {
            Text(viewModel.storageUsage?.displayText ?? "State image: not created")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Refresh storage usage", action: viewModel.refreshStorageUsage)
            Divider()
            Button("Prune BuildKit cache…", action: viewModel.pruneBuildKitCache)
                .disabled(!viewModel.isRunning)
            Button("Reset BuildKit state…", action: viewModel.resetState)
                .disabled(!viewModel.canResetState)
        }

        Divider()

        Button("Open Logs…", action: viewModel.openLogsWindow)
        Button("Copy diagnostics summary", action: viewModel.copyDiagnosticsSummary)

        if let ep = viewModel.endpoint {
            Divider()
            Button("Copy socket path") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(ep.socketPath, forType: .string)
            }
            Menu("Use with…") {
                Text("buildx: \(viewModel.buildxStatus.displayText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Button("Add and use docker buildx builder", action: viewModel.addToBuildx)
                Button("Refresh buildx status", action: viewModel.refreshBuildxStatus)
                Button("Recreate buildx builder", action: viewModel.recreateBuildxBuilder)
                Button("Remove buildx builder", action: viewModel.removeBuildxBuilder)
                Divider()
                Button("Copy `docker buildx create` command", action: viewModel.copyBuildxCreateCommand)
                Button("Copy BUILDKIT_HOST env line", action: viewModel.copyBuildKitHostEnv)
            }
            .disabled(!viewModel.isRunning)
        }

        Divider()

        if let info = viewModel.lastInfo {
            Text(info)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let err = viewModel.lastError {
            Text("Error:")
                .font(.caption.bold())
            // Truncate visually but full text is one click away.
            Text(err.prefix(140) + (err.count > 140 ? "…" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Copy error to clipboard", action: viewModel.copyLastErrorToPasteboard)
        }

        if !viewModel.logTail.isEmpty {
            Button("Copy last \(viewModel.logTail.count) log lines", action: viewModel.copyLogsToPasteboard)
        }

        Divider()
        Button("Quit Crucible") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
