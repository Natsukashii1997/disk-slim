import Foundation
import Testing
@testable import DiskSlimCore

// 第 11 批独立审查的对抗测试（2026-11-18，原稿在 evidence/2026-11-18-memory/review/）：
// A 组是审查找到的问题，按修好后的规则断言；B 组是边界回归。
@Suite struct MemoryAdversarialTests {
    let gb: Int64 = 1_073_741_824
    let mb: Int64 = 1_048_576
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let claudePath = "/Users/x/Library/Application Support/Claude/claude-code/2.1.325/abc/claude.app/Contents/MacOS/claude"
    var st: MemoryStatus { MemoryStatus(totalBytes: 24 * gb, level: .normal, usedPercent: 50, swapUsedBytes: 0, swapTotalBytes: 0, bootedAt: nil) }

    func usage(_ apps: [(RunningApp, Int64)], sessions: [SessionMemory] = []) -> MemoryUsage {
        MemoryUsage(apps: apps.map { AppMemory(app: $0.0, bytes: $0.1) }, sessions: sessions, vmBytes: 0)
    }
    func hasSessionsAsk(_ p: MemoryPlan) -> Bool { p.asks.contains { if case .sessions = $0 { return true }; return false } }

    @Test func A1_应用停过一段再启动_从启动起重新看满4小时() {
        var r = MemoryRecord(trackingSince: now.addingTimeInterval(-3 * 86_400))
        r.activated("md.obsidian", at: now.addingTimeInterval(-10 * 3600))
        r.apps["md.obsidian@10"] = ActivityTrack(cpuNanos: 0, at: now, busyAt: now.addingTimeInterval(-86_400))
        let a = RunningApp(pid: 10, name: "Obsidian", bundleID: "md.obsidian", bundlePath: "/Applications/Obsidian.app",
                           launchedAt: now.addingTimeInterval(-2 * 86_400))
        r.restarted(at: now.addingTimeInterval(-60))
        #expect(MemoryPlan.make(usage: usage([(a, 800 * mb)]), status: nil, record: r, now: now).picked.isEmpty)
        // 启动满 4 小时后才挑
        #expect(MemoryPlan.make(usage: usage([(a, 800 * mb)]), status: nil, record: r, now: now.addingTimeInterval(5 * 3600)).picked.count == 1)
        // 时钟往回拨：不把开始时间往回挪
        r.restarted(at: now.addingTimeInterval(-86_400))
        #expect(r.trackingSince == now.addingTimeInterval(-60))
    }

    @Test func A2_采样间隔很长时_当忙过() {
        var r = MemoryRecord(trackingSince: now.addingTimeInterval(-5 * 86_400))
        r.sessions["7@1"] = ActivityTrack(cpuNanos: 0, at: now.addingTimeInterval(-2 * 86_400), busyAt: now.addingTimeInterval(-2 * 86_400))
        let s = SessionMemory(pid: 7, startedAt: 1, bytes: gb, cpuNanos: 3600 * 1_000_000_000)
        r.sample(st, sessions: [s], at: now)
        #expect(!hasSessionsAsk(MemoryPlan.make(usage: usage([], sessions: [s]), status: nil, record: r, now: now)))
    }

    @Test func A3_子进程跑完退出_合计变小时当忙过() {
        var r = MemoryRecord(trackingSince: now.addingTimeInterval(-86_400))
        r.sessions["7@1"] = ActivityTrack(cpuNanos: 210 * 1_000_000_000, at: now.addingTimeInterval(-300), busyAt: now.addingTimeInterval(-13 * 3600))
        r.sample(st, sessions: [SessionMemory(pid: 7, startedAt: 1, bytes: gb, cpuNanos: 15 * 1_000_000_000)], at: now)
        #expect(r.sessions["7@1"]?.busyAt == now)
    }

