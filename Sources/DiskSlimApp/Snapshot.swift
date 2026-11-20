import AppKit
import DiskSlimCore
import SwiftUI

/// `DiskSlim --snapshot <目录>`：用真实扫描结果把各页面离屏渲染成 PNG（只有浅色一种外观），供对照设计稿。
/// 只读：不执行任何清理；确认框只是画出来。
@MainActor
enum Snapshot {
    static func run(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let report = Scan().run()
        let shots: [(String, (Store) -> Void)] = [
            ("1-首页", { _ in }),
            ("2-首页-要你说一句", { $0.drawer = .ask }),
            ("3-首页-先不动", { $0.drawer = .keep }),
            ("4-替你挑好的", { $0.page = .picked }),
            ("5-下载", { $0.page = .downloads }),
            ("6-先不动的", { $0.page = .keep }),
            ("7-对话记录", { $0.page = .records }),
            ("8-清理前确认", { $0.confirming = $0.suggestedPicks }),
            ("9-清理后提示", { $0.toast = Toast(text: "移到废纸篓 139 MB（清空后才释放），已释放 897 MB", canUndo: true) }),
            ("10-涨幅-真实记录", { $0.page = .growth }),
            ("11-首页-示例记录", { $0.samples = example(report) }),
            ("12-涨幅-示例记录", { $0.samples = example(report); $0.page = .growth }),
            ("13-提醒设置", { $0.page = .alerts }),
            // 清理完成的彩带，用 11 月 18 日那次真实清理的数字（清理前 5.9 GB，腾出 45.3 GB，6.7 GB 进废纸篓）定格在几个时刻
            ("14-清理完成彩带-示例-0.5秒", { celebrate($0, at: 0.5) }),
            ("15-清理完成彩带-示例-1.3秒", { celebrate($0, at: 1.3) }),
            ("16-清理完成彩带-示例-2.4秒", { celebrate($0, at: 2.4) }),
            ("17-清理完成彩带-示例-放完", { celebrate($0, at: 3.5) }),
            // 顶卡数字和色带可用那段同色：60 GB 以上绿、30 GB 以下红（真实磁盘碰不到时用示例数字看）
            ("18-首页-示例-可用72GB", { freeGB($0, 72) }),
            ("19-首页-示例-可用22GB", { freeGB($0, 22) }),
            // 第 11 批内存页：真实读数（曲线要应用常驻攒），和照 11 月 18 日 13:50 实测编的示例
            ("30-内存-真实", { realMemory($0) }),
            ("31-内存-真实-先不动", { realMemory($0); $0.memDrawer = .keep }),
            ("32-内存-示例", { exampleMemory($0) }),
            ("33-内存-示例-要你说一句", { exampleMemory($0); $0.memDrawer = .ask }),
            ("34-内存-示例-先不动", { exampleMemory($0); $0.memDrawer = .keep }),
            ("35-强制退出-真实", { realMemory($0); $0.page = .forceQuit }),
            ("36-强制退出-示例-点了一下", { exampleMemory($0); $0.page = .forceQuit; $0.forceArmed = "com.google.Chrome@1" }),
            ("37-内存-示例-退出后提示", { exampleMemory($0); $0.toast = Toast(text: "已退出 预览，腾出约 1.2 GB。要用时照常打开", canUndo: false) }),
        ]
        for (name, setup) in shots {
            let store = Store(readOnly: true)
            store.apply(report)
            setup(store)
            let view = PanelView()
                .overlay(alignment: .topTrailing) {
                    // 假记录画出来的图要在画面上标明
                    if name.contains("示例") {
                        Text("示例数据，非真实记录").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.orange)).padding(4)
                    }
                }
                .environmentObject(store)
            let r = ImageRenderer(content: view)
            r.scale = 2
            guard let cg = r.cgImage,
                  let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                print("渲染失败：\(name)")
                continue
            }
            let file = dir.appendingPathComponent("\(name).png")
            try? png.write(to: file)
            print(file.path)
        }
        ball(to: dir)
    }

    static func realMemory(_ store: Store) {
        store.tab = .memory
        store.applyMemory(status: readMemoryStatus(), usage: MemoryAttribution.usage(listProcesses(), apps: RunningApps.current()))
    }

    /// 示例：照 11 月 18 日 13:50 实测的数字编（20 个会话半天没动、Chrome 8 GB、开机 3 天）；
    /// ChatGPT 里会跑 Codex 任务，不挑（审查高 2），一键退出的示例换成两天没用的「预览」
    static func exampleMemory(_ store: Store) {
        let gb = 1_073_741_824.0, now = Date()
        func app(_ pid: Int32, _ name: String, _ id: String, _ path: String) -> RunningApp {
            RunningApp(pid: pid, name: name, bundleID: id, bundlePath: path, launchedAt: now.addingTimeInterval(-3 * 86_400))
        }
        let apps: [(RunningApp, Double)] = [
            (app(1, "Google Chrome", "com.google.Chrome", "/Applications/Google Chrome.app"), 8.0),
            (app(2, "Claude", "com.anthropic.claudefordesktop", "/Applications/Claude.app"), 3.7),
            (app(3, "飞书", "com.bytedance.macos.feishu", "/Applications/飞书.app"), 3.1),
            (app(4, "ChatGPT", "com.openai.codex", "/Applications/ChatGPT.app"), 1.8),
            (app(5, "微信", "com.tencent.xinWeChat", "/Applications/微信.app"), 1.7),
            (app(6, "预览", "com.apple.Preview", "/System/Applications/Preview.app"), 1.2),
        ]
        var sessions: [SessionMemory] = []
        var record = MemoryRecord(trackingSince: now.addingTimeInterval(-2 * 86_400))
        for i in 0..<43 {
            let s = SessionMemory(pid: Int32(100 + i), startedAt: 1, bytes: Int64((i < 20 ? 11.7 / 20 : 6.8 / 23) * gb), cpuNanos: 0)
            sessions.append(s)
            record.sessions[s.key] = ActivityTrack(cpuNanos: 0, at: now, busyAt: now.addingTimeInterval(i < 20 ? -20 * 3600 : -600))
        }
        for (a, _) in apps where a.bundleID != "com.apple.Preview" {
            record.activated(a.bundleID, at: now.addingTimeInterval(a.bundleID == "com.google.Chrome" ? -2 * 3600 : -300))
        }
        record.activated("com.apple.Preview", at: now.addingTimeInterval(-2 * 86_400 - 3600))
        record.apps["com.apple.Preview@6"] = ActivityTrack(cpuNanos: 0, at: now, busyAt: now.addingTimeInterval(-2 * 86_400))
        let curve = [38, 40, 36, 42, 48, 55, 52, 58, 61, 57, 63, 66, 70, 64, 68, 72, 75, 71, 74, 78, 76, 79, 77, 78]
        record.pressure = curve.enumerated().map { PressurePoint(at: now.addingTimeInterval(Double($0.offset - 23) * 3600), usedPercent: $0.element, level: .tight) }
        store.memRecord = record
        store.tab = .memory
        let status = MemoryStatus(totalBytes: Int64(24 * gb), level: .tight, usedPercent: 78, swapUsedBytes: Int64(29.6 * gb),
                                  swapTotalBytes: Int64(30 * gb), bootedAt: now.addingTimeInterval(-(3 * 86_400 + 17 * 3600)))
        store.applyMemory(status: status, usage: MemoryUsage(apps: apps.map { AppMemory(app: $0.0, bytes: Int64($0.1 * gb)) },
                                                             sessions: sessions, vmBytes: Int64(2.5 * gb)))
    }

    /// 把可用空间换成示例数字，总容量不变
    static func freeGB(_ store: Store, _ gb: Double) {
        let total = store.disk?.totalBytes ?? Int64(460 * 1_073_741_824.0)
        store.disk = DiskStatus(totalBytes: total, availableBytes: Int64(gb * 1_073_741_824))
    }

    /// 刚清理完的样子：正在重新扫描、结果还没回来（report 为空），彩带定格在第 `t` 秒
    static func celebrate(_ store: Store, at t: TimeInterval) {
        let gb: Double = 1_073_741_824
        store.report = nil
        store.scanning = true
        // 清理后的数字用现在真实的可用空间；清理前固定写 5.9 GB
        let after = store.disk?.availableBytes ?? Int64(51.2 * gb)
        store.celebration = Celebration(at: Date(), fromBytes: Int64(5.9 * gb), toBytes: after,
                                        freedBytes: Int64(45.3 * gb), trashedBytes: Int64(6.7 * gb))
        store.celebrationFrozenAt = t
        if t >= Celebration.toastDelay {
            store.toast = Toast(text: "已释放 45.3 GB，移到废纸篓 6.7 GB（清空后才释放）", canUndo: true)
        }
    }

    /// 第 8 批：桌面悬浮球各状态（2 倍图）。要用打包版跑才有图标，调试版画的是缺图时的圆
    static func ball(to dir: URL) {
        let gb: Int64 = 1_073_741_824
        let states: [(String, Int64?, Bool)] = [
            ("21-悬浮球-平时", 120 * gb, false),
            ("22-悬浮球-面板打开", 120 * gb, true),
            ("23-悬浮球-低于60GB", 45 * gb, false),
            ("24-悬浮球-低于30GB", 20 * gb, false),
        ]
        for (name, free, expanded) in states {
            let v = BallView(frame: NSRect(x: 0, y: 0, width: FloatGeometry.size, height: FloatGeometry.size))
            v.update(free: free)
            v.expanded = expanded
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 96, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = v.bounds.size
            v.cacheDisplay(in: v.bounds, to: rep)
            let file = dir.appendingPathComponent("\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
            print(file.path)
        }
    }

    /// 示例记录：以这次真实扫描为今天，往前编 6 天（可用空间逐天变少，postpane 构建产物和「其他」在涨）
    static func example(_ report: ScanReport) -> [UsageSample] {
        guard let today = Usage.sample(from: report) else { return [] }
        let gb: Int64 = 1_073_741_824
        let grow = today.parts.keys.first { $0.contains("worktree 构建产物") } ?? "下载文件夹"
        return (0..<7).map { i -> UsageSample in
            let back = Int64(6 - i) // 6 天前 … 今天
            var parts = today.parts
            parts[grow, default: 0] -= back * 2 * gb
            parts["下载文件夹", default: 0] -= back * gb / 4
            let free = today.freeBytes + back * 3 * gb + (i == 3 ? 5 * gb : 0)
            return UsageSample(at: today.at.addingTimeInterval(-Double(back) * 86_400),
                               totalBytes: today.totalBytes, freeBytes: free, parts: parts.mapValues { max(0, $0) })
        }
    }
}

