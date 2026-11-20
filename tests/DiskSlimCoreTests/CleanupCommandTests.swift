import Foundation
import Testing
@testable import DiskSlimCore

/// 清理命令类的项（npm、uv、pnpm、pip）：命令找不找得到、对应工具在不在跑（issue #18）。
@Suite struct CleanupCommandTests {
    let t = TempDir()
    var home: URL { t.url.appendingPathComponent("home") }

    func found(_ title: String, _ args: [String], suggested: Bool = true) -> Finding {
        Finding(area: .hidden, category: "包管理器缓存", title: title, detail: "下次安装时会重新下载",
                paths: ["/x/" + title], bytes: 100, risk: .safe, suggested: suggested, cleanup: .command(args))
    }

    // MARK: 找不到命令

    /// 从「应用程序」启动时 PATH 里没有 ~/.local/bin、nvm 这些位置：uv、pnpm 找不到，点了只会被跳过。
    /// 找不到的不勾选、不能勾，归「先不动」，说明里写去终端怎么清
    @Test func 找不到清理命令的_不勾选_不能勾_写明去终端怎么清() {
        let run = FakeRunner()
        run.on(0, "/usr/local/bin/npm\n") { a, _ in a == ["which", "npm"] }
        let out = applyAvailability([found("npm 缓存", ["npm", "cache", "clean", "--force"]),
                                     found("uv 缓存", ["uv", "cache", "clean"])], runner: run)
        #expect(out[0].suggested == true)
        #expect(out[0].cleanup == .command(["npm", "cache", "clean", "--force"]))
        #expect(out[1].suggested == false)
        #expect(out[1].cleanup == Cleanup.none)
        #expect(out[1].detail == "这台电脑上没找到 uv 命令，清不了；可以在终端里运行 uv cache clean")
        #expect(out[1].bucket(now: now) == .keep)
        #expect(Alerts.autoCleanPicks(out).map(\.title) == ["npm 缓存"])
        // 大小、路径、分组照旧，涨幅记录里的名字不变
        #expect(out[1].bytes == 100 && out[1].paths == ["/x/uv 缓存"] && out[1].id == found("uv 缓存", []).id)
    }

    @Test func 不是清理命令的项_不查也不改() {
        let run = FakeRunner()
        var asked: [[String]] = []
        run.on(1, "") { a, _ in asked.append(a); return true }
        let trash = Finding(area: .downloads, category: "安装包", title: "a.dmg", detail: "d", paths: ["/d/a.dmg"],
                            bytes: 1, risk: .safe, suggested: true, cleanup: .trash)
        let out = applyAvailability([trash], runner: run)
        #expect(out[0].suggested == true && out[0].cleanup == .trash)
        #expect(asked.isEmpty)
    }

    /// 整次扫描里也生效：用应用同款的环境（找不到 uv）扫一遍
    @Test func 整次扫描_找不到命令的缓存归先不动() {
        t.file("home/.cache/uv/a", bytes: 60 * 1_048_576)
        t.file("home/.npm/_cacache/a", bytes: 60 * 1_048_576)
        let run = FakeRunner()
        run.on(0, "/usr/local/bin/npm\n") { a, _ in a == ["which", "npm"] }
        let r = Scan(home: home, workRoot: home.appendingPathComponent("work"), meta: FakeMetadata(), runner: run).run(now: now)
        let uv = r.findings.first { $0.title == "uv 缓存" }
        let npm = r.findings.first { $0.title == "npm 缓存" }
        #expect(uv?.suggested == false && uv?.cleanup == Cleanup.none)
        #expect(npm?.suggested == true)
        // 「替你挑好的」合计不再把清不了的算进去
        #expect(r.suggestedBytes == npm?.bytes)
    }

    // MARK: 对应工具正在运行

    func cleaner(_ run: FakeRunner) -> Cleaner {
        Cleaner(safety: SafetyGuard(home: home, workRoot: home.appendingPathComponent("work")), runner: run,
                trasher: FakeTrasher(dir: t.url.appendingPathComponent("Trash")), log: .standard(home: home))
    }

    func place(_ path: String, _ args: [String]) -> Finding {
        Finding(area: .hidden, category: "包管理器缓存", title: args[0], detail: "", paths: [home.appendingPathComponent(path).path],
                bytes: 1, risk: .safe, suggested: true, cleanup: .command(args))
    }

