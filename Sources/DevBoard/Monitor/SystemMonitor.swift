import Darwin
import Foundation
import IOKit.ps
import Observation

struct AppUsage: Identifiable, Equatable {
    var id: String { key }
    let key: String
    var name: String
    var path: String?
    var memory: UInt64
    var cpu: Double          // percent of one core
    var pids: [pid_t]
    var paused: Bool         // any process stopped (ram-guard SIGSTOP)
    var isDev: Bool          // Godot, Blender, omp, Swift, etc.
}

struct SystemSample: Equatable {
    var cpu: Double = 0              // 0...1 across all cores
    var memUsed: UInt64 = 0
    var memTotal: UInt64 = 1
    var freePercent: Int = 100       // kernel memorystatus level (same as `memory_pressure`)
    var swapUsed: UInt64 = 0
    var netIn: Double = 0
    var netOut: Double = 0
    var diskFree: UInt64 = 0
    var battery: Int? = nil
    var charging = false
    var thermal: ProcessInfo.ThermalState = .nominal

    var memFraction: Double { Double(memUsed) / Double(max(memTotal, 1)) }
    var pressure: Double { 1 - Double(freePercent) / 100 }
}

/// Polls cheap kernel counters every 2 s; the per-app scan only runs while the Monitor tab is visible.
@MainActor @Observable
final class SystemMonitor {
    private(set) var sample = SystemSample()
    private(set) var cpuHistory: [Double] = []
    private(set) var memHistory: [Double] = []
    private(set) var netInHistory: [Double] = []
    private(set) var netOutHistory: [Double] = []
    private(set) var apps: [AppUsage] = []
    let cores = ProcessInfo.processInfo.activeProcessorCount

    /// Set while the Monitor tab is on screen; enables the 1 s refresh and process scan.
    var detailed = false {
        didSet { if detailed && !oldValue { wake() } }
    }

    @ObservationIgnored private let sampler = Sampler()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var sleeper: CheckedContinuation<Void, Never>?
    private static let historyLength = 90

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                await self.pause(seconds: self.detailed ? 1 : 3)
            }
        }
    }

    private func pause(seconds: Double) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            sleeper = c
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.resumeSleeper()
            }
        }
    }

    private func resumeSleeper() {
        let c = sleeper
        sleeper = nil
        c?.resume()
    }

    private func wake() { resumeSleeper() }

    private func tick() async {
        let wantApps = detailed
        let sampler = sampler
        let (s, list) = await Task.detached(priority: .utility) {
            (sampler.sample(), wantApps ? sampler.apps() : nil)
        }.value
        sample = s
        push(&cpuHistory, s.cpu)
        push(&memHistory, s.memFraction)
        push(&netInHistory, s.netIn)
        push(&netOutHistory, s.netOut)
        if let list { apps = list }
    }

    private func push(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > Self.historyLength { arr.removeFirst(arr.count - Self.historyLength) }
    }

    /// SIGTERM (or SIGKILL when `force`) every process in the group the user owns.
    func terminate(_ app: AppUsage, force: Bool) {
        for pid in app.pids where pid != getpid() { kill(pid, force ? SIGKILL : SIGTERM) }
        apps.removeAll { $0.key == app.key }
    }
}

/// Non-isolated sampler; holds the deltas between calls. Only touched from one detached task at a time.
private final class Sampler: @unchecked Sendable {
    private let host = mach_host_self()
    private var lastTicks: (UInt64, UInt64)?           // (busy, total)
    private var lastNet: (UInt64, UInt64, Date)?
    private var lastCPU: [pid_t: (UInt64, Date)] = [:]
    private var pathCache: [pid_t: String] = [:]
    private let timebase: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()
    private let pageSize = UInt64(vm_kernel_page_size)
    private let uid = getuid()
    private let lock = NSLock()

    func sample() -> SystemSample {
        lock.lock(); defer { lock.unlock() }
        var s = SystemSample()
        s.cpu = cpuLoad()
        (s.memUsed, s.memTotal) = memory()
        s.freePercent = Int(sysctlInt32("kern.memorystatus_level") ?? 100)
        s.swapUsed = swap()
        (s.netIn, s.netOut) = network()
        s.diskFree = diskFree()
        (s.battery, s.charging) = battery()
        s.thermal = ProcessInfo.processInfo.thermalState
        return s
    }

