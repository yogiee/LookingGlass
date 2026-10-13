import Foundation
import Darwin
import IOKit

/// One model currently resident in Ollama (from /api/ps), with its VRAM/RAM footprint.
struct OllamaModelUsage: Identifiable {
    let name: String
    let vramGB: Double
    var id: String { name }
}

/// A model Looking Glass runs itself, outside Ollama: on Core AI (the image model, the LIGHT voice) or on MLX
/// in the sidecar (Alice's cloned voice).
struct LocalModelUsage: Identifiable {
    let name: String
    let engine: String       // "Core AI" | "MLX"
    let gb: Double
    var id: String { name }
}

@MainActor
class SystemMonitor: ObservableObject {
    @Published var cpuPercent: Double = 0
    @Published var gpuPercent: Double? = nil
    @Published var ramUsedGB: Double = 0
    @Published var ramTotalGB: Double = 0
    @Published var ollamaStatus: String = "—"
    @Published var ollamaModel: String? = nil
    @Published var ollamaVRAMGB: Double = 0          // total across all running models
    @Published var ollamaModels: [OllamaModelUsage] = []  // per-model breakdown
    @Published var localModels: [LocalModelUsage] = []
    /// Neural Engine memory traffic, bytes/s; nil where it can't be read (see `NeuralEngineMonitor`).
    @Published var aneBytesPerSec: Double? = nil
    @Published var lastTokensPerSec: Double = 0
    @Published var cpuSubtitle: String = ""
    @Published var gpuSubtitle: String = ""

    private var timer: Timer?
    private let client = SidecarClient()
    private let voiceClient = NeuralVoiceClient()
    private let neuralEngine = NeuralEngineMonitor()
    var ollamaHost: String? = nil

    /// Whether this Mac's Neural Engine traffic can be read at all; the panel hides the card when not.
    var isNeuralEngineReadable: Bool { neuralEngine != nil }
    var localModelsGB: Double { localModels.reduce(0) { $0 + $1.gb } }

    private struct OllamaPsResponse: Decodable {
        struct Model: Decodable {
            let name: String
            let size_vram: Int64?
        }
        let models: [Model]
    }

    // CPU tick bookkeeping for delta computation
    private var prevCPUInfo: processor_info_array_t?
    private var prevNumCPUInfo: mach_msg_type_number_t = 0

    func start() {
        ramTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        Task { await fetchStaticHardwareInfo() }
    }

    private func fetchStaticHardwareInfo() async {
        // CPU — all via sysctl, fast
        if let name = sysctlString("machdep.cpu.brand_string") {
            let cores = sysctlInt32("hw.physicalcpu")
            let freqHz = sysctlInt64("hw.perflevel0.maxfreq")
            var str = "\(name) (\(cores) cores)"
            if freqHz > 0 { str += String(format: " @ %.2f GHz", Double(freqHz) / 1e9) }
            cpuSubtitle = str
        }

        // GPU — system_profiler reads IOKit cache, run off main thread once
        let (gpuName, gpuCores) = await withCheckedContinuation {
            (cont: CheckedContinuation<(String, Int), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
                proc.arguments = ["SPDisplaysDataType", "-json"]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = Pipe()
                guard (try? proc.run()) != nil else { cont.resume(returning: ("", 0)); return }
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let displays = json["SPDisplaysDataType"] as? [[String: Any]],
                   let first = displays.first {
                    let name  = first["sppci_model"] as? String ?? ""
                    let cores = Int(first["sppci_cores"] as? String ?? "0") ?? 0
                    cont.resume(returning: (name, cores))
                } else {
                    cont.resume(returning: ("", 0))
                }
            }
        }
        var gpuStr = gpuName.isEmpty ? "GPU" : gpuName
        if gpuCores > 0 { gpuStr += " (\(gpuCores) cores)" }
        gpuSubtitle = gpuStr
    }

    private func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private func sysctlInt32(_ name: String) -> Int32 {
        var v: Int32 = 0; var s = MemoryLayout<Int32>.size
        sysctlbyname(name, &v, &s, nil, 0); return v
    }

    private func sysctlInt64(_ name: String) -> Int64 {
        var v: Int64 = 0; var s = MemoryLayout<Int64>.size
        sysctlbyname(name, &v, &s, nil, 0); return v
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
        aneBytesPerSec = neuralEngine?.bytesPerSecond()
        Task {
            let healthy = await client.health(ollamaHost: ollamaHost)
            ollamaStatus = healthy ? "Running" : "Offline"
            await fetchLocalModels(sidecarUp: healthy)
            if healthy {
                await fetchOllamaPs()
            } else {
                ollamaModel = nil
                ollamaVRAMGB = 0
                ollamaModels = []
            }
        }
    }

    private func fetchOllamaPs() async {
        let host = ollamaHost ?? "http://localhost:11434"
        guard let url = URL(string: "\(host)/api/ps") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(OllamaPsResponse.self, from: data)
            let models = decoded.models.map {
                OllamaModelUsage(name: $0.name, vramGB: Double($0.size_vram ?? 0) / 1_073_741_824)
            }
            ollamaModels = models
            ollamaModel = models.first?.name
            ollamaVRAMGB = models.reduce(0) { $0 + $1.vramGB }   // total across all
        } catch {
            ollamaModel = nil
            ollamaVRAMGB = 0
            ollamaModels = []
        }
    }

    // MARK: Core AI + MLX — the models Looking Glass loads itself

    private func fetchLocalModels(sidecarUp: Bool) async {
        var models: [LocalModelUsage] = []
        // The image model lives only while the lg-imagegen helper runs, so its real footprint is the helper's.
        if let bytes = Self.footprint(ofProcessNamed: "lg-imagegen"), bytes > 0 {
            models.append(LocalModelUsage(name: "FLUX.2 [klein] · image", engine: "Core AI", gb: Double(bytes) / 1e9))
        }
        let voice = sidecarUp ? await voiceClient.status() : nil
        if SpeechOutputService.shared.isLightVoiceLoaded {
            models.append(LocalModelUsage(name: "Kokoro · LIGHT voice", engine: "Core AI",
                                          gb: voice?.tiers["light"]?.residentGB ?? 0.83))
        }
        if let voice, let tier = voice.loadedTier, voice.residentGB > 0 {
            let label = voice.tiers[tier]?.label ?? tier
            models.append(LocalModelUsage(name: "Qwen3-TTS · \(label) voice", engine: "MLX", gb: voice.residentGB))
        }
        localModels = models
    }

    /// Physical footprint of the first process with this name (what Activity Monitor calls Memory, GPU
    /// allocations included on Apple Silicon), or nil if none is running.
    private static func footprint(ofProcessNamed target: String) -> UInt64? {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return nil }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        // proc_name returns nothing into a MAXCOMLEN+1 buffer; it wants room for the 2×MAXCOMLEN BSD name.
        var name = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            guard proc_name(pid, &name, UInt32(name.count)) > 0, String(cString: name) == target else { continue }
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            return ok == 0 ? info.ri_phys_footprint : nil
        }
        return nil
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
