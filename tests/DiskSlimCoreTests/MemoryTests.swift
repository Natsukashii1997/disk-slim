import Foundation
import Testing
@testable import DiskSlimCore

@Suite struct MemoryTests {
    let mb: Int64 = 1_048_576
    let gb: Int64 = 1_073_741_824
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let claudePath = "/Users/x/Library/Application Support/Claude/claude-code/2.1.325/abc/claude.app/Contents/MacOS/claude"

    func app(_ pid: Int32, _ name: String, _ id: String, active: Bool = false, launched: TimeInterval? = nil) -> RunningApp {
        RunningApp(pid: pid, name: name, bundleID: id, bundlePath: "/Applications/\(name).app", active: active,
                   launchedAt: launched.map { now.addingTimeInterval(-$0) })
    }
    func proc(_ pid: Int32, _ ppid: Int32, _ path: String, _ bytes: Int64, cpu: UInt64 = 0, start: UInt64 = 100) -> ProcInfo {
        ProcInfo(pid: pid, ppid: ppid, path: path, footprint: bytes, cpuNanos: cpu, startedAt: start)
    }
    func status(swap: Int64 = 0, bootDaysAgo: Double = 1, level: MemoryLevel = .tight) -> MemoryStatus {
        MemoryStatus(totalBytes: 24 * gb, level: level, usedPercent: 70, swapUsedBytes: swap, swapTotalBytes: 30 * gb,
                     bootedAt: now.addingTimeInterval(-bootDaysAgo * 86_400))
    }
    /// 一天前开始记录，什么应用都没切到前台过；Obsidian（1 号）一天没在后台忙过
    func record() -> MemoryRecord {
        var r = MemoryRecord(trackingSince: now.addingTimeInterval(-86_400))
        r.apps["md.obsidian@1"] = ActivityTrack(cpuNanos: 0, at: now, busyAt: now.addingTimeInterval(-86_400))
        r.apps["com.apple.Preview@1"] = ActivityTrack(cpuNanos: 0, at: now, busyAt: now.addingTimeInterval(-86_400))
        return r
    }
    func obsidian(active: Bool = false, launched: TimeInterval? = nil) -> RunningApp { app(1, "Obsidian", "md.obsidian", active: active, launched: launched) }

    // MARK: 压力档

    @Test func 系统压力档对应正常偏紧告急() {
        #expect(MemoryLevel(kernelLevel: 1) == .normal)
        #expect(MemoryLevel(kernelLevel: 2) == .tight)
        #expect(MemoryLevel(kernelLevel: 4) == .critical)
        #expect(MemoryLevel(kernelLevel: 0) == .normal)
        #expect(MemoryLevel(kernelLevel: 4).label == "告急")
    }

    // MARK: 按应用合计

