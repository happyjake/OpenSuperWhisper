import Foundation
import AppKit

// MARK: - Memory Constants

enum LLMMemoryConstants {
    /// Minimum free memory required before loading a model (2GB buffer)
    static let minimumFreeMemoryBytes: UInt64 = 2 * 1024 * 1024 * 1024

    /// Memory pressure threshold to trigger unload consideration (85%)
    static let pressureThresholdPercent: Double = 0.85

    /// Default estimated model size for memory checks (4GB)
    static let defaultEstimatedModelSize: UInt64 = 4 * 1024 * 1024 * 1024
}

// MARK: - LLM Memory Manager

/// Manages LLM model lifecycle based on app state and memory pressure
final class LLMMemoryManager {
    static let shared = LLMMemoryManager()

    private var workspaceObserver: NSObjectProtocol?
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// Whether to automatically unload models when app is backgrounded
    var autoUnloadOnBackground: Bool = true

    /// Callback when memory pressure requires model unload
    var onMemoryPressureUnload: (() async -> Void)?

    /// Callback when app is backgrounded
    var onAppBackgrounded: (() async -> Void)?

    private init() {
        setupWorkspaceObserver()
        setupMemoryPressureObserver()
    }

    deinit {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        memoryPressureSource?.cancel()
    }

    // MARK: - Workspace Observer (App Background State)

    private func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  self.autoUnloadOnBackground,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Bundle.main.bundleIdentifier else {
                return
            }

            // App moved to background - consider unloading model
            Task {
                await self.handleAppBackgrounded()
            }
        }
    }

    private func handleAppBackgrounded() async {
        guard autoUnloadOnBackground else { return }

        print("LLMMemoryManager: App backgrounded, notifying for potential model unload")
        await onAppBackgrounded?()
    }

    // MARK: - Memory Pressure Observer

    private func setupMemoryPressureObserver() {
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )

        memoryPressureSource?.setEventHandler { [weak self] in
            guard let self = self,
                  let source = self.memoryPressureSource else { return }

            let event = source.data
            if event.contains(.critical) {
                print("LLMMemoryManager: CRITICAL memory pressure - forcing model unload")
                Task {
                    await self.onMemoryPressureUnload?()
                }
            } else if event.contains(.warning) {
                print("LLMMemoryManager: Memory pressure WARNING - consider unloading")
                // Optionally unload on warning if model isn't actively being used
            }
        }

        memoryPressureSource?.resume()
    }

    // MARK: - Pre-Load Memory Check

    /// Check if sufficient memory is available before loading a model
    /// - Parameter estimatedModelSize: Estimated memory requirement for the model (bytes)
    /// - Returns: Whether loading should proceed
    func canLoadModel(estimatedModelSize: UInt64 = LLMMemoryConstants.defaultEstimatedModelSize) -> Bool {
        let freeMemory = getAvailableMemory()
        let requiredMemory = estimatedModelSize + LLMMemoryConstants.minimumFreeMemoryBytes

        if freeMemory < requiredMemory {
            let freeMB = freeMemory / 1024 / 1024
            let requiredMB = requiredMemory / 1024 / 1024
            print("LLMMemoryManager: Insufficient memory. Free: \(freeMB)MB, Required: \(requiredMB)MB")
            return false
        }

        return true
    }

    /// Get the amount of available memory in bytes
    func getAvailableMemory() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { statsPtr in
            statsPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { pointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, pointer, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            print("LLMMemoryManager: Failed to get memory statistics")
            return 0
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let freeMemory = UInt64(stats.free_count) * pageSize
        let inactiveMemory = UInt64(stats.inactive_count) * pageSize

        // Available = free + inactive (inactive can be reclaimed)
        return freeMemory + inactiveMemory
    }

    /// Get the total physical memory in bytes
    func getTotalMemory() -> UInt64 {
        return ProcessInfo.processInfo.physicalMemory
    }

    /// Get memory usage percentage
    func getMemoryUsagePercent() -> Double {
        let total = getTotalMemory()
        let available = getAvailableMemory()
        guard total > 0 else { return 0 }
        return Double(total - available) / Double(total)
    }

    /// Check if memory pressure is above threshold
    func isMemoryPressureHigh() -> Bool {
        return getMemoryUsagePercent() > LLMMemoryConstants.pressureThresholdPercent
    }

    // MARK: - Memory Info (For Debugging/UI)

    /// Get formatted memory information for display
    func getMemoryInfo() -> MemoryInfo {
        let total = getTotalMemory()
        let available = getAvailableMemory()
        let used = total - available

        return MemoryInfo(
            totalBytes: total,
            availableBytes: available,
            usedBytes: used,
            usagePercent: getMemoryUsagePercent()
        )
    }
}

// MARK: - Memory Info

/// Memory information for display
struct MemoryInfo {
    let totalBytes: UInt64
    let availableBytes: UInt64
    let usedBytes: UInt64
    let usagePercent: Double

    var totalGB: Double { Double(totalBytes) / 1024 / 1024 / 1024 }
    var availableGB: Double { Double(availableBytes) / 1024 / 1024 / 1024 }
    var usedGB: Double { Double(usedBytes) / 1024 / 1024 / 1024 }

    var formattedTotal: String { String(format: "%.1f GB", totalGB) }
    var formattedAvailable: String { String(format: "%.1f GB", availableGB) }
    var formattedUsed: String { String(format: "%.1f GB", usedGB) }
    var formattedUsagePercent: String { String(format: "%.0f%%", usagePercent * 100) }
}
