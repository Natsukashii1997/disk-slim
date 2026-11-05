import Foundation

/// 一次完整扫描：下载区 + worktree 构建产物 + 已知位置。
public struct Scan {
    public var home: URL
    public var workRoot: URL
    public var meta: FileMetadata
    public var runner: CommandRunner

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                workRoot: URL? = nil,
                meta: FileMetadata = SpotlightMetadata(),
                runner: CommandRunner = ProcessRunner()) {
        self.home = home
        self.workRoot = workRoot ?? home.appendingPathComponent("Documents/ChatGPT/个人/work")
        self.meta = meta
        self.runner = runner
    }

    public func run(now: Date = Date()) -> ScanReport {
        let start = Date()
        let findings =
            DownloadsScanner(root: home.appendingPathComponent("Downloads"), now: now, meta: meta).scan()
            + WorktreeScanner(workRoot: workRoot, now: now, runner: runner).scan()
            + applyHistory(KnownPlacesScanner(home: home).scan(), history: OperationLog.standard(home: home).load(), now: now)
        return ScanReport(scannedAt: now, seconds: Date().timeIntervalSince(start),
                          disk: diskStatus(of: home), findings: findings)
    }

    /// 执行前复核会随时间变化的规则：扫描后又标了「保留」的下载项、扫描后又编译过的构建产物。
    public func recheck(_ f: Finding, now: Date = Date()) -> String? {
        let urls = f.paths.map { URL(fileURLWithPath: $0) }
        if f.area == .downloads, urls.contains(where: { meta.tags($0).contains(DownloadsRules().keepTag) }) {
            return "扫描后标了「保留」，这次不清"
        }
        if f.cleanup == .remove, urls.contains(where: { $0.path.hasPrefix(workRoot.path + "/") && WorktreeScanner.recentlyBuilt($0, now: now) }) {
            return "扫描后又编译过，这次不删"
        }
        return nil
    }

    /// 命令行和菜单栏应用共用的清理器。`sandbox` 为 true 时不运行清理命令（它们作用在真实电脑上）。
    public func cleaner(sandbox: Bool = false) -> Cleaner {
        Cleaner(safety: SafetyGuard(home: home, workRoot: workRoot), runner: runner, log: .standard(home: home),
                recheck: { self.recheck($0) }, allowCommands: !sandbox)
    }
}