    private func cpuLoad() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return 0 }
        let user = UInt64(info.cpu_ticks.0), sys = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + sys + nice, total = busy + idle
        defer { lastTicks = (busy, total) }
        guard let (pb, pt) = lastTicks, total > pt else { return 0 }
        return Double(busy - pb) / Double(total - pt)
    }

    private func memory() -> (UInt64, UInt64) {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard r == KERN_SUCCESS else { return (0, total) }
        // Activity Monitor's "Memory Used" = app memory + wired + compressed.
        let app = UInt64(vm.internal_page_count) &- UInt64(vm.purgeable_count)
        let used = (app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * pageSize
        return (min(used, total), total)
    }

    private func swap() -> UInt64 {
        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 ? xsw.xsu_used : 0
    }

    private func sysctlInt32(_ name: String) -> Int32? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? v : nil
    }

    private func network() -> (Double, Double) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (0, 0) }
        defer { freeifaddrs(head) }
        var inBytes: UInt64 = 0, outBytes: UInt64 = 0
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            let a = ifa.pointee
            if let addr = a.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = a.ifa_data {
                let name = String(cString: a.ifa_name)
                if !name.hasPrefix("lo") {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    inBytes += UInt64(d.ifi_ibytes)
                    outBytes += UInt64(d.ifi_obytes)
                }
            }
            p = a.ifa_next
        }
        let now = Date()
        defer { lastNet = (inBytes, outBytes, now) }
        guard let (li, lo, lt) = lastNet else { return (0, 0) }
        let dt = max(now.timeIntervalSince(lt), 0.1)
        let di = inBytes >= li ? Double(inBytes - li) : 0
        let dout = outBytes >= lo ? Double(outBytes - lo) : 0
        return (di / dt, dout / dt)
    }

    private func diskFree() -> UInt64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return UInt64(max(0, v?.volumeAvailableCapacityForImportantUsage ?? 0))
    }

    private func battery() -> (Int?, Bool) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any],
                  let cap = d[kIOPSCurrentCapacityKey] as? Int else { continue }
            return (cap, (d[kIOPSIsChargingKey] as? Bool) ?? false)
        }
        return (nil, false)
    }

    // MARK: Per-app scan

    private static let devMarkers = ["godot", "blender", "omp", "swift", "node", "bun", "python", "blockbench", "obs", "code helper", "visual studio code", "xcode", "clang"]

    func apps() -> [AppUsage] {
        lock.lock(); defer { lock.unlock() }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let now = Date()
        var groups: [String: AppUsage] = [:]
        var seen = Set<pid_t>()

        for pid in pids.prefix(got) where pid > 0 {
            var ru = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &ru) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { continue }   // other users' processes are not readable; that's fine
            seen.insert(pid)

            let cpuNs = UInt64(Double(ru.ri_user_time + ru.ri_system_time) * timebase)
            var cpu = 0.0
            if let (prev, t) = lastCPU[pid], cpuNs >= prev {
                cpu = Double(cpuNs - prev) / max(now.timeIntervalSince(t), 0.1) / 1e9 * 100
            }
            lastCPU[pid] = (cpuNs, now)

            let path = pathCache[pid] ?? procPath(pid)
            pathCache[pid] = path
            let (key, name, bundlePath) = group(for: path, pid: pid)

            var bsd = proc_bsdinfo()
            let stopped = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0
                && bsd.pbi_status == UInt32(SSTOP)

            var g = groups[key] ?? AppUsage(key: key, name: name, path: bundlePath, memory: 0, cpu: 0, pids: [], paused: false,
                                             isDev: Self.devMarkers.contains { name.lowercased().contains($0) })
            g.memory += ru.ri_phys_footprint
            g.cpu += cpu
            g.pids.append(pid)
            g.paused = g.paused || stopped
            groups[key] = g
        }
        lastCPU = lastCPU.filter { seen.contains($0.key) }
        pathCache = pathCache.filter { seen.contains($0.key) }
        return groups.values.sorted { $0.memory > $1.memory }.prefix(14).map { $0 }
    }

    private func procPath(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        if n > 0 { return String(cString: buf) }
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, UInt32(name.count))
        return String(cString: name)
    }

    /// Groups helpers under their top-level .app so "Google Chrome" shows as one row.
    private func group(for path: String, pid: pid_t) -> (String, String, String?) {
        if let r = path.range(of: ".app/") {
            let bundle = String(path[..<r.lowerBound]) + ".app"
            let name = (bundle as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            return (bundle, name, bundle)
        }
        let name = (path as NSString).lastPathComponent
        return (name.isEmpty ? "pid\(pid)" : name, name.isEmpty ? "pid \(pid)" : name, nil)
    }
}
