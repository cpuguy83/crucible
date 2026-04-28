import SwiftUI
import BuildKitCore
import BuildKitContainerization
import BuildKitContainerCLI
import os

/// Bridges `BuildKitSupervisor` (actor, async) to SwiftUI (`ObservableObject`,
/// main-thread). All published properties are mutated on the main actor.
@MainActor
final class TrayViewModel: ObservableObject {
    @Published private(set) var state: BuildKitState = .stopped
    @Published private(set) var lastError: String?
    @Published private(set) var lastInfo: String?
    @Published private(set) var progressMessage: String?
    @Published private(set) var logTail: [String] = []

    let logStore = LogStore()

    private static let log = Logger(subsystem: "com.cpuguy83.Crucible", category: "tray")

    private let supervisor: BuildKitSupervisor
    private let buildx = BuildxIntegration()
    private var subscriberTask: Task<Void, Never>?
    private var subscribedToBackend = false
    private var logWindowController: LogWindowController?

    init() {
        let settings = BuildKitSettings()
        self.supervisor = BuildKitSupervisor(settings: settings) { s in
            switch s.backend {
            case .containerization:
                return ContainerizationBackend(settings: s)
            case .containerCLI:
                return ContainerCLIBackend(settings: s)
            }
        }

        Task { await self.start() }
    }

    var canStart: Bool {
        switch state {
        case .stopped, .error:
            return true
        case .starting, .running, .degraded, .stopping:
            return false
        }
    }

    var canStop: Bool {
        switch state {
        case .starting, .running, .degraded:
            return true
        case .stopped, .stopping, .error:
            return false
        }
    }

    var canRestart: Bool {
        switch state {
        case .running, .degraded, .error, .stopped:
            return true
        case .starting, .stopping:
            return false
        }
    }

    var canResetState: Bool {
        switch state {
        case .stopped, .error:
            return true
        case .starting, .running, .degraded, .stopping:
            return false
        }
    }

    var statusText: String {
        switch state {
        case .stopped: return "Stopped"
        case .starting: return progressMessage.map { "Starting: \($0)" } ?? "Starting…"
        case .running: return "Running"
        case .degraded(let reason, _): return "Degraded: \(reason)"
        case .stopping: return "Stopping…"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    /// SF Symbol name reflecting current state.
    var statusSymbol: String {
        switch state {
        case .stopped: return "circle"
        case .starting, .stopping: return "circle.dotted"
        case .running: return "circle.fill"
        case .degraded: return "exclamationmark.circle"
        case .error: return "xmark.circle"
        }
    }

    var endpoint: BuildKitEndpoint? {
        switch state {
        case .running(let ep): return ep
        case .degraded(_, let ep): return ep
        default: return nil
        }
    }

    func start() async {
        await subscribeBackendStreamsIfNeeded()
        await run("start") { try await self.supervisor.start() }
    }

    func startFromMenu() {
        Task { await self.start() }
    }

    func stop() {
        Task { await run("stop") { try await self.supervisor.stop() } }
    }

    func shutdownForTermination() async {
        logStore.append(source: .supervisor, level: .info, "Application terminating; stopping BuildKit")
        do {
            try await supervisor.stop()
            state = await supervisor.currentState()
            lastError = nil
            logStore.append(source: .supervisor, level: .info, "BuildKit stopped")
        } catch {
            let msg = String(describing: error)
            lastError = msg
            logStore.append(source: .supervisor, level: .error, "shutdown failed: \(msg)")
            Self.log.error("shutdown failed: \(msg, privacy: .public)")
        }
    }

    func restart() {
        Task {
            await self.subscribeBackendStreamsIfNeeded()
            await run("restart") { try await self.supervisor.restart() }
        }
    }

    /// Stop, wipe persistent buildkitd state (cache, metadata), then leave
    /// the daemon stopped so the user can decide when to restart. Use
    /// when bbolt corruption ("structure needs cleaning") prevents
    /// startup.
    func resetState() {
        Task { await run("resetState") { try await self.supervisor.resetState() } }
    }

    func copyLastErrorToPasteboard() {
        guard let err = lastError else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(err, forType: .string)
    }

    func copyLogsToPasteboard() {
        let text = logStore.events.map(\.rawLine).joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func openLogsWindow() {
        if logWindowController == nil {
            logWindowController = LogWindowController(store: logStore)
        }
        logWindowController?.show()
    }

    // MARK: - Buildx integration

    /// True only when the daemon is running, so menu items that depend on
    /// having a live endpoint can disable themselves.
    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func copyBuildKitHostEnv() {
        guard let ep = endpoint else { return }
        copyToPasteboard(BuildxCommands.buildKitHostEnv(for: ep))
        lastInfo = "Copied BUILDKIT_HOST env"
    }

    func copyBuildxCreateCommand() {
        guard let ep = endpoint else { return }
        copyToPasteboard(BuildxCommands.dockerBuildxCreateCommand(for: ep))
        lastInfo = "Copied docker buildx create command"
    }

    func addToBuildx() {
        guard let ep = endpoint else { return }
        Task { [buildx] in
            let result = await buildx.install(endpoint: ep)
            await MainActor.run {
                switch result {
                case .created(let name):
                    self.lastInfo = "Added '\(name)' to docker buildx"
                    self.lastError = nil
                    self.logStore.append(source: .buildx, level: .info, self.lastInfo ?? "")
                case .alreadyExists(let name):
                    self.lastInfo = "'\(name)' already registered in buildx (set as default)"
                    self.lastError = nil
                    self.logStore.append(source: .buildx, level: .info, self.lastInfo ?? "")
                case .dockerNotFound:
                    self.lastError = "docker not found. Install Docker Desktop, or copy the command and run it in a shell."
                    self.logStore.append(source: .buildx, level: .error, self.lastError ?? "")
                case .failed(let stderr, let code):
                    self.lastError = "docker buildx create failed (exit \(code)):\n\(stderr)"
                    self.logStore.append(source: .buildx, level: .error, self.lastError ?? "")
                }
                Self.log.notice("addToBuildx -> \(String(describing: result), privacy: .public)")
            }
        }
    }

    private func copyToPasteboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    /// Wire up subscriptions to the backend's three async streams. The
    /// backend doesn't exist until `supervisor.start()` (or any other
    /// op) materializes it, so we re-fetch the streams every call and
    /// cancel any prior subscription task.
    private func subscribeBackendStreamsIfNeeded() async {
        // AsyncStream is not a broadcast log bus. Keep one long-lived
        // consumer task attached to the backend streams instead of
        // cancelling/recreating consumers across stop/start cycles.
        guard !subscribedToBackend else { return }

        let streams: (
            state: AsyncStream<BuildKitState>,
            progress: AsyncStream<BuildKitProgress>,
            logs: AsyncStream<String>
        )
        do {
            streams = try await supervisor.streams()
        } catch {
            self.lastError = String(describing: error)
            return
        }
        subscribedToBackend = true

        subscriberTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self?.consumeState(streams.state) }
                group.addTask { await self?.consumeProgress(streams.progress) }
                group.addTask { await self?.consumeLogs(streams.logs) }
            }
            await MainActor.run {
                self?.subscribedToBackend = false
            }
        }
    }

