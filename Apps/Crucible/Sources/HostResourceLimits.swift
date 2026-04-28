import Foundation

struct HostResourceLimits: Sendable, Equatable {
    var cpuMax: Int
    var memorySliderMaxGiB: Int
    var physicalMemoryMiB: Int
    var reservedHostMemoryGiB: Int

    static func current() -> HostResourceLimits {
        let processInfo = ProcessInfo.processInfo
        let cpuMax = min(64, max(1, processInfo.processorCount))
        let physicalMemoryMiB = max(512, Int(processInfo.physicalMemory / 1_048_576))
        let physicalGiB = max(1, physicalMemoryMiB / 1024)

        // Leave roughly 4 GiB for macOS, but don't make small machines
        // unusable. The exact MiB field can still exceed this UI slider
        // cap up to validator limits if the user intentionally wants it.
        let reservedHostMemoryGiB = 4
        let recommendedMaxGiB = max(1, physicalGiB - reservedHostMemoryGiB)
        return HostResourceLimits(
            cpuMax: cpuMax,
            memorySliderMaxGiB: recommendedMaxGiB,
            physicalMemoryMiB: physicalMemoryMiB,
            reservedHostMemoryGiB: reservedHostMemoryGiB
        )
    }
}
