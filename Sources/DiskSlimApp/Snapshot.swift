import AppKit
import DiskSlimCore
import SwiftUI

/// `DiskSlim --snapshot <目录>`：用真实扫描结果把各页面（浅色、深色）离屏渲染成 PNG，供对照设计稿。
/// 只读：不执行任何清理；确认框只是画出来。
@MainActor
enum Snapshot {
    static func run(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let report = Scan().run()
        let shots: [(String, (Store) -> Void)] = [
            ("1-首页", { _ in }),
            ("2-下载", { $0.page = .downloads }),
            ("3-缓存与构建产物", { $0.page = .caches }),
            ("4-要你决定", { $0.page = .decide }),
            ("5-对话记录", { $0.page = .records }),
            ("6-清理前确认", { $0.confirming = $0.suggestedPicks }),
            ("7-清理后提示", { $0.toast = Toast(text: "移到废纸篓 139 MB（清空后才释放），已释放 897 MB", canUndo: true) }),
            ("8-涨幅-真实记录", { $0.page = .growth }),
            ("9-首页-示例记录", { $0.samples = example(report) }),
            ("10-涨幅-示例记录", { $0.samples = example(report); $0.page = .growth }),
            ("11-本周待决定", { $0.page = .week }),
            ("12-提醒设置", { $0.page = .alerts }),
        ]
        for (name, setup) in shots {
            for scheme in [ColorScheme.light, .dark] {
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
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme)
                let r = ImageRenderer(content: view)
                r.scale = 2
                guard let cg = r.cgImage,
                      let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                    print("渲染失败：\(name)")
                    continue
                }
                let file = dir.appendingPathComponent("\(name)-\(scheme == .dark ? "深色" : "浅色").png")
                try? png.write(to: file)
                print(file.path)
            }
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