    private func consumeState(_ stream: AsyncStream<BuildKitState>) async {
        for await s in stream {
            await MainActor.run {
                self.state = s
                self.logStore.append(source: .state, String(describing: s))
                Self.log.notice("state: \(String(describing: s), privacy: .public)")
            }
        }
    }

    private func consumeProgress(_ stream: AsyncStream<BuildKitProgress>) async {
        for await p in stream {
            await MainActor.run {
                self.progressMessage = p.message
                self.logStore.append(source: .progress, p.message)
                Self.log.notice("progress[\(p.phase.rawValue, privacy: .public)]: \(p.message, privacy: .public)")
            }
        }
    }

    private func consumeLogs(_ stream: AsyncStream<String>) async {
        for await line in stream {
            await MainActor.run {
                self.logTail.append(line)
                if self.logTail.count > 500 {
                    self.logTail.removeFirst(self.logTail.count - 500)
                }
                self.logStore.append(source: .buildkitd, level: Self.level(for: line), line)
                Self.log.notice("\(line, privacy: .public)")
            }
        }
    }

    private func run(_ label: String, _ op: @escaping () async throws -> Void) async {
        do {
            try await op()
            self.state = await supervisor.currentState()
            self.lastError = nil
        } catch {
            let msg = String(describing: error)
            self.lastError = msg
            self.logStore.append(source: .supervisor, level: .error, "\(label) failed: \(msg)")
            Self.log.error("\(label, privacy: .public) failed: \(msg, privacy: .public)")
        }
    }

    private static func level(for line: String) -> LogLevel? {
        if line.contains("level=error") || line.localizedCaseInsensitiveContains("panic") || line.localizedCaseInsensitiveContains("fatal") {
            return .error
        }
        if line.contains("level=warning") || line.localizedCaseInsensitiveContains("warning") {
            return .warning
        }
        if line.contains("level=debug") { return .debug }
        if line.contains("level=info") { return .info }
        return nil
    }
}
