import Darwin
import Foundation

// 第 11 批：内存（docs/PRD.md 3.6、4.4）。这里只读系统状态，不退出、不结束任何进程。

/// 内存压力三档，照系统自己的判断（`kern.memorystatus_vm_pressure_level`：1 正常、2 警告、4 严重）
public enum MemoryLevel: String, Codable, Equatable {
    case normal, tight, critical

    public init(kernelLevel: Int) {
        switch kernelLevel {
        case 4...: self = .critical
        case 2, 3: self = .tight
        default: self = .normal
        }
    }

    public var label: String {
        switch self {
        case .normal: return "正常"
        case .tight: return "偏紧"
        case .critical: return "告急"
        }
    }
}

public struct MemoryStatus: Equatable {
    public let totalBytes: Int64
    public let level: MemoryLevel
    /// 已用的百分比（0～100）：100 减去系统报的「空闲百分比」（`kern.memorystatus_level`，`memory_pressure` 命令打印的那个）
    public let usedPercent: Int
    public let swapUsedBytes: Int64
    public let swapTotalBytes: Int64
    /// 开机时间：交换文件大、又很久没重启时提醒重启
    public let bootedAt: Date?

    public init(totalBytes: Int64, level: MemoryLevel, usedPercent: Int, swapUsedBytes: Int64, swapTotalBytes: Int64, bootedAt: Date?) {
        self.totalBytes = totalBytes
        self.level = level
        self.usedPercent = max(0, min(100, usedPercent))
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.bootedAt = bootedAt
    }
}

private func sysctlValue<T>(_ name: String, _ zero: T) -> T? {
    var value = zero
    var size = MemoryLayout<T>.size
    let ok = withUnsafeMutablePointer(to: &value) { sysctlbyname(name, $0, &size, nil, 0) }
    return ok == 0 ? value : nil
}

/// 读本机内存状态；都不需要管理员权限
public func readMemoryStatus() -> MemoryStatus? {
    guard let total = sysctlValue("hw.memsize", UInt64(0)),
          let level = sysctlValue("kern.memorystatus_vm_pressure_level", Int32(0)),
          let freePercent = sysctlValue("kern.memorystatus_level", Int32(0)) else { return nil }
    let swap = sysctlValue("vm.swapusage", xsw_usage())
    let boot = sysctlValue("kern.boottime", timeval()).map { Date(timeIntervalSince1970: TimeInterval($0.tv_sec)) }
    return MemoryStatus(totalBytes: Int64(total), level: MemoryLevel(kernelLevel: Int(level)), usedPercent: 100 - Int(freePercent),
                        swapUsedBytes: Int64(swap?.xsu_used ?? 0), swapTotalBytes: Int64(swap?.xsu_total ?? 0), bootedAt: boot)
}

/// 一个进程：只收本用户、读得到内存的（系统和别的用户的进程读不到，也不归我们管）
public struct ProcInfo: Equatable {
    public let pid: Int32
    public let ppid: Int32
    public let path: String
    /// 和「活动监视器」的「内存」一栏同一个数（phys_footprint，含被压缩、换到硬盘的部分）
    public let footprint: Int64
    /// 累计用过的 CPU 时间（纳秒）
    public let cpuNanos: UInt64
    /// 启动时间（秒）：和 pid 一起认同一个进程，pid 被重用时不会认错
    public let startedAt: UInt64

    public init(pid: Int32, ppid: Int32, path: String, footprint: Int64, cpuNanos: UInt64 = 0, startedAt: UInt64 = 0) {
        self.pid = pid
        self.ppid = ppid
        self.path = path
        self.footprint = footprint
        self.cpuNanos = cpuNanos
        self.startedAt = startedAt
    }
}

/// 列出本用户的所有进程
public func listProcesses() -> [ProcInfo] {
    let me = getuid()
    var count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    var out: [ProcInfo] = []
    for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
        var bsd = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0, bsd.pbi_uid == me else { continue }
        var usage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { continue }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let path = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
        out.append(ProcInfo(pid: pid, ppid: Int32(bsd.pbi_ppid), path: path, footprint: Int64(usage.ri_phys_footprint),
                            cpuNanos: cpuNanos(of: usage), startedAt: bsd.pbi_start_tvsec))
    }
    return out
}

/// rusage 里的 CPU 时间单位是 mach 时间刻度，换成纳秒
private func cpuNanos(of u: rusage_info_v4) -> UInt64 {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    // 加上已经退出、被回收的子进程用掉的时间：工具命令大多是一闪而过的短进程（审查中 5）
    let ticks = u.ri_user_time &+ u.ri_system_time &+ u.ri_child_user_time &+ u.ri_child_system_time
    guard tb.denom > 0 else { return ticks }
    return ticks / UInt64(tb.denom) * UInt64(tb.numer)
}

/// 一个普通应用（程序坞里那种）；由应用层从 NSWorkspace 读进来
public struct RunningApp: Equatable {
    public let pid: Int32
    public let name: String
    public let bundleID: String
    public let bundlePath: String
    /// 现在在前台
    public let active: Bool
    public let launchedAt: Date?

