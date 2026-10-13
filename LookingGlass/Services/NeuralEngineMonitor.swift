import Foundation

/// How hard the Neural Engine is working, read from IOReport without root — the same source `macmon` uses.
///
/// macOS has no public ANE utilisation API, and on an M1 Max under macOS 27 IOReport's `Energy Model` ANE
/// channel always reads 0, as do the CPU channels. Two signals do work:
/// - `SoC Stats / Cluster Power States / ANE0` says whether the ANE is powered, but it stays ACT for ~5 s
///   after the last request, so it reads "busy" long after the work is done.
/// - `AMC Stats / Perf Counters / ANE0 RD|WR` is the ANE's memory traffic, which moves with the work. That is
///   what this reports, in bytes per second. Measured 2026-10-13: idle 0, a powered-but-idle ANE ~6 MB/s,
///   Vision OCR ~5 GB/s read + write, an Apple Intelligence reply peaks at ~16 GB/s read.
///
/// libIOReport is private API, loaded with `dlopen` so a missing symbol degrades to "unavailable" rather than
/// failing to launch. Fine for this app (not sandboxed, not on the App Store).
final class NeuralEngineMonitor {
    private typealias CopyChannels = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer?, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelName = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IntegerValue = @convention(c) (CFDictionary, Int32) -> Int64

    private let createSamples: CreateSamples
    private let createDelta: CreateDelta
    private let channelName: ChannelName
    private let integerValue: IntegerValue
    private let subscription: OpaquePointer
    private let channels: CFMutableDictionary

    private var previous: (sample: CFDictionary, at: Date)?

    /// nil when IOReport or the ANE traffic counters aren't there (another chip, a future OS).
    init?() {
        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW),
              let copy = dlsym(lib, "IOReportCopyChannelsInGroup"),
              let subscribe = dlsym(lib, "IOReportCreateSubscription"),
              let samples = dlsym(lib, "IOReportCreateSamples"),
              let delta = dlsym(lib, "IOReportCreateSamplesDelta"),
              let name = dlsym(lib, "IOReportChannelGetChannelName"),
              let value = dlsym(lib, "IOReportSimpleGetIntegerValue")
        else { return nil }
        createSamples = unsafeBitCast(samples, to: CreateSamples.self)
        createDelta = unsafeBitCast(delta, to: CreateDelta.self)
        channelName = unsafeBitCast(name, to: ChannelName.self)
        integerValue = unsafeBitCast(value, to: IntegerValue.self)

        guard let found = unsafeBitCast(copy, to: CopyChannels.self)("AMC Stats" as CFString, "Perf Counters" as CFString, 0, 0, 0)?
                .takeRetainedValue(),
              let list = (found as NSDictionary)["IOReportChannels"] as? [NSDictionary],
              list.contains(where: { Self.isANETraffic(unsafeBitCast(name, to: ChannelName.self)($0)?.takeUnretainedValue() as String?) })
        else { return nil }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let sub = unsafeBitCast(subscribe, to: CreateSubscription.self)(nil, found, &subscribed, 0, nil) else { return nil }
        subscribed?.release()
        subscription = sub
        channels = found
    }

    /// "ANE0 RD", "ANE1 WR"… — not the "ANE0 DCS RD" cache-side duplicates.
    private static func isANETraffic(_ name: String?) -> Bool {
        guard let name, name.hasPrefix("ANE"), !name.contains("DCS") else { return false }
        return name.hasSuffix(" RD") || name.hasSuffix(" WR")
    }

    /// ANE memory traffic since the last call, in bytes per second. The first call only primes the counter.
    func bytesPerSecond() -> Double? {
        guard let sample = createSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        let now = Date()
        defer { previous = (sample, now) }
        guard let previous,
              let delta = createDelta(previous.sample, sample, nil)?.takeRetainedValue(),
              let list = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary]
        else { return nil }
        let seconds = now.timeIntervalSince(previous.at)
        guard seconds > 0 else { return nil }
        var bytes: Int64 = 0
        for channel in list where Self.isANETraffic(channelName(channel)?.takeUnretainedValue() as String?) {
            bytes += max(0, integerValue(channel, 0))
        }
        return Double(bytes) / seconds
    }
}