    @Test func A4_收会话前再看一眼_正在跑的不收_闲着的收() {
        var r = MemoryRecord(trackingSince: now.addingTimeInterval(-86_400))
        r.sessions["7@1"] = ActivityTrack(cpuNanos: 100_000_000_000, at: now.addingTimeInterval(-120), busyAt: now.addingTimeInterval(-13 * 3600))
        r.sessions["9@1"] = ActivityTrack(cpuNanos: 100_000_000_000, at: now.addingTimeInterval(-120), busyAt: now.addingTimeInterval(-13 * 3600))
        func procs(_ cpu7: UInt64, _ child7: UInt64, _ cpu9: UInt64) -> [ProcInfo] {
            [ProcInfo(pid: 7, ppid: 6, path: claudePath, footprint: gb, cpuNanos: cpu7, startedAt: 1),
             ProcInfo(pid: 8, ppid: 7, path: "/bin/zsh", footprint: mb, cpuNanos: child7, startedAt: 2),
             ProcInfo(pid: 9, ppid: 6, path: claudePath, footprint: gb, cpuNanos: cpu9, startedAt: 1)]
        }
        // 7 号的子进程这 3 秒用了 2 秒 CPU（正在编译）；9 号只用了一点点
        let before = procs(100_000_000_000, 0, 100_000_000_000)
        let after = procs(100_010_000_000, 2_000_000_000, 100_020_000_000)
        #expect(MemoryGuard.quietSessionPids(["7@1", "9@1"], before: before, after: after, seconds: 3, record: r, now: now) == [9])
        // 上次采样以来 9 号忙过（两分钟用了 30 秒）：也不收
        let busySince = procs(100_000_000_000, 0, 130_000_000_000)
        #expect(MemoryGuard.quietSessionPids(["9@1"], before: busySince, after: busySince, seconds: 3, record: r, now: now).isEmpty)
        // 没有采样记录的不收
        #expect(MemoryGuard.quietSessionPids(["9@1"], before: before, after: before, seconds: 3, record: MemoryRecord(trackingSince: now), now: now).isEmpty)
    }

    @Test func A5_系统自带应用_强制退出页能退_一键退出不挑() {
        // 强制退出页和系统 ⌥⌘Esc 一样，卡住的终端、活动监视器也要能关
        #expect(MemoryGuard.mayQuit(bundleID: "com.apple.Terminal"))
        #expect(MemoryGuard.mayQuit(bundleID: "com.apple.ActivityMonitor"))
        var r = MemoryRecord(trackingSince: now.addingTimeInterval(-86_400))
        r.apps["com.apple.ActivityMonitor@3"] = ActivityTrack(cpuNanos: 0, at: now, busyAt: now.addingTimeInterval(-86_400))
        let a = RunningApp(pid: 3, name: "活动监视器", bundleID: "com.apple.ActivityMonitor", bundlePath: "/System/Applications/Utilities/Activity Monitor.app")
        #expect(MemoryPlan.make(usage: usage([(a, 500 * mb)]), status: nil, record: r, now: now).picked.isEmpty)
    }

    @Test func A6_A7_ChatGPT和Docker这类有后台任务的不挑() {
        var r = MemoryRecord(trackingSince: now.addingTimeInterval(-86_400))
        for id in ["com.openai.codex@11", "com.docker.docker@12", "com.jetbrains.goland@13"] {
            r.apps[id] = ActivityTrack(cpuNanos: 0, at: now, busyAt: now.addingTimeInterval(-86_400))
        }
        let apps = [RunningApp(pid: 11, name: "ChatGPT", bundleID: "com.openai.codex", bundlePath: "/Applications/ChatGPT.app"),
                    RunningApp(pid: 12, name: "Docker", bundleID: "com.docker.docker", bundlePath: "/Applications/Docker.app"),
                    RunningApp(pid: 13, name: "GoLand", bundleID: "com.jetbrains.goland", bundlePath: "/Applications/GoLand.app")]
        let p = MemoryPlan.make(usage: usage(apps.map { ($0, 2 * gb) }), status: nil, record: r, now: now)
        #expect(p.picked.isEmpty)
        #expect(Set(p.keep.map(\.reason)) == [.working])
    }

    @Test func A6b_4小时没切前台但在后台忙过的普通应用不挑() {
        var r = MemoryRecord(trackingSince: now.addingTimeInterval(-86_400))
        let a = RunningApp(pid: 14, name: "某下载器", bundleID: "x.downloader", bundlePath: "/Applications/D.app")
        r.apps["x.downloader@14"] = ActivityTrack(cpuNanos: 0, at: now, busyAt: now.addingTimeInterval(-3600))
        #expect(MemoryPlan.make(usage: usage([(a, gb)]), status: nil, record: r, now: now).keep.first?.reason == .busy)
        // 没记到忙闲的也不挑
        #expect(MemoryPlan.make(usage: usage([(a, gb)]), status: nil, record: MemoryRecord(trackingSince: now.addingTimeInterval(-86_400)), now: now).picked.isEmpty)
        // 采样把应用的忙闲记下来
        r.sample(st, sessions: [], apps: [AppMemory(app: a, bytes: gb, cpuNanos: 60_000_000_000)], at: now.addingTimeInterval(300))
        #expect(r.apps["x.downloader@14"]?.busyAt == now.addingTimeInterval(300))
    }

    @Test func A8_不到300MB的浏览器不列() {
        let a = RunningApp(pid: 13, name: "Safari", bundleID: "com.apple.Safari", bundlePath: "/Applications/Safari.app", active: true)
        #expect(MemoryPlan.make(usage: usage([(a, 80 * mb)]), status: nil, record: MemoryRecord(trackingSince: now), now: now).keep.isEmpty)
    }

