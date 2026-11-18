import Foundation

// 第 11 批：内存页「替你判断」（docs/PRD.md 4.4）。纯规则，不碰系统：输入是读到的占用和记录，输出是三段。

/// 24 小时曲线上的一个点（每 5 分钟一个）
public struct PressurePoint: Codable, Equatable {
    public let at: Date
    public let usedPercent: Int
    public let level: MemoryLevel

    public init(at: Date, usedPercent: Int, level: MemoryLevel) {
        self.at = at
        self.usedPercent = usedPercent
        self.level = level
    }
}

/// 一个 Claude Code 会话最近一次「忙」是什么时候：整棵进程树在一个采样间隔里 CPU 用到 5% 以上就算忙
public struct SessionTrack: Codable, Equatable {
    public var cpuNanos: UInt64
    public var at: Date
    public var busyAt: Date
    /// 第一次见到的时间：12 小时内见到的还在「刚开始看」
    public var since: Date?

    public init(cpuNanos: UInt64, at: Date, busyAt: Date, since: Date? = nil) {
        self.cpuNanos = cpuNanos
        self.at = at
        self.busyAt = busyAt
        self.since = since
    }

    /// 还看不出忙闲：第一次见到不满 12 小时，而且那之后没忙过
    func learning(now: Date) -> Bool {
        guard let since else { return false }
        return busyAt == since && now.timeIntervalSince(since) < MemoryRules.sessionIdle
    }
}

/// memory.json：曲线、每个应用最后一次被切到前台的时间、会话忙闲、几个「别问」
public struct MemoryRecord: Codable, Equatable {
    /// 从什么时候开始记「最后使用」：之前开着、之后一直没切到前台的应用，按这个时间算
    public var trackingSince: Date
    public var pressure: [PressurePoint] = []
    public var lastActive: [String: Date] = [:]
    public var sessions: [String: SessionTrack] = [:]
    /// 「今晚提醒我」重启：到点发一条通知
    public var restartRemindAt: Date?
    /// 「这周别问」重启
    public var restartQuietUntil: Date?
    /// 闲着的 Claude 会话选了「留着」：到这个时间前不再问
    public var sessionsQuietUntil: Date?
    /// 浏览器选了「还在用」：bundle id → 到这个时间前不再问
    public var browserQuietUntil: [String: Date] = [:]
    /// 普通应用的忙闲（整棵进程树的 CPU）：4 小时内在后台干过活的不挑（审查高 2、中 7）
    public var apps: [String: SessionTrack] = [:]

    public init(trackingSince: Date) { self.trackingSince = trackingSince }

    // 自己写解码：少了哪个键也能读出来（L-08）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackingSince = try c.decode(Date.self, forKey: .trackingSince)
        pressure = try c.decodeIfPresent([PressurePoint].self, forKey: .pressure) ?? []
        lastActive = try c.decodeIfPresent([String: Date].self, forKey: .lastActive) ?? [:]
        sessions = try c.decodeIfPresent([String: SessionTrack].self, forKey: .sessions) ?? [:]
        restartRemindAt = try c.decodeIfPresent(Date.self, forKey: .restartRemindAt)
        restartQuietUntil = try c.decodeIfPresent(Date.self, forKey: .restartQuietUntil)
        sessionsQuietUntil = try c.decodeIfPresent(Date.self, forKey: .sessionsQuietUntil)
        browserQuietUntil = try c.decodeIfPresent([String: Date].self, forKey: .browserQuietUntil) ?? [:]
        apps = try c.decodeIfPresent([String: SessionTrack].self, forKey: .apps) ?? [:]
    }

    /// 应用每次启动时调：停机这段时间里谁用过记不到，从现在重新看满 4 小时（审查中 3）
    public mutating func restarted(at: Date) { trackingSince = max(trackingSince, at) }

    /// 一段 CPU 用量算不算忙：间隔太长（睡眠、应用没开）或合计变小（子进程退出），都看不准，一律当忙过（审查中 4、中 5）
    static func busy(from t: SessionTrack, cpu: UInt64, at: Date) -> Bool {
        let seconds = at.timeIntervalSince(t.at)
        if seconds <= 0 || seconds > MemoryRules.longGap || cpu < t.cpuNanos { return true }
        return Double(cpu - t.cpuNanos) / 1e9 / seconds >= MemoryRules.busyCPU
    }

    private static func track(_ old: [String: SessionTrack], _ now: [(String, UInt64)], at: Date) -> [String: SessionTrack] {
        var next: [String: SessionTrack] = [:]
        for (key, cpu) in now {
            if var t = old[key], at > t.at {
                if busy(from: t, cpu: cpu, at: at) { t.busyAt = at }
                t.cpuNanos = cpu
                t.at = at
                next[key] = t
            } else if let t = old[key] {
                next[key] = t
            } else {
                // 第一次见到：先当它刚忙过，看满一段时间才算闲
                next[key] = SessionTrack(cpuNanos: cpu, at: at, busyAt: at, since: at)
            }
        }
        return next
    }

    /// 每 5 分钟记一次：加一个曲线点（只留 24 小时），更新每个会话忙闲，走掉的会话删掉
    public mutating func sample(_ status: MemoryStatus, sessions now: [SessionMemory], apps: [AppMemory] = [], at: Date) {
        pressure.append(PressurePoint(at: at, usedPercent: status.usedPercent, level: status.level))
        pressure = pressure.filter { at.timeIntervalSince($0.at) < MemoryRules.curveWindow && $0.at <= at }
        sessions = Self.track(sessions, now.map { ($0.key, $0.cpuNanos) }, at: at)
        self.apps = Self.track(self.apps, apps.map { ($0.key, $0.cpuNanos) }, at: at)
    }

    public mutating func activated(_ bundleID: String, at: Date) { lastActive[bundleID] = at }

    /// 还看不出闲不闲：开始记录不满 4 小时，这个应用在那之前就开着、之后没切到前台过
    public func learning(_ app: RunningApp, now: Date) -> Bool {
        lastActive[app.bundleID] == nil && (app.launchedAt ?? .distantPast) <= trackingSince
            && now.timeIntervalSince(trackingSince) < MemoryRules.pickIdle
    }

    /// 应用最后一次被用的时间：记到的切到前台时间、开始记录的时间、应用启动时间，取最晚的
    public func lastUsed(_ app: RunningApp) -> Date {
        [lastActive[app.bundleID], trackingSince, app.launchedAt].compactMap { $0 }.max() ?? trackingSince
    }
}

