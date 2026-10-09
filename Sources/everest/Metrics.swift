import CoreAudio
import Darwin
import Foundation
import IOKit

struct MetricsSample {
    var cpu: UInt8 = 0
    var gpu: UInt8 = 0
    var disk: UInt8 = 0
    var networkMBs: UInt8 = 0
    var ram: UInt8 = 0
    var volumeLevel: UInt8?
}

/// System metrics for the dial display: the same five slots the firmware
/// knows (cpu, gpu, hdd, network MB/s, ram) plus the volume command.
enum Metrics {
    private static var prevCPU: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private static var prevNet: (bytes: UInt64, time: Date)?
    private static var smoothed: [Double] = [0, 0, 0, 0, 0]

    private static let lock = NSLock()
    private static var last: (sample: MetricsSample, at: Date)?

    /// The latest sample, taken again only if it is older than `maxAge`.
    /// The keyboard loop (dial gauges) and the DisplayPad thread (live keys)
    /// share it: `sample()` keeps deltas between calls, so two callers
    /// sampling on their own would each see half the CPU time.
    static func latest(maxAge: TimeInterval = 0.4) -> MetricsSample {
        lock.lock()
        defer { lock.unlock() }
        if let last, Date().timeIntervalSince(last.at) < maxAge { return last.sample }
        let s = sample()
        last = (s, Date())
        return s
    }

    static func sample() -> MetricsSample {
        var s = MetricsSample()
        let raw0 = cpuPercent()
        let raw4 = ramPercent()
        let raw2 = diskPercent()
        let raw3 = networkMBs()
        let raw1 = gpuPercent()
        let raw = [raw0, raw1, raw2, raw3, raw4]
        let alpha = 0.4
        for i in 0..<5 {
            smoothed[i] = alpha * raw[i] + (1 - alpha) * smoothed[i]
        }
        s.cpu = clamp(smoothed[0])
        s.gpu = clamp(smoothed[1])
        s.disk = clamp(smoothed[2])
        s.networkMBs = clamp(smoothed[3])
        s.ram = clamp(smoothed[4])
        s.volumeLevel = defaultOutputVolume()
        return s
    }

    private static func clamp(_ v: Double) -> UInt8 {
        UInt8(max(0, min(255, v.rounded())))
    }

    // MARK: - CPU

    static func cpuPercent() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let res = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { p in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, p, &size)
            }
        }
        guard res == KERN_SUCCESS else { return 0 }
        let ticks = (user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
        defer { prevCPU = ticks }
        guard let prev = prevCPU else { return 0 }
        let du = Double(ticks.user &- prev.user)
        let ds = Double(ticks.system &- prev.system)
        let di = Double(ticks.idle &- prev.idle)
        let dn = Double(ticks.nice &- prev.nice)
        let total = du + ds + di + dn
        guard total > 0 else { return 0 }
        return (du + ds + dn) / total * 100.0
    }

    // MARK: - RAM

    static func ramPercent() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vm = vm_statistics64_data_t()
        let res = withUnsafeMutablePointer(to: &vm) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { p in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, p, &size)
            }
        }
        guard res == KERN_SUCCESS else { return 0 }
        let pageSize = Double(vm_kernel_page_size)
        let active = Double(vm.active_count) * pageSize
        let wired = Double(vm.wire_count) * pageSize
        let compressed = Double(vm.compressor_page_count) * pageSize
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return 0 }
        return min(100, (active + wired + compressed) / total * 100.0)
    }

    // MARK: - Disk (capacity used, matching the Linux companion)

    static func diskPercent() -> Double {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else { return 0 }
        let total = Double(fs.f_blocks) * Double(fs.f_bsize)
        let free = Double(fs.f_bfree) * Double(fs.f_bsize)
        guard total > 0 else { return 0 }
        return (total - free) / total * 100.0
    }

    // MARK: - Network

    static func networkMBs() -> Double {
        var bytes: UInt64 = 0
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return 0 }
        defer { freeifaddrs(ifaddrPtr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let ifa = cur.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: ifa.ifa_name)
                if name != "lo0", let data = ifa.ifa_data {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    bytes += UInt64(d.ifi_ibytes) + UInt64(d.ifi_obytes)
                }
            }
            ptr = ifa.ifa_next
        }
        let now = Date()
        defer { prevNet = (bytes, now) }
        guard let prev = prevNet else { return 0 }
        let dt = now.timeIntervalSince(prev.time)
        guard dt > 0.2 else { return smoothed[3] }
        let delta = bytes >= prev.bytes ? bytes - prev.bytes : 0
        return Double(delta) / dt / 1_000_000.0
    }

    // MARK: - Volume

    static func defaultOutputVolume() -> UInt8? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr else { return nil }

        func scalar(element: AudioObjectPropertyElement) -> Float32? {
            var vol = Float32(0)
            var vsize = UInt32(MemoryLayout<Float32>.size)
            var vaddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element)
            guard AudioObjectHasProperty(deviceID, &vaddr) else { return nil }
            guard AudioObjectGetPropertyData(deviceID, &vaddr, 0, nil, &vsize, &vol) == noErr else { return nil }
            return vol
        }

        let candidates: [AudioObjectPropertyElement] = [
            kAudioObjectPropertyElementMain, 1, 2,
        ]
        for el in candidates {
            if let v = scalar(element: el) {
                return UInt8(max(0, min(100, Int((v * 100).rounded()))))
            }
        }
        return nil
    }

    // MARK: - GPU (Apple Silicon / Intel via IOAccelerator)

    static func gpuPercent() -> Double {
        var iterator: io_iterator_t = 0
        let match = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let stats = dict["PerformanceStatistics"] as? [String: Any] else { continue }
            for key in ["Device Utilization %", "GPU Activity(%)", "GPU Core Utilization"] {
                if let v = stats[key] as? Int { return Double(v) }
                if let v = stats[key] as? Double { return v }
            }
        }
        return 0
    }
}
