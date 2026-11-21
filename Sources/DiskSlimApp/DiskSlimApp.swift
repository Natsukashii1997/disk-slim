import AppKit
import DiskSlimCore
import SwiftUI

let isTestNotify = CommandLine.arguments.contains("--test-notify")

/// 2026-11-19 常浩定：不要菜单栏图标，入口只留驿窗侧栏的扫帚浮游兽挂件（和默认关着的桌面悬浮球）。
/// 不用 SwiftUI 的 App：它至少要一个场景，放个空的设置场景占位，启动时会自己弹出一个透明的「Settings」窗口挡在屏幕中间（2026-11-19 真屏实测）
@main
enum DiskSlimMain {
    /// NSApplication 只弱引用 delegate，这里留住
    private static let delegate = AppDelegate()

    @MainActor static func main() {
        let app = NSApplication.shared
        // 自测用：离屏把每个页面渲染成 PNG，然后退出，不弹任何窗口
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Snapshot.run(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            exit(0)
        }
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var termSource: DispatchSourceSignal?
    /// 应用唯一的数据（面板、悬浮球、驿窗挂件共用）。启动完才建：离屏截图在 App.init 里就退出了，不该碰真实记录
    private var store: Store?

    /// 正在清理时不退出：操作记录每清完一项才写一次，半途退出，正在清的那一项可能记不下、撤销不了
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if MainActor.assumeIsolated({ Store.main?.working == true }) {
            MainActor.assumeIsolated { Store.main?.ui.toast = Toast(text: "正在清理，清完再退出。", canUndo: false) }
            return .terminateCancel
        }
        // 面板开着就退出时先收起，状态文件写回 panelOpen false，驿窗挂件的光圈才会熄
        MainActor.assumeIsolated { FloatingBall.shared.closePanel() }
        return .terminateNow
    }

    /// 第 9 批：驿窗挂件被点时发来 diskslim://panel/toggle?x=…（挂件的位置，主屏左上原点）。
    /// 应用没开着时 LaunchServices 先启动它再转交，悬浮球还没启动就先记下
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let primary = NSScreen.screens.first?.frame.height else { return }
        for url in urls {
            guard let anchor = PanelLink.anchor(from: url) else { continue }
            MainActor.assumeIsolated {
                FloatingBall.shared.toggle(from: PanelLink.appKitRect(anchor, primaryHeight: primary))
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 安装脚本用 SIGTERM 请它退出：走正常退出流程（正在清理时会拒绝），不被直接杀掉
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSource = source
        // 不在程序坞显示（打包后 Info.plist 的 LSUIElement 也会保证这一点）
        NSApp.setActivationPolicy(.accessory)
        // 自测用：用示例数据把每种提醒各发一条系统通知，然后退出（要用打包版运行）。
        // 放在应用启动后、后台线程里等授权，不卡主线程；不建 Store，不扫描、不写记录
        if isTestNotify {
            DispatchQueue.global().async {
                Notifier.shared.sendExamples()
                DispatchQueue.main.async { exit(0) }
            }
            return
        }
        MainActor.assumeIsolated {
            let store = Store(readOnly: false)
            self.store = store
            // 桌面悬浮球（第 8 批）和驿窗挂件叫开的面板都挂在这里；链接比这里先到时由 FloatingBall 先记下
            FloatingBall.shared.start(store: store)
            Task { @MainActor in await store.dailyLoop() }
        }
    }
}
