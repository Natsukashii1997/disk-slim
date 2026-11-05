import Foundation

/// 各项目 `.claude/worktrees/*/target`：Rust 构建产物（docs/PRD.md 4.2）。
/// 前提：是 Rust 构建目录（有 Cargo.toml、target 被 git 忽略）、没有未提交的已跟踪改动、没在用。
/// 「没在用」三道一起判（第 7 批）：worktree 没被 git 锁住、cargo 的锁文件没被占（没在编译）、没有进程的工作目录或可执行文件在里面，
/// 外加 2 小时内没编译过。
/// - 已落地（PR 已合并且停在合并时的提交，或者当前提交已在 main 里）：默认勾选，可以自动清理。
/// - 没落地但闲置 ≥ 3 天：列成「要你决定」，不默认勾选。
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
        let openPaths = Self.openPaths(runner)
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
            let locked = Self.lockedWorktrees(project, runner: runner)

            for wt in worktrees {
                let target = wt.appendingPathComponent("target")
                var reasons = blockers(wt: wt, target: target)
                reasons += Self.inUse(wt, target: target, locked: locked, openPaths: openPaths, processes: processes, now: now)
                let title = "\(project.lastPathComponent) · \(wt.lastPathComponent)"
                let built = BeijingTime.monthDay(Self.lastBuilt(target) ?? now)
                let landed = landedReason(wt, merged: merged)
                let idleDays = Int(now.timeIntervalSince(idleSince(wt, target: target) ?? now) / 86_400)
                if reasons.isEmpty, let landed {
                    found.append(Finding(area: .hidden, category: "已合并 worktree 的构建产物", title: title,
                                         detail: "\(landed)，最后编译 \(built)", paths: [target.path],
                                         bytes: sizeOf(target), risk: .safe, suggested: true, cleanup: .remove))
                } else if reasons.isEmpty, idleDays >= 3 {
                    found.append(Finding(area: .hidden, category: "闲置的 worktree 构建产物", title: title,
                                         detail: "闲置 \(idleDays) 天，PR 还没合并；清掉下次要重新编译", paths: [target.path],
                                         bytes: sizeOf(target), risk: .confirm, suggested: false, cleanup: .remove))
                } else {
                    if landed == nil { reasons.insert(merged == nil ? "查不到 PR 状态" : "PR 还没合并", at: 0) }
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

    /// 静置窗口：这么久内编译过就不清（第 7 批从 24 小时缩到 2 小时，换来的是下面三道「正在用」的判断）
    public static let quietSeconds: TimeInterval = 2 * 3600

    public static func recentlyBuilt(_ target: URL, now: Date) -> Bool {
        guard let last = lastBuilt(target) else { return false }
        return now.timeIntervalSince(last) < quietSeconds
    }

    /// 「正在用」：扫描时和执行前复核都用。返回原因，空表示没在用
    public static func inUse(_ wt: URL, target: URL, locked: [String: String], openPaths: [String], processes: String, now: Date) -> [String] {
        var reasons: [String] = []
        if let why = locked[wt.path] ?? locked[wt.resolvingSymlinksInPath().path] {
            reasons.append(why.isEmpty ? "worktree 被锁住了" : "worktree 被锁住了（\(why)）")
        }
        if cargoBusy(target) { reasons.append("正在编译") }
        let prefixes = [wt.path, wt.resolvingSymlinksInPath().path]
        if openPaths.contains(where: { p in prefixes.contains { p == $0 || p.hasPrefix($0 + "/") } }) || busy(wt, processes: processes) {
            reasons.append("有程序在里面运行")
        }
        if recentlyBuilt(target, now: now) { reasons.append("2 小时内编译过") }
        return reasons
    }

    /// 所有进程的工作目录和可执行文件路径（`lsof -d cwd,txt`）。`cargo run` 起的程序命令行里是相对路径，只能这样认出来
    public static func openPaths(_ runner: CommandRunner) -> [String] {
        runner.run(["/usr/sbin/lsof", "-n", "-d", "cwd,txt", "-Fn"], cwd: nil).output
            .split(separator: "\n").filter { $0.hasPrefix("n/") }.map { String($0.dropFirst()) }
    }

    /// `git worktree list --porcelain` 里被锁住的 worktree：路径 → 锁的原因（不解析里面的 pid，有锁就算在用）
    public static func lockedWorktrees(_ project: URL, runner: CommandRunner) -> [String: String] {
        let out = runner.run(["git", "--no-optional-locks", "-C", project.path, "worktree", "list", "--porcelain"], cwd: nil).output
        var result: [String: String] = [:], current: String?
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") { current = String(line.dropFirst("worktree ".count)) }
            else if line == "locked" || line.hasPrefix("locked "), let c = current {
                result[c] = line.count > 7 ? String(line.dropFirst(7)) : ""
            }
        }
        return result
    }

    /// cargo 编译时会用 flock 占住 `target/<profile>/.cargo*lock`：试着非阻塞地拿一下，拿不到就是正在编译。只读打开，不创建
    public static func cargoBusy(_ target: URL) -> Bool { holdCargoLocks(target).map { release($0); return false } ?? true }

    /// 拿住所有 cargo 锁并返回文件描述符；有一个拿不到就全部放掉、返回 nil（删除时持有，cargo 这时会等，不会写进来）
    public static func holdCargoLocks(_ target: URL) -> [Int32]? {
        var fds: [Int32] = []
        for lock in cargoLockFiles(target) {
            let fd = open(lock.path, O_RDONLY)
            if fd < 0 { continue }
            if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); release(fds); return nil }
            fds.append(fd)
        }
        return fds
    }

    public static func release(_ fds: [Int32]) { for fd in fds { flock(fd, LOCK_UN); close(fd) } }

    /// `target/*/.cargo*lock` 和 `target/*/*/.cargo*lock`（带三元组的目录）
    static func cargoLockFiles(_ target: URL) -> [URL] {
        let fm = FileManager.default
        func locks(in dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasPrefix(".cargo") && $0.hasSuffix("lock") }.map { dir.appendingPathComponent($0) }
        }
        func subdirs(_ dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false }
        }
        return subdirs(target).flatMap { d in locks(in: d) + subdirs(d).flatMap(locks) }
    }

    /// 已落地的说明；没落地返回 nil。PR 合并（按分支名 + 提交认）或当前提交已在远端主分支里（认得出 squash 合并后检出的 main）
    private func landedReason(_ wt: URL, merged: [String: Set<String>]?) -> String? {
        let branch = git(wt, "branch", "--show-current")
        let head = git(wt, "rev-parse", "HEAD")
        if !branch.isEmpty, !head.isEmpty, merged?[branch]?.contains(head) == true { return "PR 已合并" }
        for ref in ["origin/HEAD", "origin/main", "origin/master"]
        where runner.run(["git", "--no-optional-locks", "-C", wt.path, "rev-parse", "--verify", "-q", ref], cwd: nil).status == 0 {
            let r = runner.run(["git", "--no-optional-locks", "-C", wt.path, "merge-base", "--is-ancestor", "HEAD", ref], cwd: nil)
            return r.status == 0 ? "当前提交已在\(ref == "origin/HEAD" ? "主分支" : " \(ref) ")里" : nil
        }
        return nil
    }

    /// 闲置从什么时候算：最后编译时间和 worktree 的 HEAD 最后变动时间取较晚的
    private func idleSince(_ wt: URL, target: URL) -> Date? {
        var dates = [Self.lastBuilt(target)]
        let gitDir = git(wt, "rev-parse", "--absolute-git-dir")
        if !gitDir.isEmpty {
            dates.append((try? URL(fileURLWithPath: gitDir).appendingPathComponent("logs/HEAD")
                .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
        }
        return dates.compactMap { $0 }.max()
    }

    private func git(_ wt: URL, _ args: String...) -> String {
        runner.run(["git", "--no-optional-locks", "-C", wt.path] + args, cwd: nil).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func blockers(wt: URL, target: URL) -> [String] {
        var reasons: [String] = []
        let fm = FileManager.default

        // 不是 Rust 的构建目录（例如别的项目里被 git 跟踪的 target/ 源码）就不碰
        if !fm.fileExists(atPath: wt.appendingPathComponent("Cargo.toml").path) { reasons.append("不是 Rust 项目") }
        if runner.run(["git", "--no-optional-locks", "-C", wt.path, "check-ignore", "-q", "target"], cwd: nil).status != 0 {
            reasons.append("target 没被 git 忽略")
        }

        let status = runner.run(["git", "--no-optional-locks", "-C", wt.path, "status", "--porcelain"], cwd: nil)
        let dirty = status.output.split(separator: "\n").contains { !$0.hasPrefix("??") }
        if status.status != 0 || dirty { reasons.append("有未提交的改动") }
        return reasons
    }

    /// 命令行里带着 worktree 路径的编译进程（额外一道；主要靠 cargo 锁和 lsof）
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
