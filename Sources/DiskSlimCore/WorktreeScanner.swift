import Foundation

/// 各项目 `.claude/worktrees/*/target`：Rust 构建产物（docs/PRD.md 4.2）。
/// 全部满足才建议删：是 Rust 构建目录（有 Cargo.toml、target 被 git 忽略）、PR 已合并且 worktree 停在 PR 合并时的那个提交、
/// 没有未提交的已跟踪改动、24 小时内没编译过、没有编译进程在用。
/// 项目主仓库根目录的 `target/` 不在扫描范围内；路径里有符号链接的 worktree 直接跳过。
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
                // 项目、.claude、worktrees、worktree、target 任何一层是符号链接都不碰（L-06）
                .filter { !hasSymlink($0.appendingPathComponent("target").path, under: workRoot) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if worktrees.isEmpty { continue }
            let merged = mergedHeads(project)

            for wt in worktrees {
                let target = wt.appendingPathComponent("target")
                let reasons = blockers(wt: wt, target: target, merged: merged, processes: processes)
                let title = "\(project.lastPathComponent) · \(wt.lastPathComponent)"
                let built = BeijingTime.monthDay(Self.lastBuilt(target) ?? now)
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

    /// 已合并 PR 的「分支名 → PR 最后一个提交」。查不到（gh 未登录、没有远端、出错、超时）时返回 nil，一律不建议删。
    private func mergedHeads(_ project: URL) -> [String: Set<String>]? {
        let r = runner.run(["gh", "pr", "list", "--state", "merged", "--limit", "300",
                            "--json", "headRefName,headRefOid", "-q", ".[] | \"\\(.headRefName) \\(.headRefOid)\""], cwd: project)
        guard r.status == 0 else { return nil }
        var heads: [String: Set<String>] = [:]
        for line in r.output.split(separator: "\n") {
            let p = line.split(separator: " ")
            if p.count == 2 { heads[String(p[0]), default: []].insert(String(p[1])) }
        }
        return heads
    }

    /// 也给 Cleaner 在执行前复核用：只复核会随时间变化的两条（编译时间、编译进程）。
    public static func recentlyBuilt(_ target: URL, now: Date) -> Bool {
        guard let last = lastBuilt(target) else { return false }
        return now.timeIntervalSince(last) < 86_400
    }

    private func blockers(wt: URL, target: URL, merged: [String: Set<String>]?, processes: String) -> [String] {
        var reasons: [String] = []
        let fm = FileManager.default

        // 不是 Rust 的构建目录（例如别的项目里被 git 跟踪的 target/ 源码）就不碰
        if !fm.fileExists(atPath: wt.appendingPathComponent("Cargo.toml").path) { reasons.append("不是 Rust 项目") }
        if runner.run(["git", "-C", wt.path, "check-ignore", "-q", "target"], cwd: nil).status != 0 {
            reasons.append("target 没被 git 忽略")
        }

        let branch = runner.run(["git", "-C", wt.path, "branch", "--show-current"], cwd: nil).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let head = runner.run(["git", "-C", wt.path, "rev-parse", "HEAD"], cwd: nil).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let merged {
            // 按「分支名 + 提交」一起认：分支名被复用、合并后又在 worktree 里提交过，都不算已合并
            if branch.isEmpty || head.isEmpty || !(merged[branch]?.contains(head) ?? false) { reasons.append("PR 还没合并") }
        } else {
            reasons.append("查不到 PR 状态")
        }

        let status = runner.run(["git", "-C", wt.path, "status", "--porcelain"], cwd: nil)
        let dirty = status.output.split(separator: "\n").contains { !$0.hasPrefix("??") }
        if status.status != 0 || dirty { reasons.append("有未提交的改动") }

        if Self.recentlyBuilt(target, now: now) { reasons.append("24 小时内编译过") }
        if Self.busy(wt, processes: processes) { reasons.append("正在编译") }
        return reasons
    }

    /// 只能认出命令行里带着 worktree 路径的编译进程；在 worktree 里直接跑 `cargo build` 的认不出，
    /// 那种情况靠「24 小时内编译过」兜住（编译时 target/ 里的文件会持续更新）
    static func busy(_ wt: URL, processes: String) -> Bool {
        let paths = Set([wt.path, wt.resolvingSymlinksInPath().path])
        return processes.split(separator: "\n").contains { line in
            paths.contains { line.contains($0) } && (line.contains("cargo") || line.contains("rustc") || line.contains("tauri"))
        }
    }

    /// `target/` 往下三层里最新的修改时间。cargo 增量编译改的是 `target/debug/deps/*` 这一层的文件（L-06）。
    static func lastBuilt(_ target: URL) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        var latest = (try? target.resourceValues(forKeys: Set(keys)))?.contentModificationDate
        guard let e = FileManager.default.enumerator(at: target, includingPropertiesForKeys: keys, options: [],
                                                     errorHandler: { _, _ in true }) else { return latest }
        for case let u as URL in e {
            if e.level >= 3 { e.skipDescendants() }
            if let d = (try? u.resourceValues(forKeys: Set(keys)))?.contentModificationDate, d > (latest ?? .distantPast) {
                latest = d
            }
        }
        return latest
    }
}
