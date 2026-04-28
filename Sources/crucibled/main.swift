import Foundation
import BuildKitCore
import BuildKitContainerCLI
import BuildKitContainerization
import Darwin

/// Headless smoke driver. Starts the Containerization backend, prints
/// state/progress/log events to stderr, and waits until the user hits
/// Ctrl-C. Lets us debug VM boot without the GUI.
@main
struct Main {
    static func main() async {
        // See CrucibleApp.init(): avoid host process termination when the
        // socket relay writes to a build client that has closed its end.
        signal(SIGPIPE, SIG_IGN)

        let args = CommandLine.arguments
        let smoke = args.contains("--smoke")
        let backendKind = Self.optionValue("--backend", in: args) ?? "framework"
        var settings = Self.settings(for: backendKind)
        if backendKind == "cli" || backendKind == "container-cli" {
            do {
                let kernel = try await KernelLocator.locateOrDownload(settings: settings) { progress in
                    fputs("KERNEL[\(progress.phase)]: \(progress.bytesReceived)\n", stderr)
                }
                settings.kernelOverridePath = kernel.path
            } catch {
                fputs("failed to prepare CLI smoke kernel: \(error)\n", stderr)
                exit(1)
            }
        }
        let backend: any BuildKitBackend
        switch backendKind {
        case "framework", "containerization":
            backend = ContainerizationBackend(settings: settings)
        case "cli", "container-cli":
            backend = ContainerCLIBackend(
                settings: settings,
                appRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("crucibled-cli-smoke", isDirectory: true)
            )
        default:
            fputs("unknown --backend \(backendKind); expected framework or cli\n", stderr)
            exit(2)
        }

        // Subscribe before start() so we don't miss early events.
        let stateStream = backend.stateStream
        let progressStream = backend.progressStream
        let logStream = backend.logStream

        Task.detached {
            for await s in stateStream { fputs("STATE: \(s)\n", stderr) }
        }
        Task.detached {
            for await p in progressStream {
                fputs("PROGRESS[\(p.phase.rawValue)]: \(p.message)\n", stderr)
            }
        }
        Task.detached {
            for await line in logStream { fputs("\(line)\n", stderr) }
        }

        do {
            fputs("starting \(backendKind)...\n", stderr)
            try await backend.start()
            if smoke {
                fputs("started; smoke passed. stopping...\n", stderr)
                try await backend.stop()
                fputs("stopped.\n", stderr)
                return
            }

            fputs("started; running. Ctrl-C to stop.\n", stderr)
            // Idle.
            try await Task.sleep(nanoseconds: UInt64.max / 2)
        } catch {
            fputs("START FAILED: \(error)\n", stderr)
            // Reflect it on `as NSError` too in case it's a wrapped Cocoa error.
            let ns = error as NSError
            fputs("  domain=\(ns.domain) code=\(ns.code)\n", stderr)
            fputs("  userInfo=\(ns.userInfo)\n", stderr)
            exit(1)
        }
    }

    private static func optionValue(_ name: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    private static func settings(for backend: String) -> BuildKitSettings {
        guard backend == "cli" || backend == "container-cli" else { return BuildKitSettings() }
        return BuildKitSettings(
            backend: .containerCLI,
            hostSocketPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("crucibled-cli-buildkitd.sock").path,
            autoStart: false
        )
    }
}