    @Test func A9_只认桌面版目录里的会话进程() {
        #expect(MemoryAttribution.isClaudeSession(claudePath))
        #expect(!MemoryAttribution.isClaudeSession("/Users/x/code/claude-code/build/claude.app/Contents/MacOS/claude"))
    }

    // ---- 边界回归 ----

    @Test func B1_时钟回拨_不会把会话判闲_将来的曲线点丢掉() {
        var r = MemoryRecord(trackingSince: now.addingTimeInterval(-86_400))
        r.sessions["7@1"] = ActivityTrack(cpuNanos: 0, at: now.addingTimeInterval(3600), busyAt: now.addingTimeInterval(3600))
        let s = SessionMemory(pid: 7, startedAt: 1, bytes: gb, cpuNanos: 0)
        r.sample(st, sessions: [s], at: now)
        #expect(!hasSessionsAsk(MemoryPlan.make(usage: usage([], sessions: [s]), status: nil, record: r, now: now)))
        r.pressure = [PressurePoint(at: now.addingTimeInterval(7200), usedPercent: 1, level: .normal)]
        r.sample(st, sessions: [s], at: now)
        #expect(r.pressure.count == 1)
    }

    @Test func B2_CPU计数回绕不崩() {
        var r = MemoryRecord(trackingSince: now.addingTimeInterval(-86_400))
        r.sessions["7@1"] = ActivityTrack(cpuNanos: UInt64.max, at: now.addingTimeInterval(-300), busyAt: now.addingTimeInterval(-300))
        r.sample(st, sessions: [SessionMemory(pid: 7, startedAt: 1, bytes: gb, cpuNanos: 5)], at: now)
        #expect(r.sessions["7@1"]?.cpuNanos == 5)
    }

    @Test func B3_pid被重用或路径不对不收() {
        #expect(MemoryGuard.sessionPids(["7@1"], procs: [ProcInfo(pid: 7, ppid: 6, path: claudePath, footprint: gb, startedAt: 2)]).isEmpty)
        #expect(MemoryGuard.sessionPids(["7@1"], procs: [ProcInfo(pid: 7, ppid: 6, path: "/usr/bin/python3", footprint: gb, startedAt: 1)]).isEmpty)
    }

    @Test func B4_长环和自环不死循环_最长bundle路径胜出() {
        let outer = RunningApp(pid: 100, name: "Outer", bundleID: "x.outer", bundlePath: "/Applications/Outer.app")
        let inner = RunningApp(pid: 200, name: "Inner", bundleID: "x.inner", bundlePath: "/Applications/Outer.app/Contents/Inner.app")
        let procs = [
            ProcInfo(pid: 100, ppid: 1, path: "/Applications/Outer.app/Contents/MacOS/Outer", footprint: 10),
            ProcInfo(pid: 200, ppid: 1, path: "/Applications/Outer.app/Contents/Inner.app/Contents/MacOS/Inner", footprint: 10),
            ProcInfo(pid: 300, ppid: 301, path: "/Applications/Outer.app/Contents/Inner.app/Contents/MacOS/Helper", footprint: 5),
            ProcInfo(pid: 301, ppid: 302, path: "/x", footprint: 1),
            ProcInfo(pid: 302, ppid: 300, path: "/y", footprint: 1),
            ProcInfo(pid: 400, ppid: 400, path: "/Applications/Outer.appX/Contents/MacOS/z", footprint: 7),
        ]
        let u = MemoryAttribution.usage(procs, apps: [outer, inner])
        #expect(u.apps.first { $0.app.pid == 200 }?.bytes == 15)
        #expect(u.apps.first { $0.app.pid == 100 }?.bytes == 10)
    }

    @Test func B5_旧版memory_json缺键也能读() throws {
        let json = #"{"trackingSince":"2026-11-18T08:00:00Z","sessions":{"7@1":{"cpuNanos":1,"at":"2026-11-18T08:00:00Z","busyAt":"2026-11-18T08:00:00Z"}}}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let r = try d.decode(MemoryRecord.self, from: Data(json.utf8))
        #expect(r.sessions["7@1"]?.since == nil)
        #expect(r.browserQuietUntil.isEmpty && r.apps.isEmpty)
    }

    @Test func B6_今晚提醒_北京时间边界() {
        let f = ISO8601DateFormatter()
        let a = f.date(from: "2026-11-18T23:59:00+08:00")!
        #expect(MemoryRules.tonight(a) == a.addingTimeInterval(3600))
        #expect(MemoryRules.tonight(f.date(from: "2026-11-19T00:01:00+08:00")!) == f.date(from: "2026-11-19T22:00:00+08:00")!)
        let c = f.date(from: "2026-11-18T22:00:00+08:00")!
        #expect(MemoryRules.tonight(c) == c.addingTimeInterval(3600))
    }
}
