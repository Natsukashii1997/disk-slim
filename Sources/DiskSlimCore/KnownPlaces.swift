import Foundation

/// 已知位置：包管理器缓存（安全）、备份与虚拟机（需确认）、对话记录（只展示）。docs/PRD.md 4.2。
public struct Place {
    public let category: String
    public let title: String
    /// 相对主目录的路径；多个路径合成一项
    public let paths: [String]
    public let risk: Risk
    public let suggested: Bool
    public let cleanup: Cleanup
    public let detail: String
    /// 每个子目录各算一项（如 Codex 的多份备份）
    public let perChild: Bool
    /// 进程命令行里出现这些字样时先不清（例如 Homebrew 正在下载）
    public let busyWhen: [String]
    /// 按份的备份：最新一份留着保底，超过 `Finding.unusedDays` 天的旧份默认勾选（2026-11-18 常浩定，issue #4）
    public let keepNewest: Bool
    /// 记最近一次用过的时间（虚拟机）：一个月没用才问用户
    public let trackUse: Bool

    public init(_ category: String, _ title: String, _ paths: [String], risk: Risk, suggested: Bool = false,
                cleanup: Cleanup = .none, detail: String, perChild: Bool = false, busyWhen: [String] = [],
                keepNewest: Bool = false, trackUse: Bool = false) {
        self.category = category
        self.title = title
        self.paths = paths
        self.risk = risk
        self.suggested = suggested
        self.cleanup = cleanup
        self.detail = detail
        self.perChild = perChild
        self.busyWhen = busyWhen
        self.keepNewest = keepNewest
        self.trackUse = trackUse
    }
}

public enum KnownPlaces {
    public static let all: [Place] = [
        // 安全：可再生，默认勾选
        // `npm cache clean` 只清 _cacache；_npx 另列在下面
        Place("包管理器缓存", "npm 缓存", [".npm/_cacache"], risk: .safe, suggested: true,
              cleanup: .command(["npm", "cache", "clean", "--force"]), detail: "下次安装时会重新下载"),
        Place("包管理器缓存", "uv 缓存", [".cache/uv"], risk: .safe, suggested: true,
              cleanup: .command(["uv", "cache", "clean"]), detail: "下次安装时会重新下载"),
        Place("包管理器缓存", "pnpm 存储", ["Library/pnpm/store"], risk: .safe, suggested: true,
              cleanup: .command(["pnpm", "store", "prune"]), detail: "只删没有项目引用的包"),
        // 不用 `brew cleanup`：它还会删已安装软件的旧版本、自动卸载没人依赖的软件，都不能撤销（L-06）。
        // 只删下载缓存，下次安装时重新下载
        Place("包管理器缓存", "Homebrew 下载缓存", ["Library/Caches/Homebrew/downloads"], risk: .safe, suggested: true,
              cleanup: .remove, detail: "下次安装时会重新下载", busyWhen: ["Homebrew/brew.rb"]),
        Place("包管理器缓存", "pip 缓存", ["Library/Caches/pip"], risk: .safe, suggested: true,
              cleanup: .command(["pip3", "cache", "purge"]), detail: "下次安装时会重新下载"),
        Place("测试用浏览器", "Playwright 浏览器", ["Library/Caches/ms-playwright"], risk: .safe, suggested: true,
              cleanup: .remove, detail: "下次跑测试时会自动重新下载"),
        Place("测试用浏览器", "Puppeteer 浏览器", [".cache/puppeteer"], risk: .safe, suggested: true,
              cleanup: .remove, detail: "下次跑测试时会自动重新下载"),

        // 需确认：不默认勾选
        Place("包管理器缓存", "npx 运行过的工具", [".npm/_npx"], risk: .confirm, cleanup: .trash,
              detail: "下次运行会重新下载；有些 MCP 服务正靠它运行，先关掉 Claude、Codex 再清"),
        Place("备份快照", "Codex 备份", [".codex/recovery"], risk: .confirm,
              cleanup: .trash, detail: "你自己做的备份", perChild: true, keepNewest: true),
        Place("虚拟机", "Colima 虚拟机", [".colima"], risk: .confirm,
              detail: "不用了请在终端运行 colima delete <名称>", trackUse: true),
        Place("虚拟机", "Cowork 虚拟机", ["Library/Application Support/Claude/vm_bundles"], risk: .confirm,
              detail: "由 Claude 应用管理，在 Claude 设置 › 存储里处理", trackUse: true),

        // 只展示：工具永不删除
        Place("对话记录", "Claude 对话记录", [".claude/projects"], risk: .readOnly, detail: "删了就找不回"),
        Place("对话记录", "Codex 对话记录", [".codex/sessions", ".codex/archived_sessions"], risk: .readOnly,
              detail: "删了就找不回；要清请在 Codex 里操作"),
    ]
}