    @Test(arguments: [
        (".npm/_cacache", ["npm", "cache", "clean", "--force"], "npm install left-pad"),
        (".npm/_cacache", ["npm", "cache", "clean", "--force"], "npm ci"),
        (".npm/_cacache", ["npm", "cache", "clean", "--force"], "npm i"),
        ("Library/pnpm/store", ["pnpm", "store", "prune"], "node /Users/x/.nvm/versions/node/v24/bin/pnpm install --frozen-lockfile"),
        (".cache/uv", ["uv", "cache", "clean"], "/Users/x/.local/bin/uv sync"),
        (".cache/uv", ["uv", "cache", "clean"], "uv pip install requests"),
        ("Library/Caches/pip", ["pip3", "cache", "purge"], "/usr/bin/python3 -m pip install -r requirements.txt"),
    ])
    func 正在装依赖时_这次不清(path: String, args: [String], running: String) {
        t.file("home/\(path)/a", bytes: 4_000)
        let run = FakeRunner()
        var called = false
        run.on(0, "/sbin/launchd\n\(running)\n") { a, _ in a.first == "ps" }
        run.on(0, "") { a, _ in if a == args { called = true }; return a == args }
        let item = cleaner(run).clean([place(path, args)]).items[0]
        #expect(item.outcome == .skipped)
        #expect(item.message == "相关程序正在运行，这次先不清")
        #expect(called == false)
    }

    /// 本机常年挂着几十个 `npm exec …`、`uv tool uvx …` 起的 MCP 服务：它们不算在装依赖，不能因此永远清不了
    @Test(arguments: [
        (".npm/_cacache", ["npm", "cache", "clean", "--force"], "npm exec @modelcontextprotocol/server-pdf --stdio"),
        (".npm/_cacache", ["npm", "cache", "clean", "--force"], "npm run test:nightly"),
        (".npm/_cacache", ["npm", "cache", "clean", "--force"], "npm init -y"),
        (".npm/_cacache", ["npm", "cache", "clean", "--force"], "node /x/bin/pnpm install"),
        (".cache/uv", ["uv", "cache", "clean"], "uv tool uvx mcp-server-fetch"),
        ("Library/Caches/pip", ["pip3", "cache", "purge"], "/usr/bin/python3 server.py --pipeline install"),
    ])
    func 常驻的服务和别的工具在跑_照常清(path: String, args: [String], running: String) {
        t.file("home/\(path)/a", bytes: 4_000)
        let run = FakeRunner()
        var called = false
        run.on(0, "/sbin/launchd\n\(running)\n") { a, _ in a.first == "ps" }
        run.on(0, "") { a, _ in if a == args { called = true }; return a == args }
        let item = cleaner(run).clean([place(path, args)]).items[0]
        #expect(item.outcome == .done)
        #expect(called)
    }

    /// 四条清理命令都要有「正在运行」的特征，漏一条就等于没拦
    @Test func 每条清理命令都配了在用特征() {
        for p in KnownPlaces.all {
            if case .command = p.cleanup { #expect(!p.busyWhen.isEmpty, "\(p.title) 没有 busyWhen") }
        }
    }
}

/// worktree 构建产物执行前复核：扫描之后 worktree 可能已经不是当初那个 Rust 项目（issue #18）。
@Suite struct WorktreeRecheckTests {
    let t = TempDir()

    func fixture(cargo: Bool = true) -> (Scan, Finding, FakeRunner) {
        let home = t.dir("home"), work = t.dir("home/work")
        let old = daysAgo(1)
        if cargo { t.file("home/work/proj/.claude/worktrees/wt/Cargo.toml") }
        t.file("home/work/proj/.claude/worktrees/wt/target/debug/app", bytes: 100, modified: old)
        for sub in ["target/debug", "target"] {
            t.setModified(work.appendingPathComponent("proj/.claude/worktrees/wt/\(sub)"), old)
        }
        let run = FakeRunner()
        let target = work.appendingPathComponent("proj/.claude/worktrees/wt/target").path
        let f = Finding(area: .hidden, category: "已合并 worktree 的构建产物", title: "proj · wt", detail: "",
                        paths: [target], bytes: 100, risk: .safe, suggested: true, cleanup: .remove)
        return (Scan(home: home, workRoot: work, meta: FakeMetadata(), runner: run), f, run)
    }

    @Test func 仍是Rust构建目录_照常清() {
        let (scan, f, run) = fixture()
        run.on(0, "") { a, _ in a.contains("check-ignore") }
        #expect(scan.recheck(f, now: now) == nil)
    }

    @Test func 扫描后Cargo_toml没了_这次不删() {
        let (scan, f, run) = fixture(cargo: false)
        run.on(0, "") { a, _ in a.contains("check-ignore") }
        #expect(scan.recheck(f, now: now) == "扫描后情况变了（不是 Rust 项目），这次不删")
    }

    @Test func 扫描后target不再被git忽略_这次不删() {
        let (scan, f, run) = fixture()
        run.on(1, "") { a, _ in a.contains("check-ignore") }
        #expect(scan.recheck(f, now: now) == "扫描后情况变了（target 没被 git 忽略），这次不删")
    }
}
