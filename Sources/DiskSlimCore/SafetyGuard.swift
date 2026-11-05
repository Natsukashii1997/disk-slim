import Foundation

/// 执行前的最后一道门：不信任传进来的 Finding，按规则重新核对每条路径和命令（docs/PRD.md 第 5 节）。
/// 只认这几种：
/// - 移到废纸篓：下载文件夹第一层的项；已知位置表里标为移到废纸篓的路径本身，或逐个子目录清的子项（如 Codex 备份）。
/// - 直接删除：`<work>/<项目>/.claude/worktrees/<名称>/target`；已知位置表里标为直接删除的路径本身。
/// - 运行命令：只认已知位置表里写死的命令，而且这一项的路径必须正是表里这条命令对应的路径。
/// 路径中间任何一层是符号链接一律拒绝（直接删除时最后一层也不许是链接）：防止删到允许范围以外。
public struct SafetyGuard {
    let home: URL
    let workRoot: URL
    let places: [Place]

    public init(home: URL, workRoot: URL, places: [Place] = KnownPlaces.all) {
        self.home = home
        self.workRoot = workRoot
        self.places = places
    }

    /// 允许清就返回 nil，不允许就返回原因。
    public func refusal(for f: Finding) -> String? {
        if f.risk == .readOnly { return "只展示的项，工具不会删" }
        if f.paths.isEmpty { return "没有路径" }
        // 带 . 或 .. 的路径不规范化，直接拒绝：经过符号链接时字面规范化和文件系统的理解会不一样
        if f.paths.contains(where: { $0.split(separator: "/").contains { $0 == ".." || $0 == "." } }) {
            return "路径里有 . 或 .."
        }
        switch f.cleanup {
        case .none:
            return "这一项没有清理方式"
        case .trash:
            if !f.paths.allSatisfy({ isDownloadsItem($0) || isPerChildItem($0) || isPlacePath($0, .trash) }) {
                return "不在允许移到废纸篓的位置"
            }
            // 移到废纸篓的是链接本身，不碰它指向的东西，所以最后一层可以是链接。
            // 下载文件夹本身可以是链接（有人把它放到别的盘），从它往下查
            let downloads = home.appendingPathComponent("Downloads")
            let linked = f.paths.contains { p in
                isDownloadsItem(p) ? hasSymlink(p, under: downloads, includingLast: false)
                                   : hasSymlink(p, under: home, includingLast: false)
            }
            return linked ? "路径中间有符号链接" : nil
        case .remove:
            if !f.paths.allSatisfy({ isWorktreeTarget($0) || isPlacePath($0, .remove) }) {
                return "不在允许直接删除的位置"
            }
            let linked = f.paths.contains { p in
                isWorktreeTarget(p) ? hasSymlink(p, under: workRoot) : hasSymlink(p, under: home)
            }
            return linked ? "路径里有符号链接" : nil
        case .command(let c):
            guard let place = places.first(where: { $0.cleanup == .command(c) }) else { return "不认识的清理命令" }
            let expected = Set(place.paths.map { parts(home.appendingPathComponent($0).path) })
            return Set(f.paths.map(parts)) == expected ? nil : "清理命令和它的位置对不上"
        }
    }

    /// 有这些进程在跑时，这一项先不删（例如 Homebrew 正在下载时不删它的下载缓存）。
    public func busyMarkers(for f: Finding) -> [String] {
        places.filter { place in
            place.cleanup == f.cleanup && place.paths.contains { root in
                f.paths.contains { parts($0) == parts(home.appendingPathComponent(root).path) }
            }
        }.flatMap(\.busyWhen)
    }

    private func parts(_ path: String) -> [String] {
        URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    }

    private func components(_ path: String, under root: URL) -> [String]? {
        let p = parts(path), r = root.standardizedFileURL.pathComponents
        guard p.count > r.count, Array(p.prefix(r.count)) == r else { return nil }
        return Array(p.dropFirst(r.count))
    }

    private func isDownloadsItem(_ path: String) -> Bool {
        guard let rest = components(path, under: home.appendingPathComponent("Downloads")) else { return false }
        return rest.count == 1 && !rest[0].hasPrefix(".")
    }

    private func isPerChildItem(_ path: String) -> Bool {
        places.contains { place in
            place.perChild && place.cleanup == .trash && place.paths.contains { root in
                components(path, under: home.appendingPathComponent(root)).map { $0.count == 1 && !$0[0].hasPrefix(".") } ?? false
            }
        }
    }

    private func isWorktreeTarget(_ path: String) -> Bool {
        guard let rest = components(path, under: workRoot) else { return false }
        return rest.count == 5 && rest[1] == ".claude" && rest[2] == "worktrees" && rest[4] == "target"
            && !rest[0].hasPrefix(".") && !rest[3].hasPrefix(".")
    }

    private func isPlacePath(_ path: String, _ cleanup: Cleanup) -> Bool {
        let p = parts(path)
        return places.contains { place in
            place.cleanup == cleanup && !place.perChild
                && place.paths.contains { parts(home.appendingPathComponent($0).path) == p }
        }
    }
}