public struct KnownPlacesScanner {
    let home: URL
    let places: [Place]
    /// 小于这个大小的不列出，免得一堆几 MB 的噪音
    let minBytes: Int64
    let sizeOf: (URL) -> Int64
    let now: Date
    /// 一个目录最近一次变动：它和往下两层里最新的修改时间
    let modifiedAt: (URL) -> Date?

    public init(home: URL, places: [Place] = KnownPlaces.all, minBytes: Int64 = 50 * 1_048_576,
                sizeOf: @escaping (URL) -> Int64 = allocatedSize, now: Date = Date(),
                modifiedAt: @escaping (URL) -> Date? = latestModification) {
        self.home = home
        self.places = places
        self.minBytes = minBytes
        self.sizeOf = sizeOf
        self.now = now
        self.modifiedAt = modifiedAt
    }

    public func scan() -> [Finding] {
        let fm = FileManager.default
        var found: [Finding] = []
        for place in places {
            // 位置本身或中间某层是符号链接的不看，免得顺着链接把别处的东西列进来
            let urls = place.paths.map { home.appendingPathComponent($0) }
                .filter { fm.fileExists(atPath: $0.path) && !hasSymlink($0.path, under: home) }
            if urls.isEmpty { continue }

            if place.perChild {
                let children = urls.flatMap {
                    ((try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                }.sorted { $0.lastPathComponent > $1.lastPathComponent }
                    .map { (url: $0, bytes: sizeOf($0), at: modifiedAt($0)) }.filter { $0.bytes >= minBytes }
                // 最新一份按修改时间认（名字前缀各不相同，按名字排不出先后）
                let newest = children.max { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }?.url
                for child in children {
                    var suggested = place.suggested, detail = place.detail
                    if place.keepNewest {
                        let day = child.at.map(BeijingTime.monthDay) ?? "日期不明"
                        if child.url == newest {
                            suggested = false; detail = "\(day)的，最新一份，留着保底"
                        } else if let at = child.at, now.timeIntervalSince(at) > Double(Finding.unusedDays) * 86_400 {
                            suggested = true; detail = "\(day)的旧备份，一个多月来 Codex 一直正常，留最新一份就够"
                        } else {
                            suggested = false; detail = child.at == nil ? "看不出是哪天的，先留着" : "\(day)的，一个月内做的，先留着"
                        }
                    }
                    found.append(Finding(area: .hidden, category: place.category,
                                         title: "\(place.title) · \(child.url.lastPathComponent)", detail: detail,
                                         paths: [child.url.path], bytes: child.bytes, risk: place.risk,
                                         suggested: suggested, cleanup: place.cleanup))
                }
            } else {
                let bytes = urls.reduce(Int64(0)) { $0 + sizeOf($1) }
                if bytes < minBytes { continue }
                var detail = place.detail, used: Date?
                if place.trackUse {
                    used = urls.compactMap(modifiedAt).max()
                    if let used {
                        let days = Int(now.timeIntervalSince(used) / 86_400)
                        detail = days > Finding.unusedDays ? "\(days) 天没用了。\(place.detail)" : "\(BeijingTime.monthDay(used))还用过，先留着"
                    }
                }
                found.append(Finding(area: .hidden, category: place.category, title: place.title,
                                     detail: detail, paths: urls.map(\.path), bytes: bytes,
                                     risk: place.risk, suggested: place.suggested, cleanup: place.cleanup, lastUsed: used))
            }
        }
        return found
    }
}

/// 目录和往下两层里最新的修改时间（虚拟机的磁盘文件、配置在第一二层；不往深处走，免得扫整个镜像）
public func latestModification(_ url: URL) -> Date? {
    let keys: Set<URLResourceKey> = [.contentModificationDateKey]
    var latest = (try? url.resourceValues(forKeys: keys))?.contentModificationDate
    guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [],
                                                 errorHandler: { _, _ in true }) else { return latest }
    for case let u as URL in e {
        if e.level >= 2 { e.skipDescendants() }
        if let d = (try? u.resourceValues(forKeys: keys))?.contentModificationDate, d > (latest ?? .distantPast) { latest = d }
    }
    return latest
}
