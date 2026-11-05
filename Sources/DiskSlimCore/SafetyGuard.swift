import Foundation

/// 执行前的最后一道门：不信任传进来的 Finding，按规则重新核对每条路径和命令（docs/PRD.md 第 5 节）。
/// 只认这几种：
/// - 移到废纸篓：下载文件夹第一层的项；「需确认」位置里允许逐个子目录清的子项（如 Codex 备份）。
/// - 直接删除：`<work>/<项目>/.claude/worktrees/<名称>/target`；已知位置表里标为直接删除的路径本身。
/// - 运行命令：只认已知位置表里写死的命令。
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
        switch f.cleanup {
        case .none:
            return "这一项没有清理方式"
        case .trash:
            return f.paths.allSatisfy { isDownloadsItem($0) || isPerChildItem($0) } ? nil : "不在允许移到废纸篓的位置"
        case .remove:
            return f.paths.allSatisfy { isWorktreeTarget($0) || isRemovablePlace($0) } ? nil : "不在允许直接删除的位置"
        case .command(let c):
            return places.contains { $0.cleanup == .command(c) } ? nil : "不认识的清理命令"
        }
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

    private func isRemovablePlace(_ path: String) -> Bool {
        let p = parts(path)
        return places.contains { place in
            place.cleanup == .remove && !place.perChild
                && place.paths.contains { parts(home.appendingPathComponent($0).path) == p }
        }
    }
}
