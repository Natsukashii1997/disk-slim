import Foundation

/// 下载文件夹规则（docs/PRD.md 4.1）。
public struct DownloadsRules {
    public var installerDays = 7.0
    public var staleDays = 30.0
    public var recentDays = 7.0
    public var bigBytes: Int64 = 300 * 1_048_576
    public var keepTag = "保留"
    public init() {}
}

private let installerExts: Set<String> = ["dmg", "pkg"]
/// 先长后短，「.tar.gz」要先于「.gz」匹配
private let archiveSuffixes = [".tar.gz", ".tgz", ".zip", ".rar", ".7z", ".tar", ".gz"]

public struct DownloadsScanner {
    let root: URL
    let now: Date
    let meta: FileMetadata
    let rules: DownloadsRules

    public init(root: URL, now: Date, meta: FileMetadata, rules: DownloadsRules = DownloadsRules()) {
        self.root = root
        self.now = now
        self.meta = meta
        self.rules = rules
    }

    /// 只看下载文件夹第一层；每个文件或文件夹最多归入一类，按 安装包 → 已解压 → 久未打开 → 最近大文件 的顺序判断。
    public func scan() -> [Finding] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap(classify)
    }

    private func days(since date: Date) -> Double { now.timeIntervalSince(date) / 86_400 }

    private func classify(_ url: URL) -> Finding? {
        if meta.tags(url).contains(rules.keepTag) { return nil }
        let name = url.lastPathComponent
        let added = meta.dateAdded(url)
            ?? (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            ?? now
        let opened = meta.lastUsed(url)

        func finding(_ category: String, _ detail: String, suggested: Bool, bytes: Int64? = nil,
                     cleanup: Cleanup = .trash) -> Finding {
            Finding(area: .downloads, category: category, title: name, detail: detail,
                    paths: [url.path], bytes: bytes ?? allocatedSize(url),
                    risk: .safe, suggested: suggested, cleanup: cleanup)
        }
        let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true

        if installerExts.contains(url.pathExtension.lowercased()), days(since: added) > rules.installerDays {
            return finding("安装包", "\(BeijingTime.monthDay(added)) 下载，装完就用不上了", suggested: true)
        }

        // 只认普通文件：名字以 .zip 结尾的文件夹不是压缩包
        if isFile, let stem = archiveStem(name) {
            var isDir: ObjCBool = false
            let sibling = root.appendingPathComponent(stem)
            if FileManager.default.fileExists(atPath: sibling.path, isDirectory: &isDir), isDir.boolValue {
                return finding("已解压的压缩包", "旁边已有解压好的文件夹「\(stem)」", suggested: true)
            }
        }

        if days(since: opened ?? added) > rules.staleDays {
            let detail = opened.map { "上次打开 \(BeijingTime.monthDay($0))" }
                ?? "\(BeijingTime.monthDay(added)) 下载，没打开过"
            return finding("久未打开", detail, suggested: false)
        }

        if days(since: added) <= rules.recentDays {
            let bytes = allocatedSize(url)
            if bytes > rules.bigBytes {
                // PRD 4.1：只提示，不能勾选；要删请自己判断
                return finding("最近下载的大文件", "\(BeijingTime.monthDay(added)) 下载，只提示，要删请自己判断",
                               suggested: false, bytes: bytes, cleanup: .none)
            }
        }
        return nil
    }

    private func archiveStem(_ name: String) -> String? {
        let lower = name.lowercased()
        guard let suffix = archiveSuffixes.first(where: { lower.hasSuffix($0) }) else { return nil }
        let stem = String(name.dropLast(suffix.count))
        return stem.isEmpty ? nil : stem
    }
}
