import Foundation
import Darwin
import IOKit

@MainActor
class SystemMonitor: ObservableObject {
    @Published var cpuPercent: Double = 0
    @Published var gpuPercent: Double? = nil
    @Published var ramUsedGB: Double = 0
    @Published var ramTotalGB: Double = 0
    @Published var ollamaStatus: String = "—"
    @Published var lastTokensPerSec: Double = 0

    private var timer: Timer?
    private let client = SidecarClient()
    var ollamaHost: String? = nil

    // CPU tick bookkeeping for delta computation
    private var prevCPUInfo: processor_info_array_t?
    private var prevNumCPUInfo: mach_msg_type_number_t = 0

    func start() {
        ramTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let prev = prevCPUInfo {
            let sz = vm_size_t(prevNumCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prev), sz)
            prevCPUInfo = nil
        }
    }

    func recordTokensPerSec(_ tps: Double) { lastTokensPerSec = tps }

    private func refresh() {
        cpuPercent = sampledCPU()
        gpuPercent = ioKitGPU()
        ramUsedGB  = usedRAMGB()
        Task {
            let healthy = await client.health(ollamaHost: ollamaHost)
            ollamaStatus = healthy ? "Running" : "Offline"
        }
    }

    // MARK: CPU — delta between consecutive host_processor_info samples

    private func sampledCPU() -> Double {
        var numCPUs: natural_t = 0
        var info: processor_info_array_t?
        var numInfo: mach_msg_type_number_t = 0

        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                   &numCPUs, &info, &numInfo) == KERN_SUCCESS,
              let cur = info else { return cpuPercent }

        defer {
            // Free previous sample
            if let prev = prevCPUInfo {
                let sz = vm_size_t(prevNumCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size)
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prev), sz)
            }
            prevCPUInfo = cur
            prevNumCPUInfo = numInfo
        }

        guard let prev = prevCPUInfo else { return 0 }

        var totalTicks = 0
        var idleTicks  = 0
        for i in 0..<Int(numCPUs) {
            let base = Int(CPU_STATE_MAX) * i
            let user   = Int(cur[base + Int(CPU_STATE_USER)])   - Int(prev[base + Int(CPU_STATE_USER)])
            let sys    = Int(cur[base + Int(CPU_STATE_SYSTEM)]) - Int(prev[base + Int(CPU_STATE_SYSTEM)])
            let nice   = Int(cur[base + Int(CPU_STATE_NICE)])   - Int(prev[base + Int(CPU_STATE_NICE)])
            let idle   = Int(cur[base + Int(CPU_STATE_IDLE)])   - Int(prev[base + Int(CPU_STATE_IDLE)])
            totalTicks += user + sys + nice + idle
            idleTicks  += idle
        }
        guard totalTicks > 0 else { return 0 }
        return Double(totalTicks - idleTicks) / Double(totalTicks) * 100.0
    }

    // MARK: GPU — IOAccelerator PerformanceStatistics

    private func ioKitGPU() -> Double? {
        let matching = IOServiceMatching("IOAccelerator")
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var entry = IOIteratorNext(iter)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iter) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let perf = dict["PerformanceStatistics"] as? [String: Any] else { continue }

            // Key varies by GPU vendor and macOS version — try both forms
            if let raw = perf["GPU Core Utilization"] as? Int {
                return Double(raw) / 10_000_000.0
            }
            if let raw = perf["Device Utilization %"] as? Int {
                return Double(raw)
            }
        }
        return nil
    }

    // MARK: RAM

    private func usedRAMGB() -> Double {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) +
                    UInt64(stats.compressor_page_count)) * page
        return Double(used) / 1_073_741_824
    }
}
