import Foundation
import Testing
@testable import DiskSlimCore

/// 第四批 ①：从访达、挂件启动时 PATH 很短，并上登录 shell 的 PATH 才找得到 uv、pnpm（L-16）
@Suite struct LoginShellTests {
    let t = TempDir()

    /// 写一个假 shell：`-l -c <命令>` 时先跑 `before`，把 PATH 设成 `path`，再执行命令
    func shell(_ before: String = "", path: String = "/Users/x/.local/bin:/usr/bin:/bin", exit: Int = 0) throws -> String {
        let u = t.url.appendingPathComponent("fake-sh-\(UUID().uuidString.prefix(6))")
        let script = "#!/bin/sh\n\(before)\nshift; shift\n[ \(exit) -ne 0 ] && exit \(exit)\nPATH='\(path)'\neval \"$1\"\n"
        try Data(script.utf8).write(to: u)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        return u.path
    }

    @Test func 合并_原有的在前_登录shell补上没有的_最后补Homebrew_去重() {
        #expect(mergedPath("/usr/bin:/bin", "/Users/x/.local/bin:/usr/bin:/opt/homebrew/bin")
                == "/usr/bin:/bin:/Users/x/.local/bin:/opt/homebrew/bin:/usr/local/bin")
        // 取不到登录 shell 时和第四批之前一样：原有的 + Homebrew
        #expect(mergedPath("/usr/bin:/bin", nil) == "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin")
        #expect(mergedPath(nil, nil) == "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin")
        // 空的、相对路径都不要
        #expect(mergedPath("/usr/bin::.", "bin:/a") == "/usr/bin:/a:/opt/homebrew/bin:/usr/local/bin")
    }

    @Test func 登录shell配置往外打字_只取标记后面的PATH() throws {
        let sh = try shell("echo 欢迎回来; echo '/not/this'")
        #expect(LoginShell.path(shell: sh, timeout: 30) == "/Users/x/.local/bin:/usr/bin:/bin")
    }

    @Test func 登录shell出错或超时_当作取不到() throws {
        #expect(LoginShell.path(shell: try shell(exit: 3), timeout: 30) == nil)
        let slow = try shell("/bin/sleep 5")
        let start = Date()
        #expect(LoginShell.path(shell: slow, timeout: 0.5) == nil)
        #expect(Date().timeIntervalSince(start) < 4)
        #expect(LoginShell.path(shell: "/no/such/shell") == nil)
    }

    @Test func 结果不像PATH_当作取不到() throws {
        #expect(LoginShell.path(shell: try shell(path: "oops"), timeout: 30) == nil)
    }

    @Test func 真的登录shell_拿得到绝对路径() {
        // 本机真跑一次 /bin/zsh -l -c：只要求拿得到、像 PATH，不假设装了什么
        let p = LoginShell.path(shell: "/bin/zsh", timeout: 30)
        #expect(p?.hasPrefix("/") == true && p?.contains("/usr/bin") == true, "\(p ?? "nil")")
    }

    @Test func 取成功就一直用_取失败隔10分钟再试() {
        let cache = LoginShell.Cache()
        let t0 = Date(timeIntervalSince1970: 1_763_700_000)
        var calls = 0
        #expect(cache.get(now: t0, resolve: { calls += 1; return nil }) == nil)
        #expect(cache.get(now: t0.addingTimeInterval(599), resolve: { calls += 1; return "/a" }) == nil, "10 分钟内不重试")
        #expect(calls == 1)
        #expect(cache.get(now: t0.addingTimeInterval(600), resolve: { calls += 1; return "/a" }) == "/a")
        #expect(cache.get(now: t0.addingTimeInterval(601), resolve: { calls += 1; return "/b" }) == "/a", "取成功后不再跑")
        #expect(calls == 2)
    }

    @Test func 跑命令时真的用上登录shell的PATH() {
        // 原有 PATH 只给最短的一段，子进程看到的 PATH 里要有登录 shell 的目录（审查：这一环原来没有测试守着）
        let login = LoginShell.cached()
        let out = ProcessRunner(timeout: 30, basePath: "/usr/bin:/bin").run(["sh", "-c", "printf %s \"$PATH\""], cwd: nil).output
        #expect(out.hasPrefix("/usr/bin:/bin:"))
        for dir in (login ?? "").split(separator: ":") where dir.hasPrefix("/") {
            #expect(out.split(separator: ":").contains(dir), "\(dir) 不在 \(out)")
        }
        #expect(login != nil, "本机登录 shell 应该取得到")
    }
}
