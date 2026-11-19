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
        let findings = applyDecisions(
            DownloadsScanner(root: home.appendingPathComponent("Downloads"), now: now, meta: meta).scan()
            + WorktreeScanner(workRoot: workRoot, now: now, runner: runner).scan()
            + applyHistory(KnownPlacesScanner(home: home, now: now).scan(), history: OperationLog.standard(home: home).load(readOnly: true), now: now),
            DecisionLog.standard(home: home).load(readOnly: true))
        let downloads = home.appendingPathComponent("Downloads")
        return ScanReport(scannedAt: now, seconds: Date().timeIntervalSince(start),
                          disk: diskStatus(of: home), findings: findings,
                          downloadsBytes: FileManager.default.fileExists(atPath: downloads.path) ? allocatedSizeIfReadable(downloads) : nil,
                          trashBytes: allocatedSizeIfReadable(home.appendingPathComponent(".Trash")),
                          needsAccess: [("下载文件夹", downloads), ("废纸篓", home.appendingPathComponent(".Trash"))]
                            .filter { blockedByPrivacy($0.1) }.map(\.0))
    }

    /// 执行前复核会随时间变化的规则：扫描后又标了「保留」的下载项、扫描后又编译过的构建产物。
    public func recheck(_ f: Finding, now: Date = Date()) -> String? {
        let urls = f.paths.map { URL(fileURLWithPath: $0) }
        if f.area == .downloads, urls.contains(where: { meta.tags($0).contains(DownloadsRules().keepTag) }) {
            return "扫描后标了「保留」，这次不清"
        }
        // worktree 构建产物：执行前把「正在用」再判一遍（扫描和清理之间可能过了很久）
        if f.cleanup == .remove {
            for target in urls where target.path.hasPrefix(workRoot.path + "/") && target.lastPathComponent == "target" {
                let wt = target.deletingLastPathComponent()
                let project = wt.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let reasons = WorktreeScanner.inUse(wt, target: target, locked: WorktreeScanner.lockedWorktrees(project, runner: runner),
                                                    openPaths: WorktreeScanner.recentOpenPaths(runner, now: now), processes: "", now: now)
                if !reasons.isEmpty { return "扫描后情况变了（\(reasons.joined(separator: "、"))），这次不删" }
            }
        }
        return nil
    }

    /// 命令行和桌面应用共用的清理器。`sandbox` 为 true 时不运行清理命令（它们作用在真实电脑上）。
    public func cleaner(sandbox: Bool = false) -> Cleaner {
        Cleaner(safety: SafetyGuard(home: home, workRoot: workRoot), runner: runner, log: .standard(home: home),
                recheck: { self.recheck($0) }, allowCommands: !sandbox)
    }
}
