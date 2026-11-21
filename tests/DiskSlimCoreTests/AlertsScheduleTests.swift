import Foundation
import Testing
@testable import DiskSlimCore

/// 第三批从应用层（Store）挪到核心层的几条判断：什么时候重新扫描、自动清理能不能插进来、退出前的核对。
/// 规则原样搬过来，这里把每个分支钉住。
@Suite struct AlertsScheduleTests {
    /// 2025-11-21 12:40 北京时间（周五）
    let now = Date(timeIntervalSince1970: 1_763_700_000)
    let gb: Int64 = 1_073_741_824

    func sample(_ at: Date) -> UsageSample { UsageSample(at: at, totalBytes: 500 * gb, freeBytes: 100 * gb, parts: [:]) }

    /// 周报已发、自动清理关：只剩「今天有没有记过」「多久没扫」两条在起作用
    var quiet: AlertState {
        var s = AlertState()
        s.sent["weekly"] = BeijingTime.dayKey(Weekly.lastReport(atOrBefore: now))
        return s
    }

    func needs(samples: [UsageSample]? = nil, scannedAgo: TimeInterval? = 7200, state: AlertState? = nil,
               allowed: Bool? = true, free: Int64? = 100 * 1_073_741_824) -> Bool {
        Alerts.needsScan(now: now, samples: samples ?? [sample(now.addingTimeInterval(-60))],
                         scannedAt: scannedAgo.map { now.addingTimeInterval(-$0) }, state: state ?? quiet,
                         notificationsAllowed: allowed, free: free)
    }

    @Test func 今天还没记过每日空间就扫() {
        #expect(needs(samples: []))
        // 昨天的不算（按北京日期）
        #expect(needs(samples: [sample(now.addingTimeInterval(-86_400))]))
    }

    @Test func 还没扫描过就扫() { #expect(needs(scannedAgo: nil)) }

    @Test func 一小时内扫过就不扫_哪怕周报没发或自动清理到点() {
        var s = AlertState()
        s.settings.autoClean = true
        #expect(!needs(scannedAgo: 3599, state: s, free: 10 * gb))
    }

    @Test func 超过一小时_没有要做的事也不扫() { #expect(!needs(scannedAgo: 3600)) }

    @Test func 超过一小时_周报该发没发就扫_通知被拒时不扫() {
        var s = quiet
        s.sent["weekly"] = "2020-01-03"
        #expect(needs(state: s))
        #expect(needs(state: s, allowed: nil), "还不知道权限时照常扫")
        #expect(!needs(state: s, allowed: false))
        s.settings.weekly = false
        #expect(!needs(state: s))
    }

    @Test func 超过一小时_自动清理到点就扫() {
        var s = quiet
        s.settings.autoClean = true
        #expect(needs(state: s, free: 59 * gb))
        #expect(!needs(state: s, free: 60 * gb))
        #expect(!needs(state: s, free: nil))
        s.autoCleanAt = now.addingTimeInterval(-3600)
        #expect(!needs(state: s, free: 10 * gb), "离上次自动清理不到 2 小时")
    }

    @Test func 自动清理插不插进来_每个条件单独挡得住() {
        var s = AlertState()
        s.settings.autoClean = true
        func may(active: Bool = true, busy: Bool = false, confirming: Bool = false, undo: Bool = false,
                 report: Bool = true, free: Int64? = 10 * 1_073_741_824) -> Bool {
            Alerts.mayAutoCleanNow(active: active, busy: busy, confirming: confirming, undoOffered: undo,
                                   hasReport: report, now: now, free: free, state: s)
        }
        #expect(may())
        #expect(!may(active: false))
        #expect(!may(busy: true))
        #expect(!may(confirming: true))
        #expect(!may(undo: true))
        #expect(!may(report: false))
        #expect(!may(free: 60 * gb))
        s.settings.autoClean = false
        #expect(!may())
    }

    @Test func 退出前核对_名单_自己_pid换了人() {
        let app = RunningApp(pid: 42, name: "Safari", bundleID: "com.apple.Safari", bundlePath: "/Applications/Safari.app")
        #expect(MemoryGuard.mayTerminate(app, selfPID: 7, currentBundleID: "com.apple.Safari"))
        #expect(!MemoryGuard.mayTerminate(app, selfPID: 42, currentBundleID: "com.apple.Safari"), "自己不退")
        #expect(!MemoryGuard.mayTerminate(app, selfPID: 7, currentBundleID: "com.example.other"), "pid 已经换成别的应用")
        #expect(!MemoryGuard.mayTerminate(app, selfPID: 7, currentBundleID: nil), "进程已经没了")
        let dock = RunningApp(pid: 43, name: "Dock", bundleID: "com.apple.dock", bundlePath: "")
        #expect(!MemoryGuard.mayTerminate(dock, selfPID: 7, currentBundleID: "com.apple.dock"))
    }
}
