import Foundation
import BuildKitCore
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

        let settings = BuildKitSettings()
        let backend = ContainerizationBackend(settings: settings)

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
            fputs("starting...\n", stderr)
            try await backend.start()
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
}
