import Foundation

/// 各项目 `.claude/worktrees/*/target`：Rust 构建产物（docs/PRD.md 4.2）。
/// 四个条件全满足才建议删：PR 已合并、没有未提交的已跟踪改动、24 小时内没编译过、没有编译进程在用。
/// 项目主仓库根目录的 `target/` 不在扫描范围内。
public struct WorktreeScanner {
    let workRoot: URL
    let now: Date
    let runner: CommandRunner
    let sizeOf: (URL) -> Int64

    public init(workRoot: URL, now: Date, runner: CommandRunner, sizeOf: @escaping (URL) -> Int64 = allocatedSize) {
        self.workRoot = workRoot
        self.now = now
        self.runner = runner
        self.sizeOf = sizeOf
    }

    public func scan() -> [Finding] {
        let fm = FileManager.default
        let projects = ((try? fm.contentsOfDirectory(at: workRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let processes = runner.run(["ps", "-axo", "command"], cwd: nil).output
        var found: [Finding] = []

        for project in projects {
            let wtRoot = project.appendingPathComponent(".claude/worktrees")
            let worktrees = ((try? fm.contentsOfDirectory(at: wtRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter { fm.fileExists(atPath: $0.appendingPathComponent("target").path) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if worktrees.isEmpty { continue }
            let merged = mergedBranches(project)

            for wt in worktrees {
                let target = wt.appendingPathComponent("target")
                let reasons = blockers(wt: wt, target: target, merged: merged, processes: processes)
                let title = "\(project.lastPathComponent) · \(wt.lastPathComponent)"
                let built = BeijingTime.monthDay(lastModified(target) ?? now)
                if reasons.isEmpty {
                    found.append(Finding(area: .hidden, category: "已合并 worktree 的构建产物", title: title,
                                         detail: "PR 已合并，最后编译 \(built)", paths: [target.path],
                                         bytes: sizeOf(target), risk: .safe, suggested: true, cleanup: .remove))
                } else {
                    found.append(Finding(area: .hidden, category: "暂时不能清的构建产物", title: title,
                                         detail: reasons.joined(separator: "；"), paths: [target.path],
                                         bytes: sizeOf(target), risk: .safe, suggested: false, cleanup: .none))
                }
            }
        }
        return found
    }

    /// 查不到（gh 未登录、没有远端、出错）时返回 nil，此时一律不建议删。
    private func mergedBranches(_ project: URL) -> Set<String>? {
        let r = runner.run(["gh", "pr", "list", "--state", "merged", "--limit", "300",
                            "--json", "headRefName", "-q", ".[].headRefName"], cwd: project)
        guard r.status == 0 else { return nil }
        return Set(r.output.split(separator: "\n").map(String.init))
    }

    private func blockers(wt: URL, target: URL, merged: Set<String>?, processes: String) -> [String] {
        var reasons: [String] = []
        let branch = runner.run(["git", "-C", wt.path, "branch", "--show-current"], cwd: nil).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let merged {
            if branch.isEmpty || !merged.contains(branch) { reasons.append("PR 还没合并") }
        } else {
            reasons.append("查不到 PR 状态")
        }

        let status = runner.run(["git", "-C", wt.path, "status", "--porcelain"], cwd: nil)
        let dirty = status.output.split(separator: "\n").contains { !$0.hasPrefix("??") }
        if status.status != 0 || dirty { reasons.append("有未提交的改动") }

        if let last = lastModified(target), now.timeIntervalSince(last) < 86_400 {
            reasons.append("24 小时内编译过")
        }

        // 只能认出命令行里带着 worktree 路径的编译进程；在 worktree 里直接跑 `cargo build` 的认不出，
        // 那种情况靠上面「24 小时内编译过」兜住（编译时 target/ 会持续更新）
        let paths = Set([wt.path, wt.resolvingSymlinksInPath().path])
        let busy = processes.split(separator: "\n").contains { line in
            paths.contains { line.contains($0) } && (line.contains("cargo") || line.contains("rustc") || line.contains("tauri"))
        }
        if busy { reasons.append("正在编译") }
        return reasons
    }

    /// `target/` 本身和第一层子项里最新的修改时间。
    private func lastModified(_ target: URL) -> Date? {
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: target, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return ([target] + children)
            .compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
            .max()
    }
}
