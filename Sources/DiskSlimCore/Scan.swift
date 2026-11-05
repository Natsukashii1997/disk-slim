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
            + KnownPlacesScanner(home: home).scan()
        return ScanReport(scannedAt: now, seconds: Date().timeIntervalSince(start),
                          disk: diskStatus(of: home), findings: findings)
    }
}