    public init(pid: Int32, name: String, bundleID: String, bundlePath: String, active: Bool = false, launchedAt: Date? = nil) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.active = active
        self.launchedAt = launchedAt
    }
}

/// 一个应用连同它开出来的帮手进程一共占多少
public struct AppMemory: Equatable {
    public let app: RunningApp
    public let bytes: Int64
    /// 整棵进程树累计的 CPU 时间：看它在后台忙不忙
    public let cpuNanos: UInt64

    public var key: String { "\(app.bundleID)@\(app.pid)" }

    public init(app: RunningApp, bytes: Int64, cpuNanos: UInt64 = 0) {
        self.app = app
        self.bytes = bytes
        self.cpuNanos = cpuNanos
    }
}

/// Claude 桌面版里的一个 Claude Code 会话：会话进程连同它开的插件进程
public struct SessionMemory: Equatable {
    public let pid: Int32
    public let startedAt: UInt64
    public let bytes: Int64
    /// 整棵进程树累计的 CPU 时间：子进程在跑（比如在编译）也算这个会话在忙
    public let cpuNanos: UInt64

    public var key: String { "\(pid)@\(startedAt)" }

    public init(pid: Int32, startedAt: UInt64, bytes: Int64, cpuNanos: UInt64) {
        self.pid = pid
        self.startedAt = startedAt
        self.bytes = bytes
        self.cpuNanos = cpuNanos
    }
}

public struct MemoryUsage: Equatable {
    public let apps: [AppMemory]
    public let sessions: [SessionMemory]
    /// 系统虚拟机（Cowork、Colima 等用的）：不是普通应用，单列
    public let vmBytes: Int64

    public init(apps: [AppMemory], sessions: [SessionMemory], vmBytes: Int64) {
        self.apps = apps
        self.sessions = sessions
        self.vmBytes = vmBytes
    }
}

public enum MemoryAttribution {
    /// Claude 桌面版装的 Claude Code 命令行：`~/Library/Application Support/Claude/claude-code/<版本>/<哈希>/claude.app/Contents/MacOS/claude`
    /// （只认桌面版自己的目录，自己编译的 claude-code 不算，审查低 11）
    public static func isClaudeSession(_ path: String) -> Bool {
        path.contains("/Library/Application Support/Claude/claude-code/") && path.hasSuffix("/MacOS/claude")
    }

    static func isVM(_ path: String) -> Bool { path.hasSuffix("/com.apple.Virtualization.VirtualMachine") }

    /// 每个进程顺着父进程往上找，先碰到 Claude Code 会话进程就算会话的，先碰到普通应用就算那个应用的；
    /// 都没碰到（比如由系统代开的网页进程）再看路径在不在某个应用里面。都不是的不算。
    public static func usage(_ procs: [ProcInfo], apps: [RunningApp]) -> MemoryUsage {
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let appByPid = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var appBytes: [Int32: Int64] = [:]
        var appCPU: [Int32: UInt64] = [:]
        var sessionBytes: [Int32: Int64] = [:]
        var sessionCPU: [Int32: UInt64] = [:]
        var vm: Int64 = 0

        func owner(_ p: ProcInfo) -> (session: Int32?, app: Int32?) {
            var cur: ProcInfo? = p
            var seen = Set<Int32>()
            while let c = cur, c.pid > 1, seen.insert(c.pid).inserted {
                if isClaudeSession(c.path) { return (c.pid, nil) }
                if appByPid[c.pid] != nil { return (nil, c.pid) }
                cur = byPid[c.ppid]
            }
            // 路径落在某个应用里：取最长的那个（应用里套着的帮手应用归最里面那层）
            let hit = apps.filter { !$0.bundlePath.isEmpty && p.path.hasPrefix($0.bundlePath + "/") }
                .max { $0.bundlePath.count < $1.bundlePath.count }
            return (nil, hit?.pid)
        }

        for p in procs {
            if isVM(p.path) { vm += p.footprint; continue }
            let o = owner(p)
            if let s = o.session {
                sessionBytes[s, default: 0] += p.footprint
                sessionCPU[s, default: 0] &+= p.cpuNanos
            } else if let a = o.app {
                appBytes[a, default: 0] += p.footprint
                appCPU[a, default: 0] &+= p.cpuNanos
            }
        }
        let appList = apps.compactMap { a in appBytes[a.pid].map { AppMemory(app: a, bytes: $0, cpuNanos: appCPU[a.pid] ?? 0) } }
            .sorted { $0.bytes > $1.bytes }
        let sessions = sessionBytes.compactMap { pid, bytes in
            byPid[pid].map { SessionMemory(pid: pid, startedAt: $0.startedAt, bytes: bytes, cpuNanos: sessionCPU[pid] ?? 0) }
        }.sorted { $0.bytes > $1.bytes }
        return MemoryUsage(apps: appList, sessions: sessions, vmBytes: vm)
    }
}
