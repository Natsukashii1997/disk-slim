import Foundation

/// 分组名：给人看的中文文案，界面按它分组，也写进 `scan --json`。
/// 只在这里写一遍：扫描器取这里的常量；判断「这一项是什么」一律用 `Finding.kind`，不拿文案去比
/// （改文案只动这里，逻辑不受影响；`FindingKindTests` 逐字锁着）
public enum Category {
    // 下载文件夹
    public static let installer = "安装包"
    public static let extractedArchive = "已解压的压缩包"
    public static let staleDownload = "久未打开"
    public static let recentBigDownload = "最近下载的大文件"
    // worktree 构建产物的三种状态
    public static let landedBuild = "已合并 worktree 的构建产物"
    public static let activeBuild = "还在做的 worktree 构建产物"
    public static let blockedBuild = "暂时不能清的构建产物"
    // 已知位置
    public static let packageCache = "包管理器缓存"
    public static let testBrowser = "测试用浏览器"
    public static let backup = "备份快照"
    public static let vm = "虚拟机"
    public static let records = "对话记录"
}

extension Finding {
    /// 这一项是什么东西。由分组名算出来，不进 JSON
    public enum Kind: Equatable {
        case installer, extractedArchive, staleDownload, recentBigDownload
        /// worktree 的 `target/`，三种状态（已合并 / 还在做 / 暂时不能清）都是它
        case worktreeBuild
        case packageCache, testBrowser, backup, vm, records
        case other
    }

    public var kind: Kind {
        switch category {
        case Category.installer: .installer
        case Category.extractedArchive: .extractedArchive
        case Category.staleDownload: .staleDownload
        case Category.recentBigDownload: .recentBigDownload
        case Category.landedBuild, Category.activeBuild, Category.blockedBuild: .worktreeBuild
        case Category.packageCache: .packageCache
        case Category.testBrowser: .testBrowser
        case Category.backup: .backup
        case Category.vm: .vm
        case Category.records: .records
        default: .other
        }
    }

    /// worktree 构建产物属于哪个项目：标题是「项目 · worktree」，项目名里也可能带「 · 」，所以按最后一个切
    public var worktreeProject: String {
        title.range(of: " · ", options: .backwards).map { String(title[..<$0.lowerBound]) } ?? title
    }
}

// MARK: - 给人看的名字

/// 首页列表里给人看的名字：worktree 编译文件写成「AI 编译文件 · 项目」
public func friendlyName(_ f: Finding) -> String {
    switch f.kind {
    case .worktreeBuild: "AI 编译文件 · \(f.worktreeProject)"
    // 备份文件夹名很长，日期已经写在说明里
    case .backup: "Codex 备份"
    default: f.title
    }
}

/// 「替你挑好的」按用途合并成几行
public func pickedLabel(_ f: Finding) -> String {
    if f.area == .downloads {
        return switch f.kind {
        case .installer: "下载里装好的安装包"
        case .extractedArchive: "下载里解压过的压缩包"
        default: "下载里的\(f.category)"
        }
    }
    return switch f.kind {
    case .worktreeBuild: "AI 写代码编出来的文件"
    case .backup: "Codex 旧备份"
    case .packageCache: "下载缓存"
    default: f.category
    }
}
