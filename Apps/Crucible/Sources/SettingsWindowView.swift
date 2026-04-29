import SwiftUI
import BuildKitCore

struct SettingsWindowView: View {
    @ObservedObject var viewModel: TrayViewModel
    @State private var selection: SettingsSection = .general
    private let hostLimits = HostResourceLimits.current()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                detail
                applyFooter
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Crucible")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.top, 18)

            Text(viewModel.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            ForEach(SettingsSection.allCases) { section in
                sidebarRow(section)
            }

            Spacer()
        }
        .frame(width: 210)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func sidebarRow(_ section: SettingsSection) -> some View {
        Button {
            selection = section
            if section == .buildx, viewModel.buildxStatus == .unknown {
                viewModel.refreshBuildxStatus()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .frame(width: 18)
                Text(section.title)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selection == section ? Color.accentColor.opacity(0.18) : .clear)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                switch selection {
                case .general:
                    generalView
                case .buildx:
                    buildxView
                case .storage:
                    storageView
                case .reset:
                    resetView
                case .diagnostics:
                    diagnosticsView
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selection.title)
                .font(.largeTitle.weight(.semibold))
            Text(selection.subtitle)
                .foregroundStyle(.secondary)
        }
    }

    private var generalView: some View {
        VStack(alignment: .leading, spacing: 16) {
            card("Daemon") {
                metricRow("Status", viewModel.statusText)
                metricRow("Endpoint", viewModel.endpoint?.url ?? "Not available")
                HStack {
                    Button("Start", action: viewModel.startFromMenu)
                        .disabled(!viewModel.canStart)
                    Button("Stop", action: viewModel.stop)
                        .disabled(!viewModel.canStop)
                    Button("Restart", action: viewModel.restart)
                        .disabled(!viewModel.canRestart)
                }
            }

            runtimeSettingsCard
            imageSettingsCard
            daemonConfigSettingsCard
            hostAccessSettingsCard
            resourceSettingsCard
            kernelSettingsCard
        }
    }

