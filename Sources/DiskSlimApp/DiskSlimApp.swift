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
                .onAppear { store.page = .home; store.scanIfStale() }
        } label: {
            MenuBarLabel(disk: store.disk)
                .task { await store.dailyLoop() }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
