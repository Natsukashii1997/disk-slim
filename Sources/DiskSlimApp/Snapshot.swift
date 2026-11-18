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

