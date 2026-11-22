import Foundation

/// `diskslim doctor`：一条命令看清磁盘瘦身现在好不好（第四批 ③）。只读：不扫描、不清理、不写任何文件。
/// 查不到的（通知权限、完全磁盘访问只有应用自己知道）不假装查过，写明去哪看。
public struct DoctorCheck: Equatable {
    public enum Level: Equatable { case ok, warn, bad }
    public let name: String
    public let level: Level
    public let detail: String

    public init(_ name: String, _ level: Level, _ detail: String) {
        self.name = name
        self.level = level
        self.detail = detail
    }
}

public struct Doctor {
    public let home: URL
    public let app: URL
    public let runner: CommandRunner
    /// 登录 shell 的 PATH（测试里换成固定值）
    public let loginPath: () -> String?

    public init(home: URL, app: URL = URL(fileURLWithPath: "/Applications/DiskSlim.app"),
                runner: CommandRunner = ProcessRunner(timeout: 10), loginPath: @escaping () -> String? = { LoginShell.cached() }) {
        self.home = home
        self.app = app
        self.runner = runner
        self.loginPath = loginPath
    }

    /// 状态文件多久没更新算不正常：应用开着时每 5 分钟写一次
    static let statusStale: TimeInterval = 15 * 60
    /// 多少天没送达过一条提醒要提一句
    static let alertsQuietDays = 14

    var dataDir: URL { home.appendingPathComponent("Library/Application Support/disk-slim") }

    public func run(now: Date) -> [DoctorCheck] {
        let login = loginPath()
        return [version(), running(), status(now: now), space()] + records() + [alerts(now: now), loginShell(login)] + tools(login)
    }

    func version() -> DoctorCheck {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            return DoctorCheck("已装版本", .bad, "\(app.path) 没装或读不了")
        }
        let v = info["CFBundleShortVersionString"] as? String ?? "?"
        guard let commit = info[AppBuild.commitKey] as? String else {
            return DoctorCheck("已装版本", .warn, "\(v)，没写提交号（第四批之前打的包）")
        }
        let built = (info[AppBuild.builtAtKey] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            .map { "，\(BeijingTime.monthDay($0)) \(BeijingTime.hourMinute($0)) 打包" } ?? ""
        return DoctorCheck("已装版本", .ok, "\(v)（提交 \(commit)）\(built)")
    }

    func running() -> DoctorCheck {
        runner.run(["pgrep", "-x", "DiskSlimApp"], cwd: nil).status == 0
            ? DoctorCheck("应用在跑", .ok, "在跑")
            : DoctorCheck("应用在跑", .bad, "没在跑：提醒、每日记录、自动清理都停了。从访达打开「磁盘瘦身」或点驿窗挂件")
    }

    func status(now: Date) -> DoctorCheck {
        let url = StatusFile.url(home: home)
        guard let data = try? Data(contentsOf: url) else { return DoctorCheck("状态文件", .bad, "没有或读不了：\(url.path)") }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let s = try? d.decode(StatusFile.self, from: data) else { return DoctorCheck("状态文件", .bad, "内容坏了：\(url.path)") }
        let ago = now.timeIntervalSince(s.updatedAt)
        let when = "\(BeijingTime.monthDay(s.updatedAt)) \(BeijingTime.hourMinute(s.updatedAt)) 更新"
        return ago > Self.statusStale
            ? DoctorCheck("状态文件", .warn, "\(when)，超过 15 分钟没更新：应用多半没在跑，驿窗挂件显示的是旧数字")
            : DoctorCheck("状态文件", .ok, when)
    }

    func space() -> DoctorCheck {
        guard let d = diskStatus(of: home) else { return DoctorCheck("可用空间", .warn, "读不到") }
        let text = "\(formatBytes(d.availableBytes)) / 共 \(formatBytes(d.totalBytes))"
        switch SpaceLevel(freeBytes: d.availableBytes) {
        case .ok: return DoctorCheck("可用空间", .ok, text)
        case .low: return DoctorCheck("可用空间", .warn, "\(text)，低于 60 GB")
        case .critical: return DoctorCheck("可用空间", .bad, "\(text)，低于 30 GB")
        }
    }

