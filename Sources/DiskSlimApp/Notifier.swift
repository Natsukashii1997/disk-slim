import DiskSlimCore
import Foundation
import UserNotifications

/// 系统通知。只有打包成 .app 运行时才能用（调试版、离屏截图直接跳过：没有 bundle 时系统通知中心会让进程崩溃）。
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    var available: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    private var center: UNUserNotificationCenter? {
        guard available else { return nil }
        let c = UNUserNotificationCenter.current()
        if c.delegate == nil { c.delegate = self }
        return c
    }

    /// 第一次会弹系统授权框；用户不允许就什么都不发
    /// `completion` 的第一个参数表示是否交给了系统（被拒、出错都是 false），第二个是说明
    func send(title: String, body: String, id: String = UUID().uuidString, completion: ((Bool, String) -> Void)? = nil) {
        guard let center else { completion?(false, "不是打包版，跳过通知"); return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            guard granted else { completion?(false, "没有通知权限：\(error?.localizedDescription ?? "用户未允许")"); return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
                completion?(error == nil, error.map { "发送失败：\($0.localizedDescription)" } ?? "已发送：\(title)")
            }
        }
    }

    /// 现在能不能发通知：nil 表示不是打包版或还没问过
    func allowed(_ done: @escaping (Bool?) -> Void) {
        guard let center else { done(nil); return }
        center.getNotificationSettings { s in
            done(s.authorizationStatus == .notDetermined ? nil : s.authorizationStatus == .authorized || s.authorizationStatus == .provisional)
        }
    }

    /// 应用在前台时也显示横幅
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// `DiskSlimApp --test-notify`：用示例数据把每种提醒各发一条，标题都带「示例」；打印结果后退出。只发通知，不扫描、不清理。
    func sendExamples() {
        guard available else { print("要用打包版运行：dist/DiskSlim.app/Contents/MacOS/DiskSlimApp --test-notify"); return }
        let examples: [(String, String)] = [
            ("【示例】磁盘只剩 28.4 GB", "低于 30 GB 了。点侧边的扫帚浮游兽，看看能清什么。（这是测试通知）"),
            ("【示例】postpane · worktree 构建产物 一天涨了 12.3 GB", "点侧边的扫帚浮游兽 › 涨幅，看看是谁。（这是测试通知）"),
            ("【示例】本周瘦身：4 件待决定", "一共能腾出 3.2 GB。点侧边的扫帚浮游兽，逐件决定。（这是测试通知）"),
            ("【示例】自动清理腾出了 1.4 GB", "清了 3 项缓存。（这是测试通知，没有清理任何东西）"),
        ]
        let done = DispatchSemaphore(value: 0)
        for (i, e) in examples.enumerated() {
            send(title: e.0, body: e.1, id: "example-\(i)") { print($1); done.signal() }
            done.wait()
        }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            print("通知权限：\(s.authorizationStatus == .authorized ? "已允许" : s.authorizationStatus == .denied ? "已拒绝" : "未决定")")
            done.signal()
        }
        done.wait()
    }
}
