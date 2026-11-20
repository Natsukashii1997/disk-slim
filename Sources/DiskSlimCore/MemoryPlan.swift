import Foundation

// 第 11 批：内存页「替你判断」（docs/PRD.md 4.4）。纯规则，不碰系统：输入是读到的占用和记录，输出是三段。

public enum MemoryKeepReason: String, Equatable {
    case inUse = "你正在用"
    case messages = "要收消息"
    case claudeHost = "Claude Code 会话在里面跑"
    case working = "可能有命令或任务在跑"
    case media = "可能在放声音"
    case system = "系统和常驻工具"
    case recent = "刚用过"
    case sessionsBusy = "最近在忙"
    case vm = "正在跑"
    case asked = "先不问了"
    case learning = "刚开始记，看满几个小时再判断"
    case busy = "最近在后台干活"
}

public struct MemoryKeepItem: Equatable {
    public let name: String
    public let bundleID: String?
    public let bytes: Int64
    public let reason: MemoryKeepReason
}

public enum MemoryAsk: Equatable {
    /// 闲着的 Claude Code 会话（`keys` 是 pid@启动时间，执行前要再核对）
    case sessions(keys: [String], bytes: Int64)
    case browser(AppMemory)
    case restart(days: Int, swapBytes: Int64)

    public var id: String {
        switch self {
        case .sessions: return "sessions"
        case .browser(let a): return "browser:" + a.app.bundleID
        case .restart: return "restart"
        }
    }
}

public enum MemoryTopKind: Equatable {
    case app(String)
    case sessions(Int)
    case vm
}

public struct MemoryTopItem: Equatable {
    public let kind: MemoryTopKind
    public let name: String
    public let bytes: Int64
}

public struct MemoryPlan: Equatable {
    public let picked: [AppMemory]
    public let asks: [MemoryAsk]
    public let keep: [MemoryKeepItem]
    /// 谁占着：前五
    public let top: [MemoryTopItem]

    public var pickedBytes: Int64 { picked.reduce(0) { $0 + $1.bytes } }
    public var keepBytes: Int64 { keep.reduce(0) { $0 + $1.bytes } }

    public static func make(usage: MemoryUsage, status: MemoryStatus?, record: MemoryRecord, now: Date) -> MemoryPlan {
        var picked: [AppMemory] = []
        var asks: [MemoryAsk] = []
        var keep: [MemoryKeepItem] = []
        func keepIt(_ a: AppMemory, _ r: MemoryKeepReason) {
            keep.append(MemoryKeepItem(name: a.app.name, bundleID: a.app.bundleID, bytes: a.bytes, reason: r))
        }

        for a in usage.apps {
            let id = a.app.bundleID
            let idle = now.timeIntervalSince(record.lastUsed(a.app))
            // 占得不多的不列（也不进先不动，免得列一长串；浏览器要 1 GB 才问，也满足这一条）
            if a.bytes < MemoryRules.pickMin { continue }
            if a.app.active { keepIt(a, .inUse); continue }
            if id == MemoryRules.claudeDesktop { keepIt(a, .claudeHost); continue }
            if MemoryRules.messaging.contains(id) { keepIt(a, .messages); continue }
            if MemoryRules.isWorking(id) { keepIt(a, .working); continue }
            if MemoryRules.media.contains(id) { keepIt(a, .media); continue }
            // 系统自带的应用里，只有预览、文本编辑这类文档应用会被挑；浏览器下面单独问
            if MemoryRules.never.contains(id)
                || id.hasPrefix("com.apple.") && !MemoryRules.appleDocApps.contains(id) && !MemoryRules.browsers.contains(id) {
                keepIt(a, .system); continue
            }
            // 有固定理由的上面已经分完；剩下的（能挑的、浏览器）刚开始记录时先看着
            if record.learning(a.app, now: now) { keepIt(a, .learning); continue }
            if idle < MemoryRules.recent { keepIt(a, .inUse); continue }
            if MemoryRules.browsers.contains(id) {
                guard a.bytes >= MemoryRules.browserMin else { continue }
                if let q = record.browserQuietUntil[id], q > now { keepIt(a, .asked) } else { asks.append(.browser(a)) }
                continue
            }
            if idle < MemoryRules.pickIdle { keepIt(a, .recent); continue }
            // 4 小时没切到前台，但这期间在后台干过活（下载、跑任务、导出）的不挑；没记到忙闲的也不挑
            guard let t = record.apps[a.key], now.timeIntervalSince(t.busyAt) >= MemoryRules.pickIdle else { keepIt(a, .busy); continue }
            picked.append(a)
        }

        // Claude Code 会话：12 小时没忙过的一起问；其余的算在用
        let idle = usage.sessions.filter { s in
            guard let t = record.sessions[s.key] else { return false }
            return now.timeIntervalSince(t.busyAt) >= MemoryRules.sessionIdle
        }
        let busy = usage.sessions.filter { s in !idle.contains(s) }
        if !idle.isEmpty {
            let bytes = idle.reduce(0) { $0 + $1.bytes }
            if let q = record.sessionsQuietUntil, q > now {
                keep.append(MemoryKeepItem(name: "闲着的 Claude 会话 \(idle.count) 个", bundleID: nil, bytes: bytes, reason: .asked))
            } else {
                asks.append(.sessions(keys: idle.map(\.key), bytes: bytes))
            }
        }
        if !busy.isEmpty {
            let learning = busy.allSatisfy { record.sessions[$0.key]?.learning(now: now) ?? true }
            keep.append(MemoryKeepItem(name: "Claude 会话 \(busy.count) 个", bundleID: nil, bytes: busy.reduce(0) { $0 + $1.bytes },
                                       reason: learning ? .learning : .sessionsBusy))
        }
        if usage.vmBytes >= MemoryRules.pickMin {
            keep.append(MemoryKeepItem(name: "虚拟机", bundleID: nil, bytes: usage.vmBytes, reason: .vm))
        }

        // 重启：交换文件大、又开机很久
        if let s = status, let boot = s.bootedAt, s.swapUsedBytes >= MemoryRules.restartSwap,
           now.timeIntervalSince(boot) >= MemoryRules.restartUptime, !(record.restartQuietUntil.map { $0 > now } ?? false) {
            asks.append(.restart(days: Int(now.timeIntervalSince(boot) / 86_400), swapBytes: s.swapUsedBytes))
        }

        var top: [MemoryTopItem] = usage.apps.map { MemoryTopItem(kind: .app($0.app.bundleID), name: $0.app.name, bytes: $0.bytes) }
        if !usage.sessions.isEmpty {
            top.append(MemoryTopItem(kind: .sessions(usage.sessions.count), name: "Claude Code 会话 \(usage.sessions.count) 个",
                                     bytes: usage.sessions.reduce(0) { $0 + $1.bytes }))
        }
        if usage.vmBytes > 0 { top.append(MemoryTopItem(kind: .vm, name: "虚拟机", bytes: usage.vmBytes)) }
        top = Array(top.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }.prefix(5))

        return MemoryPlan(picked: picked.sorted { $0.bytes > $1.bytes }, asks: asks, keep: keep.sorted { $0.bytes > $1.bytes }, top: top)
    }
}
