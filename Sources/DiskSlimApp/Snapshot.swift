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
        ]
        for (name, setup) in shots {
            for scheme in [ColorScheme.light, .dark] {
                let store = Store()
                store.apply(report)
                setup(store)
                let view = PanelView()
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
}