    /// 五份记录文件：在不在、读不读得了、是不是完整的 JSON。坏了的不挪（只读）
    func records() -> [DoctorCheck] {
        let names: [(String, String)] = [("history.json", "操作记录"), ("usage.json", "每日空间"), ("decisions.json", "保留决定"),
                                         ("alerts.json", "提醒"), ("memory.json", "内存记录")]
        return names.map { file, label in
            let url = dataDir.appendingPathComponent(file)
            let name = "记录：\(label)"
            guard FileManager.default.fileExists(atPath: url.path) else { return DoctorCheck(name, .ok, "还没有（用到时才建）") }
            guard let data = try? Data(contentsOf: url) else { return DoctorCheck(name, .bad, "读不了：\(url.path)") }
            guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
                return DoctorCheck(name, .bad, "内容坏了：\(url.path)（应用下次写入前会改名留底）")
            }
            return DoctorCheck(name, .ok, formatBytes(Int64(data.count)))
        }
    }

    /// 通知权限只有应用自己问得到；这里看提醒有没有真的送达过（L-16：看落盘的送达记录）。
    /// 只认 `deliveredAt`（系统收下才记），不看 `sent`：那里有首次运行预填、周报没卡片记成已处理，和发没发出去无关
    func alerts(now: Date) -> DoctorCheck {
        let state = AlertStore.standard(home: home).load(readOnly: true)
        let hint = "通知权限用已装的应用查（会弹出 4 条标着「示例」的通知）：/Applications/DiskSlim.app/Contents/MacOS/DiskSlimApp --test-notify"
        guard let at = state.deliveredAt else {
            return DoctorCheck("提醒送达", .warn, "还没有送达记录（第四批起才记）。\(hint)")
        }
        let days = BeijingTime.dayNumber(now) - BeijingTime.dayNumber(at)
        let when = "\(BeijingTime.monthDay(at)) \(BeijingTime.hourMinute(at))"
        return days > Self.alertsQuietDays
            ? DoctorCheck("提醒送达", .warn, "最近一次送达是 \(when)，已经 \(days) 天。\(hint)")
            : DoctorCheck("提醒送达", .ok, "最近一次送达是 \(when)")
    }

    func loginShell(_ login: String?) -> DoctorCheck {
        login == nil
            ? DoctorCheck("登录 shell 的 PATH", .warn, "取不到（超时或配置报错）：从访达、挂件启动时可能找不到 uv、pnpm")
            : DoctorCheck("登录 shell 的 PATH", .ok, "取得到")
    }

    /// 已知位置表里的清理命令：按应用从访达启动时的 PATH（短 PATH + 登录 shell 的）用 `which` 找，
    /// 不用终端自己的 PATH：L-16 要抓的正是「终端里找得到、应用里找不到」（审查必须修 2）
    func tools(_ login: String?) -> [DoctorCheck] {
        let path = mergedPath(LoginShell.appBasePath, login)
        var seen: [String] = []
        for p in KnownPlaces.all { if case .command(let args) = p.cleanup, let t = args.first, !seen.contains(t) { seen.append(t) } }
        return seen.map { tool in
            let r = runner.run(["/usr/bin/env", "PATH=\(path)", "which", tool], cwd: nil)
            let path = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return r.status == 0
                ? DoctorCheck("清理命令 \(tool)", .ok, path)
                : DoctorCheck("清理命令 \(tool)", .warn, "应用里找不到：对应的缓存清不了，面板里标「不能清」")
        }
    }
}

/// 打包时写进 Info.plist 的版本信息（第四批 ⑨，`scripts/bundle.sh`）
public enum AppBuild {
    public static let commitKey = "DiskSlimCommit"
    public static let builtAtKey = "DiskSlimBuiltAt"

    /// 正在运行的这份应用：「0.1.0 · 提交 abc1234」；调试版、没写提交号的只有版本号
    public static func label(_ info: [String: Any]?) -> String {
        let v = info?["CFBundleShortVersionString"] as? String ?? "调试版"
        guard let commit = info?[commitKey] as? String else { return v }
        return "\(v) · 提交 \(commit)"
    }
}
