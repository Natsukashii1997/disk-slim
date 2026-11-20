import Foundation

// 第 11 批：内存页的阈值和应用名单（docs/PRD.md 4.4）。

public enum MemoryRules {
    public static let mb: Int64 = 1_048_576
    public static let gb: Int64 = 1_073_741_824
    /// 替你挑好的：占 300 MB 以上、4 小时没切到前台
    public static let pickMin: Int64 = 300 * mb
    public static let pickIdle: TimeInterval = 4 * 3600
    /// 30 分钟内用过的算「你正在用」
    public static let recent: TimeInterval = 30 * 60
    /// 浏览器占 1 GB 以上、30 分钟没用：要你说一句（退出要靠恢复标签页）
    public static let browserMin: Int64 = 1 * gb
    /// Claude Code 会话 12 小时没忙过算闲着
    public static let sessionIdle: TimeInterval = 12 * 3600
    public static let busyCPU = 0.05
    /// 两次采样隔了 15 分钟以上就看不准忙闲，当忙过
    public static let longGap: TimeInterval = 15 * 60
    /// 交换文件 8 GB 以上、开机 3 天以上：提醒重启
    public static let restartSwap: Int64 = 8 * gb
    public static let restartUptime: TimeInterval = 3 * 86_400
    public static let curveWindow: TimeInterval = 24 * 3600

    /// 「今晚提醒我」：北京时间今天 22:00；已经过了就一小时后
    public static func tonight(_ now: Date) -> Date {
        let ten = Date(timeIntervalSince1970: TimeInterval(BeijingTime.dayNumber(now)) * 86_400 - 8 * 3600 + 22 * 3600)
        return ten > now ? ten : now.addingTimeInterval(3600)
    }

    /// 要收消息的
    static let messaging: Set<String> = [
        "com.tencent.xinWeChat", "com.bytedance.macos.feishu", "com.electron.lark", "com.alibaba.DingTalkMac", "com.tencent.qq",
        "com.tencent.WeWorkMac", "com.apple.MobileSMS", "com.apple.mail", "com.tinyspeck.slackmacgap", "ru.keepcoder.Telegram",
        "com.microsoft.teams2", "us.zoom.xos",
    ]
    /// 可能有命令或程序在跑的
    static let working: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode", "dev.zed.Zed", "com.sublimetext.4",
        // ChatGPT 桌面版的 bundle id 就是 com.openai.codex，里面会跑 Codex 任务（审查高 2）
        "com.openai.codex", "com.docker.docker", "dev.orbstack.OrbStack", "com.utmapp.UTM", "com.obsproject.obs-studio",
        "com.parallels.desktop.console", "com.vmware.fusion",
    ]
    static func isWorking(_ id: String) -> Bool { working.contains(id) || id.hasPrefix("com.jetbrains.") }
    /// 可能在放声音的
    static let media: Set<String> = ["com.apple.Music", "com.spotify.client", "com.netease.163music", "com.tencent.QQMusicMac", "com.apple.podcasts"]
    static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac", "company.thebrowser.Browser", "org.mozilla.firefox", "com.brave.Browser",
    ]
    static let claudeDesktop = "com.anthropic.claudefordesktop"
    static let appleDocApps: Set<String> = ["com.apple.Preview", "com.apple.TextEdit", "com.apple.iWork.Pages", "com.apple.iWork.Numbers", "com.apple.iWork.Keynote"]
    /// 系统自己的、磁盘瘦身自己、驿窗（挂件在用）
    static let never: Set<String> = ["com.apple.finder", "local.nat.disk-slim", "app.postpane.mac", "com.apple.systempreferences"]
}