public enum MemoryRules {
    public static let mb: Int64 = 1_048_576
    public static let gb: Int64 = 1_073_741_824
    /// 替你挑好的：占 300 MB 以上、4 小时没切到前台
    public static let pickMin: Int64 = 300 * mb
    public static let pickIdle: TimeInterval = 4 * 3600
    /// 30 分钟内用过的算「你正在用」
    public static let recent: TimeInterval = 30 * 60
    /// 浏览器占 1 GB 以上、30 分钟没用：要你说一句（退出要靠恢复标签页）
    public static let browserMin: Int64 = 1 * gb
    /// Claude Code 会话 12 小时没忙过算闲着
    public static let sessionIdle: TimeInterval = 12 * 3600
    public static let busyCPU = 0.05
    /// 两次采样隔了 15 分钟以上就看不准忙闲，当忙过
    public static let longGap: TimeInterval = 15 * 60
    /// 交换文件 8 GB 以上、开机 3 天以上：提醒重启
    public static let restartSwap: Int64 = 8 * gb
    public static let restartUptime: TimeInterval = 3 * 86_400
    public static let curveWindow: TimeInterval = 24 * 3600

    /// 「今晚提醒我」：北京时间今天 22:00；已经过了就一小时后
    public static func tonight(_ now: Date) -> Date {
        let ten = Date(timeIntervalSince1970: TimeInterval(BeijingTime.dayNumber(now)) * 86_400 - 8 * 3600 + 22 * 3600)
        return ten > now ? ten : now.addingTimeInterval(3600)
    }

    /// 要收消息的
    static let messaging: Set<String> = [
        "com.tencent.xinWeChat", "com.bytedance.macos.feishu", "com.electron.lark", "com.alibaba.DingTalkMac", "com.tencent.qq",
        "com.tencent.WeWorkMac", "com.apple.MobileSMS", "com.apple.mail", "com.tinyspeck.slackmacgap", "ru.keepcoder.Telegram",
        "com.microsoft.teams2", "us.zoom.xos",
    ]
    /// 可能有命令或程序在跑的
    static let working: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode", "dev.zed.Zed", "com.sublimetext.4",
        // ChatGPT 桌面版的 bundle id 就是 com.openai.codex，里面会跑 Codex 任务（审查高 2）
        "com.openai.codex", "com.docker.docker", "dev.orbstack.OrbStack", "com.utmapp.UTM", "com.obsproject.obs-studio",
        "com.parallels.desktop.console", "com.vmware.fusion",
    ]
    static func isWorking(_ id: String) -> Bool { working.contains(id) || id.hasPrefix("com.jetbrains.") }
    /// 可能在放声音的
    static let media: Set<String> = ["com.apple.Music", "com.spotify.client", "com.netease.163music", "com.tencent.QQMusicMac", "com.apple.podcasts"]
    static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac", "company.thebrowser.Browser", "org.mozilla.firefox", "com.brave.Browser",
    ]
    static let claudeDesktop = "com.anthropic.claudefordesktop"
    static let appleDocApps: Set<String> = ["com.apple.Preview", "com.apple.TextEdit", "com.apple.iWork.Pages", "com.apple.iWork.Numbers", "com.apple.iWork.Keynote"]
    /// 系统自己的、磁盘瘦身自己、驿窗（挂件在用）
    static let never: Set<String> = ["com.apple.finder", "local.nat.disk-slim", "app.postpane.mac", "com.apple.systempreferences"]
}

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

/// memory.json 读写：坏了先留底再从头记（和 usage.json 一样，L-08）
public struct MemoryLog {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func standard(home: URL) -> MemoryLog {
        MemoryLog(url: home.appendingPathComponent("Library/Application Support/disk-slim/memory.json"))
    }

    public func load(now: Date, readOnly: Bool = false) -> MemoryRecord {
        guard let data = try? Data(contentsOf: url) else { return MemoryRecord(trackingSince: now) }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        if let r = try? d.decode(MemoryRecord.self, from: data) { return r }
        if !readOnly {
            let aside = url.deletingLastPathComponent().appendingPathComponent("memory.broken-\(Int(now.timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
        }
        return MemoryRecord(trackingSince: now)
    }

    public func save(_ r: MemoryRecord) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try withFileLock(url) { try e.encode(r).write(to: url, options: .atomic) }
    }
}

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