    private var runtimeSettingsCard: some View {
        card("Runtime") {
            settingLabel("How Crucible starts BuildKit", "The framework backend links Apple Containerization directly. The CLI backend is intended for users who explicitly want to drive Apple's `container` binary.")
            Picker("Backend", selection: $viewModel.settingsDraft.backend) {
                Text("Apple Containerization framework").tag(BuildKitSettings.BackendKind.containerization)
                Text("Apple container CLI")
                    .tag(BuildKitSettings.BackendKind.containerCLI)
            }
            .pickerStyle(.radioGroup)
            Text("The CLI backend shells out to Apple's `container` binary and is useful for comparing Crucible against the upstream command-line runtime.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Start BuildKit when Crucible launches", isOn: $viewModel.settingsDraft.autoStart)
            Toggle("Launch Crucible when you log in", isOn: launchAtLoginBinding)
            Text("Rosetta x86_64 emulation is enabled automatically when available. Crucible registers binfmt_misc in the VM and advertises linux/amd64 plus linux/arm64 to BuildKit unless your daemon config overrides worker platforms.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var imageSettingsCard: some View {
        card("Images") {
            settingLabel("BuildKit daemon image", "OCI image that contains buildkitd and buildctl. Use a tag while experimenting, or a digest for reproducible behavior.")
            TextField(BuildKitSettings.defaultImageReference, text: $viewModel.settingsDraft.imageReference)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Pull Applied Image", action: viewModel.pullImage)
                    .disabled(!viewModel.canPullImage)
                Text("Pulls `\(viewModel.appliedSettings.imageReference)` into Crucible's local content store.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            settingLabel("VM init image", "vminitd image used by Apple Containerization to initialize and manage the guest VM. Usually this should match the framework version.")
            TextField("ghcr.io/apple/containerization/vminit:0.31.0", text: $viewModel.settingsDraft.initfsReference)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var hostAccessSettingsCard: some View {
        card("Host Access") {
            settingLabel("BuildKit socket", "Unix socket path exposed on macOS. buildctl and docker buildx connect to this endpoint.")
            TextField("Host socket path", text: $viewModel.settingsDraft.hostSocketPath)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var daemonConfigSettingsCard: some View {
        card("Daemon Config") {
            settingLabel("buildkitd.toml", "Optional BuildKit daemon TOML configuration. Crucible writes this to app support, mounts it read-only at `/etc/buildkit/buildkitd.toml`, and starts buildkitd with `--config`. Leave empty to use the image defaults.")
            TextEditor(text: $viewModel.settingsDraft.daemonConfigTOML)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            HStack {
                Button("Load Example") {
                    viewModel.loadExampleDaemonConfig()
                }
                Button("Clear Config") {
                    viewModel.settingsDraft.daemonConfigTOML = ""
                }
                .disabled(viewModel.settingsDraft.daemonConfigTOML.isEmpty)
                Button("Copy Path") {
                    copy(viewModel.daemonConfigPath)
                }
                Button("Reveal File") {
                    viewModel.openDaemonConfigInFinder()
                }
                Text("Changes apply when settings are applied and BuildKit restarts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(viewModel.daemonConfigPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var resourceSettingsCard: some View {
        card("VM Resources") {
            settingLabel("CPU and memory", "Resources assigned to the Linux VM running BuildKit. Changes apply on the next restart.")
            resourceSlider(
                title: "CPU",
                valueText: "\(viewModel.settingsDraft.cpuCount) cores",
                rangeText: "1-\(hostLimits.cpuMax) cores available",
                value: cpuBinding,
                range: 1...Double(hostLimits.cpuMax),
                step: 1
            )
            memorySlider
            Text("Memory slider snaps to whole GiB values and tops out at physical memory minus \(hostLimits.reservedHostMemoryGiB) GiB reserved for macOS (\(StorageUsage.format(Int64(hostLimits.physicalMemoryMiB) * 1_048_576)) total detected). Use the MiB field for an exact value between GiB marks or a higher intentional value.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var kernelSettingsCard: some View {
        card("Kernel") {
            settingLabel("Linux kernel override", "Optional path to a custom Linux kernel image. Leave blank to use Crucible's default lookup/download flow.")
            HStack {
                TextField("Use default kernel", text: kernelOverrideBinding)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…", action: viewModel.chooseKernelOverride)
                Button("Use Default", action: viewModel.useDefaultKernel)
                    .disabled(viewModel.settingsDraft.kernelOverridePath == nil)
            }
        }
    }

    private var applyFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.settingsValidationMessages.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.settingsValidationMessages, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption)
            }

            HStack(spacing: 12) {
                if viewModel.settingsDirty {
                    Label("Unsaved changes", systemImage: "circle.fill")
                        .foregroundStyle(.orange)
                }

                Text("Saving recreates the backend; running BuildKit restarts automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if viewModel.settingsApplyBlocked {
                    Text("Wait for startup/shutdown to finish before applying settings.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Spacer()

                Button("Discard Changes", action: viewModel.revertSettingsDraft)
                    .disabled(!viewModel.settingsDirty)
                Button("Apply Changes", action: viewModel.saveSettings)
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(!viewModel.canSaveSettings)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var buildxView: some View {
        VStack(alignment: .leading, spacing: 16) {
            card("Builder") {
                metricRow("Status", viewModel.buildxStatus.displayText)
                Text("Register Crucible as a remote docker buildx builder named `crucible`, and optionally set it as the current builder.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                HStack {
                    Button("Add and Use", action: viewModel.addToBuildx)
                        .disabled(!viewModel.isRunning)
                    Button("Refresh", action: viewModel.refreshBuildxStatus)
                    Button("Recreate", action: viewModel.recreateBuildxBuilder)
                        .disabled(!viewModel.isRunning)
                    Button("Remove", action: viewModel.removeBuildxBuilder)
                }
            }

            card("Commands") {
                HStack {
                    Button("Copy buildx create command", action: viewModel.copyBuildxCreateCommand)
                        .disabled(viewModel.endpoint == nil)
                    Button("Copy BUILDKIT_HOST env", action: viewModel.copyBuildKitHostEnv)
                        .disabled(viewModel.endpoint == nil)
                }
            }
        }
    }

    private var storageView: some View {
        VStack(alignment: .leading, spacing: 16) {
            card("Overview") {
                metricRow("App Support", viewModel.storageUsage?.appSupportPath ?? StorageUsage.appSupportDirectory().path)
                metricRow("State Image", viewModel.storageUsage?.stateImagePath ?? "Not created")
                metricRow("Capacity", viewModel.storageUsage?.stateImageCapacityText ?? "Not created")
                metricRow("Allocated", viewModel.storageUsage?.stateImageAllocatedText ?? "Not created")
                Text("BuildKit's durable state is stored in a sparse ext4 image and mounted at `/var/lib/buildkit` inside the VM. Pruning frees space inside the image; the macOS file may remain allocated until recreated.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                HStack {
                    Button("Refresh Usage", action: viewModel.refreshStorageUsage)
                    Button("Prune Cache…", action: viewModel.pruneBuildKitCache)
                        .disabled(!viewModel.isRunning)
                    Button("Reset State…", action: viewModel.resetState)
                        .disabled(!viewModel.canResetState)
                }
            }

            card("Storage Areas") {
                if let areas = viewModel.storageUsage?.areas {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(areas) { area in
                            storageAreaRow(area)
                        }
                    }
                } else {
                    Text("No storage information available yet.")
                        .foregroundStyle(.secondary)
                }
            }

        }
    }

    private var resetView: some View {
        VStack(alignment: .leading, spacing: 16) {
            card("Reset Options") {
                Text("Choose the smallest reset that matches the problem. Configuration reset keeps downloaded data; local state reset keeps configuration; factory reset removes both.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    resetActionRow(
                        title: "Reset Configuration…",
                        detail: "Restore settings to current defaults without deleting BuildKit state, pulled images, or kernel cache.",
                        action: viewModel.resetConfiguration,
                        disabled: !viewModel.canResetConfiguration
                    )
                    resetActionRow(
                        title: "Reset Local State…",
                        detail: "Stop BuildKit and delete local state, pulled images, kernels, and rootfs workspaces while preserving configuration.",
                        action: viewModel.resetLocalState,
                        disabled: !viewModel.canResetLocalState
                    )
                    resetActionRow(
                        title: "Factory Reset…",
                        detail: "Remove all Crucible settings and local data.",
                        action: viewModel.factoryReset,
                        disabled: !viewModel.canFactoryReset
                    )
                }

                if !viewModel.canFactoryReset {
                    Text("Wait for startup/shutdown to finish before resetting.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var diagnosticsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            card("Current State") {
                metricRow("Daemon", viewModel.statusText)
                metricRow("Buildx", viewModel.buildxStatus.displayText)
                metricRow("Active Builds", viewModel.activeBuildsStatusText)
                metricRow("Endpoint", viewModel.endpoint?.url ?? "none")
                metricRow("Backend", viewModel.appliedSettings.backend.rawValue)
                metricRow("Image", viewModel.appliedSettings.imageReference)
                metricRow("Platforms", viewModel.configuredWorkerPlatforms)
                metricRow("Rosetta", "enabled automatically when available")
                metricRow("Last Error", viewModel.lastError ?? "none")
            }

            card("Active Builds") {
                HStack {
                    Button("Refresh Active Builds", action: viewModel.refreshActiveBuilds)
                        .disabled(viewModel.endpoint == nil)
                    Text(viewModel.activeBuildsStatusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if viewModel.activeBuilds.isEmpty {
                    Text("No active build history records are currently visible.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.activeBuilds, id: \.ref) { build in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(build.target.map { "\(build.frontend) / \($0)" } ?? build.frontend)
                                    .font(.callout.weight(.medium))
                                Text(build.ref)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Text("\(build.completedSteps)/\(build.totalSteps) steps, \(build.cachedSteps) cached, \(build.warnings) warnings")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            card("Effective Daemon Config") {
                Text("This is the generated config mounted into buildkitd. Crucible injects worker platforms for Rosetta unless your custom config sets `[worker.oci].platforms` explicitly.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(viewModel.daemonConfigPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                ScrollView {
                    Text(viewModel.effectiveDaemonConfig)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(minHeight: 120, maxHeight: 220)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                HStack {
                    Button("Copy Effective Config") {
                        copy(viewModel.effectiveDaemonConfig)
                    }
                    Button("Copy Config Path") {
                        copy(viewModel.daemonConfigPath)
                    }
                }
            }

            card("Logs & Reports") {
                HStack {
                    Button("Open Logs…", action: viewModel.openLogsWindow)
                    Button("Copy Diagnostics Summary", action: viewModel.copyDiagnosticsSummary)
                    Button("Copy Last Logs", action: viewModel.copyLogsToPasteboard)
                        .disabled(viewModel.logTail.isEmpty)
                }
            }

            card("Prerequisites") {
                Button("Run Checks", action: viewModel.runPrerequisiteChecks)
                if viewModel.prerequisiteChecks.isEmpty {
                    Text("Run checks to validate Docker CLI discovery, kernel availability, and socket path configuration.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.prerequisiteChecks, id: \.name) { check in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: check.status.symbol)
                                    .foregroundStyle(color(for: check.status))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(check.name)
                                        .font(.callout.weight(.medium))
                                    Text(check.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: 620, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        )
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }

    private func settingLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.callout.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func resourceSlider(
        title: String,
        valueText: String,
        rangeText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.callout.weight(.medium))
                Spacer()
                Text(valueText)
                    .font(.callout.monospacedDigit())
                Text(rangeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private var memorySlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Memory")
                    .font(.callout.weight(.medium))
                Spacer()
                Text("\(memoryGiBText) GiB")
                    .font(.callout.monospacedDigit())
                Text("1-\(hostLimits.memorySliderMaxGiB) GiB suggested")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Slider(value: memoryGiBBinding, in: 1...Double(hostLimits.memorySliderMaxGiB), step: 1)
            memoryTickMarks
            HStack {
                Text("Exact")
                    .foregroundStyle(.secondary)
                TextField("MiB", value: $viewModel.settingsDraft.memoryMiB, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
                Text("MiB")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    private var memoryTickMarks: some View {
        HStack(spacing: 0) {
            ForEach(1...hostLimits.memorySliderMaxGiB, id: \.self) { gb in
                Rectangle()
                    .fill(gb % 8 == 0 ? Color.primary.opacity(0.36) : Color.primary.opacity(0.16))
                    .frame(width: 1, height: gb % 8 == 0 ? 10 : 5)
                if gb < hostLimits.memorySliderMaxGiB { Spacer(minLength: 0) }
            }
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 0) {
                Text("1")
                Spacer()
                Text("\(max(1, hostLimits.memorySliderMaxGiB / 2))")
                Spacer()
                Text("\(hostLimits.memorySliderMaxGiB)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .offset(y: 14)
        }
        .padding(.bottom, 14)
    }

    private func storageAreaRow(_ area: StorageUsage.Area) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(area.name)
                    .font(.callout.weight(.medium))
                Spacer()
                Text(area.sizeText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(area.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
            Text(area.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func resetActionRow(title: String, detail: String, action: @escaping () -> Void, disabled: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title.replacingOccurrences(of: "…", with: ""))
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(title, action: action)
                .disabled(disabled)
        }
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func color(for status: PrerequisiteCheck.Status) -> Color {
        switch status {
        case .ok: .green
        case .warning: .orange
        case .failed: .red
        }
    }

    private var kernelOverrideBinding: Binding<String> {
        Binding {
            viewModel.settingsDraft.kernelOverridePath ?? ""
        } set: { newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            viewModel.settingsDraft.kernelOverridePath = trimmed.isEmpty ? nil : trimmed
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding {
            viewModel.launchAtLoginEnabled
        } set: { enabled in
            viewModel.setLaunchAtLogin(enabled)
        }
    }

    private var cpuBinding: Binding<Double> {
        Binding {
            Double(viewModel.settingsDraft.cpuCount)
        } set: { newValue in
            viewModel.settingsDraft.cpuCount = min(hostLimits.cpuMax, max(1, Int(newValue.rounded())))
        }
    }

    private var memoryGiBBinding: Binding<Double> {
        Binding {
            min(Double(hostLimits.memorySliderMaxGiB), max(1, Double(viewModel.settingsDraft.memoryMiB) / 1024.0))
        } set: { newValue in
            viewModel.settingsDraft.memoryMiB = Int(newValue.rounded()) * 1024
        }
    }

    private var memoryGiBText: String {
        let gb = Double(viewModel.settingsDraft.memoryMiB) / 1024.0
        return gb == floor(gb) ? "\(Int(gb))" : String(format: "%.1f", gb)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case buildx
    case storage
    case reset
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .buildx: "Buildx"
        case .storage: "Storage"
        case .reset: "Reset"
        case .diagnostics: "Diagnostics"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Control the BuildKit daemon and copy its endpoint."
        case .buildx: "Manage docker buildx integration."
        case .storage: "Manage cache, metadata, and persistent state."
        case .reset: "Reset configuration or local data."
        case .diagnostics: "Inspect current state and collect troubleshooting details."
        }
    }

    var symbol: String {
        switch self {
        case .general: "switch.2"
        case .buildx: "hammer"
        case .storage: "internaldrive"
        case .reset: "arrow.counterclockwise"
        case .diagnostics: "stethoscope"
        }
    }
}
