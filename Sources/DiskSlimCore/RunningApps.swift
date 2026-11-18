import AppKit

public enum RunningApps {
    /// 程序坞里那种普通应用（菜单栏小工具、后台服务不算）
    public static func current() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { a in
            guard a.activationPolicy == .regular, let id = a.bundleIdentifier, !a.isTerminated else { return nil }
            return RunningApp(pid: a.processIdentifier, name: a.localizedName ?? id, bundleID: id,
                              bundlePath: a.bundleURL?.path ?? "", active: a.isActive, launchedAt: a.launchDate)
        }
    }
}
