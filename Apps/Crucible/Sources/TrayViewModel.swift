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
    @Published private(set) var progressMessage: String?
    @Published private(set) var logTail: [String] = []
    @Published private(set) var buildxStatus: BuildxIntegration.BuilderStatus = .unknown
    @Published private(set) var storageUsage: StorageUsage?
    @Published private(set) var appliedSettings: BuildKitSettings
    @Published var launchAtLoginEnabled: Bool
    @Published var settingsDraft: BuildKitSettings
    @Published private(set) var prerequisiteChecks: [PrerequisiteCheck] = []
    @Published private(set) var activeBuilds: [ActiveBuild] = []
    @Published private(set) var activeBuildsStatus: String = "Not checked"

    let logStore = LogStore()

    private static let log = Logger(subsystem: "com.cpuguy83.Crucible", category: "tray")

    private let supervisor: BuildKitSupervisor
    private let buildx = BuildxIntegration()
    private var subscriberTask: Task<Void, Never>?
    private var subscribedToBackend = false
    private var logWindowController: LogWindowController?
    private var settingsWindowController: SettingsWindowController?

    init() {
        let settings = AppSettingsStore.load()
        self.appliedSettings = settings
        self.settingsDraft = settings
        self.launchAtLoginEnabled = LoginItemManager.isEnabled
        self.supervisor = BuildKitSupervisor(settings: settings) { s in
            switch s.backend {
            case .containerization:
                return ContainerizationBackend(settings: s)
            case .containerCLI:
                return ContainerCLIBackend(settings: s)
            }
        }

        refreshStorageUsage()
        if settings.autoStart {
            Task { await self.start() }
        }
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
        case .running, .degraded:
            return true
        case .stopped, .starting, .stopping, .error:
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

    var canPullImage: Bool {
        !settingsDirty && !settingsApplyBlocked && BuildKitSettingsValidator.validate(appliedSettings).isEmpty
    }

    var canFactoryReset: Bool {
        switch state {
        case .starting, .stopping:
            return false
        case .stopped, .running, .degraded, .error:
            return true
        }
    }

    var canResetConfiguration: Bool { canFactoryReset }
    var canResetLocalState: Bool { canFactoryReset }

    var daemonConfigPath: String { StorageUsage.daemonConfigURL().path }

    var effectiveDaemonConfig: String { appliedSettings.effectiveDaemonConfigTOML() }

    var configuredWorkerPlatforms: String { "linux/arm64, linux/amd64" }

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
            let msg = buildKitUserMessage(for: error)
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

    func pullImage() {
        Task {
            await self.subscribeBackendStreamsIfNeeded()
            do {
                try await self.supervisor.pullImage()
                self.state = await supervisor.currentState()
                self.lastError = nil
                self.refreshStorageUsage()
                self.logStore.append(source: .supervisor, level: .info, "Pulled \(self.appliedSettings.imageReference)")
            } catch {
                let msg = buildKitUserMessage(for: error)
                self.lastError = msg
                self.logStore.append(source: .supervisor, level: .error, "pull image failed: \(msg)")
                Self.log.error("pull image failed: \(msg, privacy: .public)")
            }
        }
    }

    /// Stop, wipe persistent buildkitd state (cache, metadata), then leave
    /// the daemon stopped so the user can decide when to restart. Use
    /// when bbolt corruption ("structure needs cleaning") prevents
    /// startup.
    func resetState() {
        guard confirm(
            title: "Reset BuildKit state?",
            message: "This stops BuildKit and deletes the persistent cache/metadata image. All cached build layers will be lost.",
            confirmTitle: "Reset State"
        ) else { return }
        Task { await run("resetState") { try await self.supervisor.resetState() } }
    }

    func resetConfiguration() {
        guard confirm(
            title: "Reset configuration to defaults?",
            message: "This resets Crucible settings to current defaults. BuildKit state, pulled images, and kernel cache are kept.",
            confirmTitle: "Reset Configuration"
        ) else { return }

        Task {
            do {
                let defaults = BuildKitSettings()
                let shouldRestart = self.isRunning
                try await self.supervisor.updateSettings(defaults)
                try AppSettingsStore.delete()
                try? LoginItemManager.setEnabled(false)
                self.appliedSettings = defaults
                self.settingsDraft = defaults
                self.launchAtLoginEnabled = LoginItemManager.isEnabled
                self.subscribedToBackend = false
                self.subscriberTask?.cancel()
                self.subscriberTask = nil
                self.state = await supervisor.currentState()
                self.lastError = nil
                self.logStore.append(source: .supervisor, level: .info, "Configuration reset to defaults")
                if shouldRestart || defaults.autoStart {
                    await self.start()
                }
            } catch {
                self.reportResetFailure("reset configuration", error)
            }
        }
    }

    func resetLocalState() {
        guard confirm(
            title: "Reset local state?",
            message: "This stops BuildKit and deletes local runtime data, including BuildKit state, pulled images, kernels, and rootfs workspaces. Configuration is kept.",
            confirmTitle: "Reset Local State"
        ) else { return }

        Task {
            do {
                try await self.supervisor.stop()
                let settings = self.appliedSettings
                try AppSettingsStore.save(settings)
                try self.removeAppSupportDataPreservingSettings()
                try AppSettingsStore.save(settings)
                try await self.supervisor.updateSettings(settings)
                self.finishReset(settings: settings, message: "Local state reset")
            } catch {
                self.reportResetFailure("reset local state", error)
            }
        }
    }

    func factoryReset() {
        guard confirm(
            title: "Factory reset Crucible?",
            message: "This stops BuildKit, removes Crucible settings, deletes local images, kernels, rootfs workspaces, and BuildKit state. All cached build layers and custom settings will be lost.",
            confirmTitle: "Factory Reset"
        ) else { return }

        Task {
            do {
                try await self.supervisor.stop()
                try? LoginItemManager.setEnabled(false)
                try AppSettingsStore.delete()
                let root = StorageUsage.appSupportDirectory()
                if FileManager.default.fileExists(atPath: root.path) {
                    try FileManager.default.removeItem(at: root)
                }

                let defaults = BuildKitSettings()
                try await self.supervisor.updateSettings(defaults)
                self.launchAtLoginEnabled = LoginItemManager.isEnabled
                self.finishReset(settings: defaults, message: "Factory reset complete")
            } catch {
                self.reportResetFailure("factory reset", error)
            }
        }
    }

    private func removeAppSupportDataPreservingSettings() throws {
        let root = StorageUsage.appSupportDirectory()
        let settingsURL = AppSettingsStore.settingsURL.standardizedFileURL
        guard let contents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for url in contents where url.standardizedFileURL != settingsURL {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func finishReset(settings: BuildKitSettings, message: String) {
        appliedSettings = settings
        settingsDraft = settings
        subscribedToBackend = false
        subscriberTask?.cancel()
        subscriberTask = nil
        Task {
            self.state = await supervisor.currentState()
            self.lastError = nil
            self.refreshStorageUsage()
            self.logStore.append(source: .supervisor, level: .info, message)
        }
    }

    private func reportResetFailure(_ operation: String, _ error: Error) {
        let msg = buildKitUserMessage(for: error)
        lastError = msg
        logStore.append(source: .supervisor, level: .error, "\(operation) failed: \(msg)")
        Self.log.error("\(operation) failed: \(msg, privacy: .public)")
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

    func copyDiagnosticsSummary() {
        let recentLogs = logStore.events.suffix(80).map(\.rawLine).joined(separator: "\n")
        let summary = """
        Crucible diagnostics
        State: \(String(describing: state))
        Buildx: \(buildxStatus.displayText)
        Endpoint: \(endpoint?.url ?? "none")
        Storage: \(storageUsage?.displayText ?? "not created")
        Active builds: \(activeBuildsStatus)
        Backend: \(appliedSettings.backend.rawValue)
        BuildKit image: \(appliedSettings.imageReference)
        Worker platforms: \(configuredWorkerPlatforms)
        Rosetta: enabled automatically when available
        Effective daemon config path: \(daemonConfigPath)
        Last error: \(lastError ?? "none")

        Effective daemon config:
        \(effectiveDaemonConfig)

        Recent logs:
        \(recentLogs)
        """
        copyToPasteboard(summary)
        logStore.append(source: .supervisor, level: .info, "Copied diagnostics summary")
    }

    func openLogsWindow() {
        if logWindowController == nil {
            logWindowController = LogWindowController(store: logStore) { [weak self] in
                self?.logWindowController = nil
            }
        }
        logWindowController?.show()
    }

    func openSettingsWindow() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(viewModel: self) { [weak self] in
                self?.settingsWindowController = nil
            }
        }
        settingsWindowController?.show()
    }

    var settingsDirty: Bool { settingsDraft != appliedSettings }

    var settingsValidationMessages: [String] {
        var messages = BuildKitSettingsValidator.validate(settingsDraft).map(validationMessage(for:))
        if let path = settingsDraft.kernelOverridePath, !path.isEmpty {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            if !exists {
                messages.append("Kernel override path does not exist.")
            } else if isDirectory.boolValue {
                messages.append("Kernel override path must point to a file, not a directory.")
            } else if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let size = attrs[.size] as? NSNumber,
                      size.int64Value == 0
            {
                messages.append("Kernel override file is empty.")
            }
        }
        return messages
    }

    var canSaveSettings: Bool {
        settingsDirty && settingsValidationMessages.isEmpty && !settingsApplyBlocked
    }

    var settingsApplyBlocked: Bool {
        switch state {
        case .starting, .stopping:
            return true
        case .stopped, .running, .degraded, .error:
            return false
        }
    }

    func saveSettings() {
        let newSettings = settingsDraft
        Task {
            do {
                let shouldRestart = self.isRunning
                try await self.supervisor.updateSettings(newSettings)
                try AppSettingsStore.save(newSettings)
                self.appliedSettings = newSettings
                self.subscribedToBackend = false
                self.subscriberTask?.cancel()
                self.subscriberTask = nil
                self.state = await supervisor.currentState()
                let notice = shouldRestart ? "Applied settings; restarting BuildKit" : "Applied settings"
                self.lastError = nil
                self.logStore.append(source: .supervisor, level: .info, notice)
                if shouldRestart || newSettings.autoStart {
                    await self.start()
                }
            } catch {
                let msg = buildKitUserMessage(for: error)
                self.lastError = msg
                self.logStore.append(source: .supervisor, level: .error, "settings save failed: \(msg)")
            }
        }
    }

    func revertSettingsDraft() {
        settingsDraft = appliedSettings
    }

    func chooseKernelOverride() {
        let panel = NSOpenPanel()
        panel.title = "Choose Linux Kernel"
        panel.message = "Choose a vmlinux/Image file to boot BuildKit with. Leave unset to use Crucible's default kernel source."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settingsDraft.kernelOverridePath = url.path
    }

    func useDefaultKernel() {
        settingsDraft.kernelOverridePath = nil
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItemManager.setEnabled(enabled)
            launchAtLoginEnabled = LoginItemManager.isEnabled
            lastError = nil
        } catch {
            launchAtLoginEnabled = LoginItemManager.isEnabled
            lastError = "Failed to update launch at login: \(buildKitUserMessage(for: error))"
            logStore.append(source: .supervisor, level: .error, lastError ?? "")
        }
    }

    func runPrerequisiteChecks() {
        Task { [buildx] in
            let docker = await buildx.locateDocker()
            var checks: [PrerequisiteCheck] = [
                PrerequisiteCheck(
                    name: "Docker CLI",
                    status: docker == nil ? .warning : .ok,
                    detail: docker ?? "Not found. BuildKit can run, but buildx convenience actions need Docker CLI."
                )
            ]

            let containerPath = ContainerCLICommands.defaultBinaryPath()
            checks.append(PrerequisiteCheck(
                name: "Apple container CLI",
                status: FileManager.default.isExecutableFile(atPath: containerPath) ? .ok : .warning,
                detail: FileManager.default.isExecutableFile(atPath: containerPath) ? containerPath : "Not found. Required only when the CLI backend is selected."
            ))

            do {
                let kernel = try KernelLocator.locate(settings: self.settingsDraft)
                checks.append(PrerequisiteCheck(
                    name: "Linux kernel",
                    status: .ok,
                    detail: kernel.path
                ))
            } catch {
                checks.append(PrerequisiteCheck(
                    name: "Linux kernel",
                    status: .warning,
                    detail: "No local kernel yet. Crucible will download the default kernel on start."
                ))
            }

            checks.append(PrerequisiteCheck(
                name: "Host socket path",
                status: self.settingsDraft.hostSocketPath.hasPrefix("/") ? .ok : .failed,
                detail: self.settingsDraft.hostSocketPath
            ))

            await MainActor.run {
                self.prerequisiteChecks = checks
                self.logStore.append(source: .supervisor, level: .info, "Prerequisite check complete")
            }
        }
    }

    func refreshActiveBuilds() {
        guard let endpoint else {
            activeBuilds = []
            activeBuildsStatus = "BuildKit is not running"
            return
        }

        activeBuildsStatus = "Checking…"
        Task {
            do {
                let builds = try await BuildHistoryClient(socketPath: endpoint.socketPath).activeBuilds()
                await MainActor.run {
                    self.activeBuilds = builds
                    self.activeBuildsStatus = builds.isEmpty ? "No active builds" : "\(builds.count) active"
                    self.logStore.append(source: .supervisor, level: .info, "active builds: \(self.activeBuildsStatus)")
                }
            } catch {
                let msg = buildKitUserMessage(for: error)
                await MainActor.run {
                    self.activeBuilds = []
                    self.activeBuildsStatus = "Unavailable: \(msg)"
                    self.logStore.append(source: .supervisor, level: .warning, "active builds unavailable: \(msg)")
                }
            }
        }
    }

    func loadExampleDaemonConfig() {
        settingsDraft.daemonConfigTOML = BuildKitSettings.exampleDaemonConfigTOML
    }

    func openDaemonConfigInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([StorageUsage.daemonConfigURL()])
    }

    private func validationMessage(for issue: BuildKitSettingsValidator.Issue) -> String {
        switch issue {
        case .imageReferenceEmpty:
            return "BuildKit image reference is required."
        case .imageReferenceMalformed(let ref):
            return "BuildKit image reference looks invalid: \(ref)."
        case .socketPathEmpty:
            return "Host socket path is required."
        case .socketPathNotAbsolute(let path):
            return "Host socket path must be absolute: \(path)."
        case .cpuCountOutOfRange(let value):
            return "CPU count must be between 1 and 64 (currently \(value))."
        case .memoryOutOfRange(let value):
            return "Memory must be between 512 MiB and 256 GiB (currently \(value) MiB)."
        case .backendUnavailable(let backend):
            switch backend {
            case .containerization:
                return "Apple Containerization framework backend is unavailable."
            case .containerCLI:
                return "Apple container CLI backend is unavailable."
            }
        case .daemonConfigTooLarge(let bytes):
            return "BuildKit daemon config must be 256 KiB or smaller (currently \(bytes) bytes)."
        case .daemonConfigMalformed(let detail):
            return "BuildKit daemon config looks invalid: \(detail)."
        }
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
        logStore.append(source: .buildx, level: .info, "Copied BUILDKIT_HOST env")
    }

    func copyBuildxCreateCommand() {
        guard let ep = endpoint else { return }
        copyToPasteboard(BuildxCommands.dockerBuildxCreateCommand(for: ep))
        logStore.append(source: .buildx, level: .info, "Copied docker buildx create command")
    }

    func addToBuildx() {
        guard let ep = endpoint else { return }
        Task { [buildx] in
            let result = await buildx.install(endpoint: ep)
            await MainActor.run {
                switch result {
                case .created(let name):
                    let msg = "Added '\(name)' to docker buildx"
                    self.lastError = nil
                    self.logStore.append(source: .buildx, level: .info, msg)
                case .alreadyExists(let name):
                    let msg = "'\(name)' already registered in buildx (set as default)"
                    self.lastError = nil
                    self.logStore.append(source: .buildx, level: .info, msg)
                case .dockerNotFound:
                    self.lastError = "docker not found. Install Docker Desktop, or copy the command and run it in a shell."
                    self.logStore.append(source: .buildx, level: .error, self.lastError ?? "")
                case .failed(let stderr, let code):
                    self.lastError = "docker buildx create failed (exit \(code)):\n\(stderr)"
                    self.logStore.append(source: .buildx, level: .error, self.lastError ?? "")
                case .useFailed(let stderr, let code):
                    self.lastError = "docker buildx use failed (exit \(code)):\n\(stderr)"
                    self.logStore.append(source: .buildx, level: .error, self.lastError ?? "")
                }
                Self.log.notice("addToBuildx -> \(String(describing: result), privacy: .public)")
            }
            self.refreshBuildxStatus()
        }
    }

    func refreshBuildxStatus() {
        Task { [buildx] in
            let status = await buildx.status()
            await MainActor.run {
                self.buildxStatus = status
                self.logStore.append(source: .buildx, level: .info, "buildx status: \(status.displayText)")
            }
        }
    }

    func recreateBuildxBuilder() {
        guard let ep = endpoint else { return }
        Task { [buildx] in
            let result = await buildx.recreate(endpoint: ep)
            await MainActor.run {
                switch result {
                case .created(let name):
                    let msg = "Recreated '\(name)' buildx builder"
                    self.lastError = nil
                    self.logStore.append(source: .buildx, level: .info, msg)
                case .alreadyExists(let name):
                    let msg = "'\(name)' already registered in buildx"
                    self.lastError = nil
                    self.logStore.append(source: .buildx, level: .info, msg)
                case .dockerNotFound:
                    self.lastError = "docker not found. Install Docker Desktop, or copy the command and run it in a shell."
                    self.logStore.append(source: .buildx, level: .error, self.lastError ?? "")
                case .failed(let stderr, let code):
                    self.lastError = "docker buildx recreate failed (exit \(code)):\n\(stderr)"
                    self.logStore.append(source: .buildx, level: .error, self.lastError ?? "")
                case .useFailed(let stderr, let code):
                    self.lastError = "docker buildx use failed (exit \(code)):\n\(stderr)"
                    self.logStore.append(source: .buildx, level: .error, self.lastError ?? "")
                }
            }
            self.refreshBuildxStatus()
        }
    }

    func removeBuildxBuilder() {
        Task { [buildx] in
            let result = await buildx.remove()
            await MainActor.run {
                switch result {
                case .removed(let name):
                    let msg = "Removed '\(name)' buildx builder"
                    self.lastError = nil
                    self.logStore.append(source: .buildx, level: .info, msg)
                case .notRegistered(let name):
                    let msg = "'\(name)' buildx builder is not registered"
                    self.lastError = nil
                    self.logStore.append(source: .buildx, level: .info, msg)
                case .dockerNotFound:
                    self.lastError = "docker not found."
                    self.logStore.append(source: .buildx, level: .error, self.lastError ?? "")
                case .failed(let stderr, let code):
                    self.lastError = "docker buildx rm failed (exit \(code)):\n\(stderr)"
                    self.logStore.append(source: .buildx, level: .error, self.lastError ?? "")
                }
            }
            self.refreshBuildxStatus()
        }
    }

    func pruneBuildKitCache() {
        guard confirm(
            title: "Prune BuildKit cache?",
            message: "This removes unused BuildKit cache records. The state image file may not shrink on disk, but space is reclaimed inside the image.",
            confirmTitle: "Prune Cache"
        ) else { return }

        Task { [buildx] in
            let result = await buildx.prune()
            await MainActor.run {
                switch result {
                case .pruned(let output):
                    let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    let msg = text.isEmpty ? "BuildKit cache pruned" : text
                    self.lastError = nil
                    self.logStore.append(source: .buildx, level: .info, msg)
                case .dockerNotFound:
                    self.lastError = "docker not found."
                    self.logStore.append(source: .buildx, level: .error, self.lastError ?? "")
                case .failed(let stderr, let code):
                    self.lastError = "docker buildx prune failed (exit \(code)):\n\(stderr)"
                    self.logStore.append(source: .buildx, level: .error, self.lastError ?? "")
                }
                self.refreshStorageUsage()
            }
        }
    }

    private func copyToPasteboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    private func confirm(title: String, message: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
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
            self.lastError = buildKitUserMessage(for: error)
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
            self.refreshStorageUsage()
        } catch {
            let msg = buildKitUserMessage(for: error)
            self.lastError = msg
            self.logStore.append(source: .supervisor, level: .error, "\(label) failed: \(msg)")
            Self.log.error("\(label, privacy: .public) failed: \(msg, privacy: .public)")
        }
    }

    func refreshStorageUsage() {
        storageUsage = StorageUsage.current()
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
