import Foundation

// 第 11 批：内存记录 memory.json（docs/PRD.md 4.4）：曲线、应用最后使用时间、会话和应用的忙闲、几个「别问」。

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

/// 一个 Claude Code 会话或一个普通应用最近一次「忙」是什么时候（`MemoryRecord.sessions`、`.apps` 都用它）：整棵进程树在一个采样间隔里 CPU 用到 5% 以上就算忙
public struct ActivityTrack: Codable, Equatable {
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
    public var sessions: [String: ActivityTrack] = [:]
    /// 「今晚提醒我」重启：到点发一条通知
    public var restartRemindAt: Date?
    /// 「这周别问」重启
    public var restartQuietUntil: Date?
    /// 闲着的 Claude 会话选了「留着」：到这个时间前不再问
    public var sessionsQuietUntil: Date?
    /// 浏览器选了「还在用」：bundle id → 到这个时间前不再问
    public var browserQuietUntil: [String: Date] = [:]
    /// 普通应用的忙闲（整棵进程树的 CPU）：4 小时内在后台干过活的不挑（审查高 2、中 7）
    public var apps: [String: ActivityTrack] = [:]

    public init(trackingSince: Date) { self.trackingSince = trackingSince }

    // 自己写解码：少了哪个键也能读出来（L-08）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackingSince = try c.decode(Date.self, forKey: .trackingSince)
        pressure = try c.decodeIfPresent([PressurePoint].self, forKey: .pressure) ?? []
        lastActive = try c.decodeIfPresent([String: Date].self, forKey: .lastActive) ?? [:]
        sessions = try c.decodeIfPresent([String: ActivityTrack].self, forKey: .sessions) ?? [:]
        restartRemindAt = try c.decodeIfPresent(Date.self, forKey: .restartRemindAt)
        restartQuietUntil = try c.decodeIfPresent(Date.self, forKey: .restartQuietUntil)
        sessionsQuietUntil = try c.decodeIfPresent(Date.self, forKey: .sessionsQuietUntil)
        browserQuietUntil = try c.decodeIfPresent([String: Date].self, forKey: .browserQuietUntil) ?? [:]
        apps = try c.decodeIfPresent([String: ActivityTrack].self, forKey: .apps) ?? [:]
    }

    /// 应用每次启动时调：停机这段时间里谁用过记不到，从现在重新看满 4 小时（审查中 3）
    public mutating func restarted(at: Date) { trackingSince = max(trackingSince, at) }

    /// 一段 CPU 用量算不算忙：间隔太长（睡眠、应用没开）或合计变小（子进程退出），都看不准，一律当忙过（审查中 4、中 5）
    static func busy(from t: ActivityTrack, cpu: UInt64, at: Date) -> Bool {
        let seconds = at.timeIntervalSince(t.at)
        if seconds <= 0 || seconds > MemoryRules.longGap || cpu < t.cpuNanos { return true }
        return Double(cpu - t.cpuNanos) / 1e9 / seconds >= MemoryRules.busyCPU
    }

    private static func track(_ old: [String: ActivityTrack], _ now: [(String, UInt64)], at: Date) -> [String: ActivityTrack] {
        var next: [String: ActivityTrack] = [:]
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
                next[key] = ActivityTrack(cpuNanos: cpu, at: at, busyAt: at, since: at)
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

/// memory.json 读写：坏了先留底再从头记（和 usage.json 一样，L-08）
public struct MemoryLog {
    public let url: URL
    var file: RecordFile<MemoryRecord> { RecordFile(url: url) }

    public init(url: URL) { self.url = url }

    public static func standard(home: URL) -> MemoryLog {
        MemoryLog(url: home.appendingPathComponent("Library/Application Support/disk-slim/memory.json"))
    }

    public func load(now: Date, readOnly: Bool = false) -> MemoryRecord {
        file.load(readOnly: readOnly).value ?? MemoryRecord(trackingSince: now)
    }

    /// 文件在但读不了时报错不写（第三批起，之前会直接覆盖）
    public func save(_ r: MemoryRecord) throws { try file.save(r) }
}
