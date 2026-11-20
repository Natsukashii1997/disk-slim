import Foundation

/// 动手前最后一道核对（PRD 第 5 节内存部分）
public enum MemoryGuard {
    /// 收掉会话前再核对：pid 还在、启动时间对得上、确实是 Claude Code 会话进程；对不上的跳过
    public static func sessionPids(_ keys: [String], procs: [ProcInfo]) -> [Int32] {
        let wanted = Set(keys)
        return procs.filter { MemoryAttribution.isClaudeSession($0.path) && wanted.contains("\($0.pid)@\($0.startedAt)") }.map(\.pid)
    }

    /// 收掉会话前再看一眼还闲不闲（审查高 1）：隔几秒读两次进程，整棵进程树这几秒 CPU 用到 5% 以上的不收；
    /// 和上次采样比，这段时间忙过（或看不准）的也不收。返回还能收的 pid
    public static func quietSessionPids(_ keys: [String], before: [ProcInfo], after: [ProcInfo], seconds: TimeInterval,
                                        record: MemoryRecord, now: Date) -> [Int32] {
        let was = Dictionary(MemoryAttribution.usage(before, apps: []).sessions.map { ($0.key, $0.cpuNanos) }, uniquingKeysWith: { a, _ in a })
        let sessions = MemoryAttribution.usage(after, apps: []).sessions
        let ok = Set(sessionPids(keys, procs: after))
        return sessions.filter { s in
            guard ok.contains(s.pid), let cpu0 = was[s.key], s.cpuNanos >= cpu0, seconds > 0 else { return false }
            if Double(s.cpuNanos - cpu0) / 1e9 / seconds >= MemoryRules.busyCPU { return false }
            guard let t = record.sessions[s.key] else { return false }
            return !MemoryRecord.busy(from: t, cpu: s.cpuNanos, at: now)
        }.map(\.pid)
    }

    /// 能不能退出（一键退出、强制退出都过这一道）：系统自己的、磁盘瘦身自己、驿窗不退
    public static func mayQuit(bundleID: String) -> Bool {
        !bundleID.isEmpty && !MemoryRules.never.contains(bundleID) && bundleID != "com.apple.loginwindow" && bundleID != "com.apple.dock"
    }
}
