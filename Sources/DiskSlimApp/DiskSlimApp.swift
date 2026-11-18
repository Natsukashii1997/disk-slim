import AppKit
import DiskSlimCore
import SwiftUI

let isTestNotify = CommandLine.arguments.contains("--test-notify")

@main
struct DiskSlimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store(readOnly: isTestNotify)

    init() {
        // 自测用：离屏把每个页面渲染成 PNG，然后退出，不弹任何窗口
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Snapshot.run(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(store)
                .onAppear { store.page = .home; store.drawer = nil; store.confirming = nil; store.tab = .disk; store.memDrawer = nil; store.scanIfStale(); store.refreshMemory() }
        } label: {
            MenuBarLabel(disk: store.disk)
                .task {
                    // 桌面悬浮球（第 8 批）：示例通知自测时不出现
                    if !isTestNotify { FloatingBall.shared.start(store: store) }
                    await store.dailyLoop()
                }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var termSource: DispatchSourceSignal?

    /// 正在清理时不退出：操作记录要等整批做完才写，半途退出会丢掉撤销记录
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if MainActor.assumeIsolated({ Store.main?.working == true }) {
            MainActor.assumeIsolated { Store.main?.toast = Toast(text: "正在清理，清完再退出。", canUndo: false) }
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
        // 放在应用启动后、后台线程里等授权，不卡主线程；这时 Store 是只读的，不扫描、不写记录
        if isTestNotify {
            DispatchQueue.global().async {
                Notifier.shared.sendExamples()
                DispatchQueue.main.async { exit(0) }
            }
        }
    }
}

/// 菜单栏上的图标和剩余 GB。低于 60 GB 换成提醒图标，低于 30 GB 换成警告图标。
struct MenuBarLabel: View {
    let disk: DiskStatus?

    var body: some View {
        let gb = disk.map { Double($0.availableBytes) / 1_073_741_824 }
        HStack(spacing: 3) {
            Image(systemName: icon(gb))
            Text(gb.map { "\(Int($0))G" } ?? "—").monospacedDigit()
        }
    }

    private func icon(_ gb: Double?) -> String {
        guard let gb else { return "internaldrive" }
        return gb < 30 ? "exclamationmark.triangle.fill" : gb < 60 ? "exclamationmark.circle" : "internaldrive"
    }
}
