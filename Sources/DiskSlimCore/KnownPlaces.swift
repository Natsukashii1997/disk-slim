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
    /// 有这些程序在干活时先不清（例如 Homebrew 正在下载、npm 正在装依赖）
    public let busyWhen: [Busy]
    /// 按份的备份：最新一份留着保底，超过 `Finding.unusedDays` 天的旧份默认勾选（2026-11-18 常浩定，issue #4）
    public let keepNewest: Bool
    /// 记最近一次用过的时间（虚拟机）：一个月没用才问用户
    public let trackUse: Bool

    public init(_ category: String, _ title: String, _ paths: [String], risk: Risk, suggested: Bool = false,
                cleanup: Cleanup = .none, detail: String, perChild: Bool = false, busyWhen: [Busy] = [],
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
        // npm、pnpm、pip 的 busyWhen 只认「正在装依赖」的子命令（含别名）：本机常年挂着几十个 `npm exec …` 起的 MCP 服务，
        // 写成「npm 在跑就不清」等于永远清不了；`pnpm dlx` 同理不列。
        // uv 不一样：任何 uv 进程（含常驻的 `uv run`、uvx 服务）都占着缓存锁，这时 `uv cache clean` 会一直等到超时
        // （2026-11-20 用隔离缓存目录实测，uv 0.11.7），所以只要有 uv 在跑就先不清；不加 `--force`，它会删掉正在用的环境
        // `npm cache clean` 只清 _cacache；_npx 另列在下面
        Place("包管理器缓存", "npm 缓存", [".npm/_cacache"], risk: .safe, suggested: true,
              cleanup: .command(["npm", "cache", "clean", "--force"]), detail: "下次安装时会重新下载",
              busyWhen: [Busy("npm", ["install", "add", "i", "in", "ins", "inst", "insta", "instal", "isnt", "isnta", "isntal", "isntall",
                                    "ci", "clean-install", "ic", "install-clean", "it", "install-test", "cit", "install-ci-test",
                                    "update", "up", "upgrade", "udpate", "dedupe", "ddp"])]),
        Place("包管理器缓存", "uv 缓存", [".cache/uv"], risk: .safe, suggested: true,
              cleanup: .command(["uv", "cache", "clean"]), detail: "下次安装时会重新下载",
              busyWhen: [Busy("uv"), Busy("uvx")]),
        Place("包管理器缓存", "pnpm 存储", ["Library/pnpm/store"], risk: .safe, suggested: true,
              cleanup: .command(["pnpm", "store", "prune"]), detail: "只删没有项目引用的包",
              busyWhen: [Busy("pnpm", ["install", "i", "add", "update", "up", "upgrade", "fetch", "import", "dedupe"])]),
        // 不用 `brew cleanup`：它还会删已安装软件的旧版本、自动卸载没人依赖的软件，都不能撤销（L-06）。
        // 只删下载缓存，下次安装时重新下载
        Place("包管理器缓存", "Homebrew 下载缓存", ["Library/Caches/Homebrew/downloads"], risk: .safe, suggested: true,
              cleanup: .remove, detail: "下次安装时会重新下载", busyWhen: [Busy("Homebrew/brew.rb")]),
        Place("包管理器缓存", "pip 缓存", ["Library/Caches/pip"], risk: .safe, suggested: true,
              cleanup: .command(["pip3", "cache", "purge"]), detail: "下次安装时会重新下载",
              busyWhen: [Busy("pip", ["install", "download", "wheel"])]),

        // 需确认：不默认勾选
        Place("包管理器缓存", "npx 运行过的工具", [".npm/_npx"], risk: .confirm, cleanup: .trash,
              detail: "下次运行会重新下载；有些 MCP 服务正靠它运行，先关掉 Claude、Codex 再清"),
        // 驿窗、剪藏插件的扩展测试靠它跑；Playwright 1.64 跑测试、装依赖都不会自动补下载，删了测试直接全挂
        // （11-17、11-18 删过 3 次，驿窗 L-16、剪藏插件 L-16），所以不默认勾选、不进自动清理（2026-11-19 常浩批）
        Place("测试用浏览器", "Playwright 浏览器", ["Library/Caches/ms-playwright"], risk: .confirm, cleanup: .remove,
              detail: "驿窗、剪藏插件的扩展测试要用；删了测试直接失败，不会自动重新下载，要在项目里手动 playwright install 装回"),
        // 和 Playwright 同类：浏览器是装依赖时下载的，启动时不会自动补，原来写的「下次跑测试时会自动重新下载」不对
        // （按 Puppeteer 的已知行为判断，本机没有这个目录，没实测）。2026-11-20 常浩确认照 Playwright 改（issue #18），
        // 11-19 那次定的是「这次不动」
        Place("测试用浏览器", "Puppeteer 浏览器", [".cache/puppeteer"], risk: .confirm, cleanup: .remove,
              detail: "用 Puppeteer 的项目跑测试要用；删了不会自动重新下载，要在项目里运行 npx puppeteer browsers install 装回"),
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

/// 清理命令在这台电脑上找不到的项：不勾选、不能勾，说明里写去终端怎么清。
/// 应用从「应用程序」或登录项启动时 PATH 很短（`ProcessRunner` 只补了 Homebrew），装在 `~/.local/bin`、nvm 目录下的
/// uv、pnpm 找不到，点了只会被跳过；在终端里跑命令行时找得到，照常勾选（L-16）。
/// 用和执行时同一个 `runner` 查（`which`），两边看到的 PATH 一致。
public func applyAvailability(_ findings: [Finding], runner: CommandRunner) -> [Finding] {
    var known: [String: Bool] = [:]
    return findings.map { f in
        guard case .command(let args) = f.cleanup, let tool = args.first else { return f }
        let available = known[tool] ?? (runner.run(["which", tool], cwd: nil).status == 0)
        known[tool] = available
        if available { return f }
        return f.revised(detail: "没找到 \(tool) 命令，这里清不了；装了的话可以在终端里运行 \(args.joined(separator: " "))",
                         suggested: false, cleanup: .none)
    }
}

/// 「对应的工具正在干活」的特征：进程命令行里有 `tool` 这个程序，而且它后面的词里有 `subcommands` 之一（空表示只要在跑就算）。
/// 按词比，不按子串比：`pnpm install` 不算 npm 在装；带全局选项的 `pnpm --filter web install`、`python -m pip -q install`、
/// 带版本号的 `pip3.12 install` 都认得。宁可多拦：命令行里只是提到这些词（`sh -c "npm install && vite"`）也算，这次跳过、下次再清
public struct Busy: Equatable {
    /// 可执行文件的名字，或路径的结尾（`Homebrew/brew.rb`）
    public let tool: String
    public let subcommands: Set<String>

    public init(_ tool: String, _ subcommands: Set<String> = []) {
        self.tool = tool
        self.subcommands = subcommands
    }

    /// `ps -axo command` 的一行里有没有它
    public func running(in line: Substring) -> Bool {
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        for (i, word) in words.enumerated() where isTool(word) {
            if subcommands.isEmpty || words[(i + 1)...].contains(where: { subcommands.contains(String($0)) }) { return true }
        }
        return false
    }

    private func isTool(_ word: Substring) -> Bool {
        if word == tool || word.hasSuffix("/" + tool) { return true }
        // 带版本号的名字：pip3、pip3.12
        let base = word.split(separator: "/").last ?? word
        return base.hasPrefix(tool) && base.count > tool.count && base.dropFirst(tool.count).allSatisfy { $0.isNumber || $0 == "." }
    }
}

public struct KnownPlacesScanner {
    let home: URL
    let places: [Place]
    /// 小于这个大小的不列出，免得一堆几 MB 的噪音
    let minBytes: Int64
    let sizeOf: (URL) -> Int64
    let now: Date
    /// 一个目录最近一次变动：它和往下两层里最新的修改时间（认备份的先后）
    let modifiedAt: (URL) -> Date?
    /// 虚拟机最近一次用：往下三层（Colima 的磁盘文件在 `.colima/_lima/<名>/diffdisk`，开着不重启时只有它在变）
    let useOf: (URL) -> Date?

    public init(home: URL, places: [Place] = KnownPlaces.all, minBytes: Int64 = 50 * 1_048_576,
                sizeOf: @escaping (URL) -> Int64 = allocatedSize, now: Date = Date(),
                modifiedAt: @escaping (URL) -> Date? = { latestModification($0) },
                useOf: @escaping (URL) -> Date? = { latestModification($0, depth: 3) }) {
        self.home = home
        self.places = places
        self.minBytes = minBytes
        self.sizeOf = sizeOf
        self.now = now
        self.modifiedAt = modifiedAt
        self.useOf = useOf
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
                    used = urls.compactMap { useOf($0) }.max()
                    if let used {
                        // 和 Finding.bucket 用同一个判断，说明和分段不会对不上
                        let stale = now.timeIntervalSince(used) > Double(Finding.unusedDays) * 86_400
                        detail = stale ? "\(Int(now.timeIntervalSince(used) / 86_400)) 天没用了。\(place.detail)"
                                       : "\(BeijingTime.monthDay(used))还用过，先留着"
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