    @Test func 帮手进程算回所属应用_会话进程和插件算会话() {
        let chrome = app(10, "Google Chrome", "com.google.Chrome")
        let claude = app(20, "Claude", "com.anthropic.claudefordesktop")
        let procs = [
            proc(10, 1, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", 500 * mb),
            proc(11, 10, "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper", 700 * mb),
            // 由系统代开、父进程是 launchd，但路径在 Chrome 里面
            proc(12, 1, "/Applications/Google Chrome.app/Contents/Frameworks/Other.app/Contents/MacOS/Other", 100 * mb),
            proc(20, 1, "/Applications/Claude.app/Contents/MacOS/Claude", 300 * mb),
            proc(21, 20, "/Applications/Claude.app/Contents/Helpers/disclaimer", 1 * mb),
            proc(22, 21, claudePath, 200 * mb, cpu: 5),
            proc(23, 22, "/usr/local/bin/node", 400 * mb, cpu: 7), // 会话开的插件
            proc(30, 1, "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/x.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine", 2 * gb),
            proc(40, 1, "/usr/libexec/somethingd", 50 * mb), // 不归任何人
        ]
        let u = MemoryAttribution.usage(procs, apps: [chrome, claude])
        #expect(u.apps.first { $0.app.pid == 10 }?.bytes == 1300 * mb)
        #expect(u.apps.first { $0.app.pid == 20 }?.bytes == 301 * mb) // 会话不算进 Claude 桌面版
        #expect(u.sessions.count == 1)
        #expect(u.sessions[0].bytes == 600 * mb)
        #expect(u.sessions[0].cpuNanos == 12)
        #expect(u.vmBytes == 2 * gb)
    }

    @Test func 父进程成环也不死循环() {
        let procs = [proc(5, 6, "/a", mb), proc(6, 5, "/b", mb)]
        let u = MemoryAttribution.usage(procs, apps: [])
        #expect(u.apps.isEmpty && u.sessions.isEmpty)
    }

    // MARK: 三段

    func plan(_ apps: [(RunningApp, Int64)], sessions: [SessionMemory] = [], vm: Int64 = 0, record r: MemoryRecord? = nil,
              status s: MemoryStatus? = nil) -> MemoryPlan {
        let usage = MemoryUsage(apps: apps.map { AppMemory(app: $0.0, bytes: $0.1) }, sessions: sessions, vmBytes: vm)
        return MemoryPlan.make(usage: usage, status: s ?? status(), record: r ?? record(), now: now)
    }

    @Test func 闲了4小时以上且占300MB以上的普通应用替你挑好() {
        let p = plan([(obsidian(), 1800 * mb), (app(2, "小工具", "x.small"), 200 * mb)])
        #expect(p.picked.map(\.app.name) == ["Obsidian"])
        #expect(p.pickedBytes == 1800 * mb)
        #expect(p.keep.isEmpty) // 占得不多的不列
    }

    @Test func 前台的和30分钟内用过的算你正在用() {
        var r = record()
        r.activated("md.obsidian", at: now.addingTimeInterval(-10 * 60))
        let p = plan([(obsidian(), 2 * gb), (app(2, "预览", "com.apple.Preview", active: true), 1 * gb)], record: r)
        #expect(p.picked.isEmpty)
        #expect(p.keep.map(\.reason) == [.inUse, .inUse])
    }

    @Test func 一小时前用过的算刚用过_不挑() {
        var r = record()
        r.activated("md.obsidian", at: now.addingTimeInterval(-3600))
        let p = plan([(obsidian(), 2 * gb)], record: r)
        #expect(p.picked.isEmpty)
        #expect(p.keep.first?.reason == .recent)
    }

    @Test func 刚启动的应用按启动时间算_不会被当成闲了一天() {
        let p = plan([(obsidian(launched: 600), 2 * gb)])
        #expect(p.picked.isEmpty)
    }

    @Test func 刚开始记录时不挑_标刚开始记_记满4小时才挑() {
        let fresh = MemoryRecord(trackingSince: now.addingTimeInterval(-3600))
        let p = plan([(obsidian(launched: 86_400), 2 * gb),
                      (app(2, "预览", "com.apple.Preview", active: true, launched: 86_400), gb)], record: fresh)
        #expect(p.picked.isEmpty)
        #expect(p.keep.map(\.reason) == [.learning, .inUse]) // 前台的照样算你正在用
        // 开始记录之后才启动、又没切到前台的，按启动时间算，不算「刚开始记」
        let q = plan([(obsidian(launched: 10 * 60), 2 * gb)], record: fresh)
        #expect(q.keep.first?.reason == .inUse)
        // 有固定理由的照样写固定理由，不写「刚开始记」
        let r = plan([(app(3, "微信", "com.tencent.xinWeChat", launched: 86_400), 2 * gb),
                      (app(4, "Claude", "com.anthropic.claudefordesktop", launched: 86_400), 3 * gb)], record: fresh)
        #expect(r.keep.map(\.reason) == [.claudeHost, .messages])
    }

    @Test func 会话刚开始看的标刚开始记() {
        var r = MemoryRecord(trackingSince: now)
        let s = SessionMemory(pid: 1, startedAt: 9, bytes: gb, cpuNanos: 0)
        r.sample(status(), sessions: [s], at: now)
        #expect(plan([], sessions: [s], record: r).keep.first?.reason == .learning)
        // 每 5 分钟采样一次、看满 12 小时、中间一直不忙：转成要你说一句（一下跳 13 小时的话看不准，当忙过）
        for i in 1...(13 * 12) { r.sample(status(), sessions: [s], at: now.addingTimeInterval(Double(i) * 300)) }
        let later = MemoryPlan.make(usage: MemoryUsage(apps: [], sessions: [s], vmBytes: 0), status: status(), record: r,
                                    now: now.addingTimeInterval(13 * 3600))
        #expect(later.asks == [.sessions(keys: ["1@9"], bytes: gb)])
    }

    @Test func 收消息的_Claude桌面版_终端_系统应用_磁盘瘦身自己都先不动() {
        let p = plan([
            (app(1, "微信", "com.tencent.xinWeChat"), 2 * gb), (app(2, "飞书", "com.bytedance.macos.feishu"), 3 * gb),
            (app(3, "Claude", "com.anthropic.claudefordesktop"), 4 * gb), (app(4, "终端", "com.apple.Terminal"), 1 * gb),
            (app(5, "系统设置", "com.apple.systempreferences"), 500 * mb), (app(6, "访达", "com.apple.finder"), 500 * mb),
            (app(7, "磁盘瘦身", "local.nat.disk-slim"), 400 * mb), (app(8, "驿窗", "app.postpane.mac"), 600 * mb),
            (app(9, "照片", "com.apple.Photos"), 900 * mb),
        ])
        #expect(p.picked.isEmpty)
        #expect(Set(p.keep.map(\.reason)) == [.messages, .claudeHost, .working, .system])
        #expect(p.keep.first { $0.name == "Claude" }?.reason == .claudeHost)
    }

    @Test func 预览这种系统文档应用可以挑() {
        let p = plan([(app(1, "预览", "com.apple.Preview"), 600 * mb)])
        #expect(p.picked.count == 1)
    }

    @Test func 浏览器不进一键_要你说一句_选了还在用就先不问() {
        let chrome = app(1, "Google Chrome", "com.google.Chrome")
        let p = plan([(chrome, 8 * gb)])
        #expect(p.picked.isEmpty)
        #expect(p.asks == [.browser(AppMemory(app: chrome, bytes: 8 * gb))])
        var r = record()
        r.browserQuietUntil["com.google.Chrome"] = now.addingTimeInterval(3600)
        let q = plan([(chrome, 8 * gb)], record: r)
        #expect(q.asks.isEmpty)
        #expect(q.keep.first?.reason == .asked)
        // 不到 1 GB 的浏览器不问
        #expect(plan([(chrome, 500 * mb)]).asks.isEmpty)
    }

    @Test func 会话12小时没忙算闲着_一起问_其余算最近在忙() {
        var r = record()
        let idle = SessionMemory(pid: 1, startedAt: 9, bytes: 600 * mb, cpuNanos: 0)
        let busy = SessionMemory(pid: 2, startedAt: 9, bytes: 400 * mb, cpuNanos: 0)
        let unseen = SessionMemory(pid: 3, startedAt: 9, bytes: 100 * mb, cpuNanos: 0) // 没记录：不算闲
        r.sessions[idle.key] = ActivityTrack(cpuNanos: 0, at: now, busyAt: now.addingTimeInterval(-13 * 3600))
        r.sessions[busy.key] = ActivityTrack(cpuNanos: 0, at: now, busyAt: now.addingTimeInterval(-3600))
        let p = plan([], sessions: [idle, busy, unseen], record: r)
        #expect(p.asks == [.sessions(keys: ["1@9"], bytes: 600 * mb)])
        #expect(p.keep.first?.reason == .sessionsBusy)
        #expect(p.keep.first?.bytes == 500 * mb)
        r.sessionsQuietUntil = now.addingTimeInterval(60)
        #expect(plan([], sessions: [idle], record: r).asks.isEmpty)
    }

    @Test func 交换文件大且开机3天以上提醒重启_这周别问后不提() {
        let s = status(swap: 29 * gb, bootDaysAgo: 3.7)
        #expect(plan([], status: s).asks == [.restart(days: 3, swapBytes: 29 * gb)])
        #expect(plan([], status: status(swap: 29 * gb, bootDaysAgo: 1)).asks.isEmpty)
        #expect(plan([], status: status(swap: 2 * gb, bootDaysAgo: 10)).asks.isEmpty)
        var r = record()
        r.restartQuietUntil = now.addingTimeInterval(86_400)
        #expect(plan([], record: r, status: s).asks.isEmpty)
    }

    @Test func 谁占着取前五_会话合成一项() {
        let apps = (1...6).map { (app(Int32($0), "A\($0)", "x.\($0)"), Int64($0) * gb) }
        let sessions = [SessionMemory(pid: 90, startedAt: 1, bytes: 10 * gb, cpuNanos: 0), SessionMemory(pid: 91, startedAt: 1, bytes: 8 * gb, cpuNanos: 0)]
        let p = plan(apps, sessions: sessions, vm: 2 * gb)
        #expect(p.top.count == 5)
        #expect(p.top[0] == MemoryTopItem(kind: .sessions(2), name: "Claude Code 会话 2 个", bytes: 18 * gb))
        #expect(p.top.map(\.bytes) == [18 * gb, 6 * gb, 5 * gb, 4 * gb, 3 * gb])
    }

    // MARK: 记录

    @Test func 采样_曲线只留24小时_会话CPU用到5以上记成忙() {
        var r = MemoryRecord(trackingSince: now)
        let s0 = SessionMemory(pid: 1, startedAt: 9, bytes: mb, cpuNanos: 0)
        r.sample(status(), sessions: [s0], at: now)
        #expect(r.sessions["1@9"]?.busyAt == now)
        // 5 分钟后只用了 3 秒 CPU（1%）：不算忙
        let t1 = now.addingTimeInterval(300)
        r.sample(status(), sessions: [SessionMemory(pid: 1, startedAt: 9, bytes: mb, cpuNanos: 3_000_000_000)], at: t1)
        #expect(r.sessions["1@9"]?.busyAt == now)
        // 再 5 分钟用了 30 秒（10%）：忙
        let t2 = now.addingTimeInterval(600)
        r.sample(status(), sessions: [SessionMemory(pid: 1, startedAt: 9, bytes: mb, cpuNanos: 33_000_000_000)], at: t2)
        #expect(r.sessions["1@9"]?.busyAt == t2)
        // 会话走了就删掉；25 小时前的曲线点丢掉
        r.pressure.insert(PressurePoint(at: now.addingTimeInterval(-25 * 3600), usedPercent: 10, level: .normal), at: 0)
        r.sample(status(), sessions: [], at: now.addingTimeInterval(900))
        #expect(r.sessions.isEmpty)
        #expect(r.pressure.count == 4)
    }

    @Test func 记录缺键也能读_坏了留底从头记() throws {
        let t = TempDir()
        let log = MemoryLog(url: t.url.appendingPathComponent("memory.json"))
        try Data(#"{"trackingSince":"2026-11-18T06:00:00Z"}"#.utf8).write(to: log.url)
        let r = log.load(now: now)
        #expect(r.pressure.isEmpty && r.lastActive.isEmpty)
        try Data("{ broken".utf8).write(to: log.url)
        let fresh = log.load(now: now)
        #expect(fresh.trackingSince == now)
        let left = try FileManager.default.contentsOfDirectory(atPath: t.url.path)
        #expect(left.contains { $0.hasPrefix("memory-damaged-") && $0.hasSuffix(".json.bak") })
        var w = fresh
        w.activated("a.b", at: now)
        try log.save(w)
        #expect(log.load(now: now) == w)
    }

    // MARK: 动手前核对

    @Test func 收会话前核对pid和启动时间_对不上的不动() {
        let procs = [proc(1, 0, claudePath, mb, start: 9), proc(2, 0, claudePath, mb, start: 50), proc(3, 0, "/usr/bin/node", mb, start: 9)]
        // 2 号的 pid 被别的会话重用了（启动时间不同）；3 号不是会话进程
        #expect(MemoryGuard.sessionPids(["1@9", "2@9", "3@9", "4@9"], procs: procs) == [1])
    }

    @Test func 系统和自己不让退() {
        #expect(!MemoryGuard.mayQuit(bundleID: "com.apple.finder"))
        #expect(!MemoryGuard.mayQuit(bundleID: "local.nat.disk-slim"))
        #expect(!MemoryGuard.mayQuit(bundleID: "app.postpane.mac"))
        #expect(!MemoryGuard.mayQuit(bundleID: ""))
        #expect(MemoryGuard.mayQuit(bundleID: "com.google.Chrome"))
    }

    @Test func 本机真读得到内存状态和进程() {
        let s = readMemoryStatus()
        #expect(s != nil)
        #expect((s?.totalBytes ?? 0) > gb)
        let procs = listProcesses()
        #expect(procs.contains { $0.pid == getpid() })
    }
}

@Suite struct MemoryTonightTests {
    func bj(_ s: String) -> Date { ISO8601DateFormatter().date(from: s + "+08:00")! }

    @Test func 今晚提醒按北京时间22点_过了就一小时后() {
        #expect(MemoryRules.tonight(bj("2026-11-18T14:00:00")) == bj("2026-11-18T22:00:00"))
        // 北京时间早上 7 点（UTC 前一天 23 点）也是当天 22 点
        #expect(MemoryRules.tonight(bj("2026-11-18T07:00:00")) == bj("2026-11-18T22:00:00"))
        #expect(MemoryRules.tonight(bj("2026-11-18T22:30:00")) == bj("2026-11-18T23:30:00"))
    }
}
