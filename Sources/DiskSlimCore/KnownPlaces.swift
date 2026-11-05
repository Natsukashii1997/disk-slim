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

    public init(_ category: String, _ title: String, _ paths: [String], risk: Risk, suggested: Bool = false,
                cleanup: Cleanup = .none, detail: String, perChild: Bool = false, busyWhen: [String] = []) {
        self.category = category
        self.title = title
        self.paths = paths
        self.risk = risk
        self.suggested = suggested
        self.cleanup = cleanup
        self.detail = detail
        self.perChild = perChild
        self.busyWhen = busyWhen
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
              cleanup: .trash, detail: "你自己做的备份；Codex 用着正常的话，可以只留最新一份", perChild: true),
        Place("虚拟机", "Colima 虚拟机", [".colima"], risk: .confirm,
              detail: "不用了请在终端运行 colima delete <名称>"),
        Place("虚拟机", "Cowork 虚拟机", ["Library/Application Support/Claude/vm_bundles"], risk: .confirm,
              detail: "由 Claude 应用管理，在 Claude 设置 › 存储里处理"),

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

    public init(home: URL, places: [Place] = KnownPlaces.all, minBytes: Int64 = 50 * 1_048_576,
                sizeOf: @escaping (URL) -> Int64 = allocatedSize) {
        self.home = home
        self.places = places
        self.minBytes = minBytes
        self.sizeOf = sizeOf
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
                for child in children {
                    let bytes = sizeOf(child)
                    if bytes < minBytes { continue }
                    found.append(Finding(area: .hidden, category: place.category,
                                         title: "\(place.title) · \(child.lastPathComponent)", detail: place.detail,
                                         paths: [child.path], bytes: bytes, risk: place.risk,
                                         suggested: place.suggested, cleanup: place.cleanup))
                }
            } else {
                let bytes = urls.reduce(Int64(0)) { $0 + sizeOf($1) }
                if bytes < minBytes { continue }
                found.append(Finding(area: .hidden, category: place.category, title: place.title,
                                     detail: place.detail, paths: urls.map(\.path), bytes: bytes,
                                     risk: place.risk, suggested: place.suggested, cleanup: place.cleanup))
            }
        }
        return found
    }
}
