import CoreServices
import Foundation

// MARK: - 文件元数据

/// 下载区规则要用的三样元数据。测试里换成假的。
public protocol FileMetadata {
    func dateAdded(_ url: URL) -> Date?
    func lastUsed(_ url: URL) -> Date?
    func tags(_ url: URL) -> [String]
}

/// 真实实现：Spotlight 的 kMDItemDateAdded / kMDItemLastUsedDate，Finder 标签。
public struct SpotlightMetadata: FileMetadata {
    public init() {}

    public func dateAdded(_ url: URL) -> Date? {
        if let d = attribute(url, kMDItemDateAdded) as? Date { return d }
        return (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate
    }

    public func lastUsed(_ url: URL) -> Date? {
        attribute(url, kMDItemLastUsedDate) as? Date
    }

    public func tags(_ url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    private func attribute(_ url: URL, _ key: CFString) -> Any? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, key)
    }
}

// MARK: - 占用大小

/// 文件或目录实际占用的磁盘空间（目录递归累加，不跟随符号链接）。读不了的部分按 0 算。
public func allocatedSize(_ url: URL) -> Int64 { measure(url, onError: {}) }

/// 同上，出错时调 `onError`
private func measure(_ url: URL, onError: () -> Void) -> Int64 {
    let keys: [URLResourceKey] = [.isDirectoryKey, .totalFileAllocatedSizeKey]
    guard let values = try? url.resourceValues(forKeys: Set(keys)) else { onError(); return 0 }
    if values.isDirectory != true { return Int64(values.totalFileAllocatedSize ?? 0) }
    var failed = false
    guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                  errorHandler: { _, _ in failed = true; return true }) else { onError(); return 0 }
    var total: Int64 = 0
    for case let child as URL in e {
        if let v = try? child.resourceValues(forKeys: [.totalFileAllocatedSizeKey]) {
            total += Int64(v.totalFileAllocatedSize ?? 0)
        } else { failed = true }
    }
    if failed { onError() }
    return total
}

/// 同上，但有任何一处读不了（没权限、读出错）就返回 nil：每日记录用，免得把「没量到」记成 0
public func allocatedSizeIfReadable(_ url: URL) -> Int64? {
    var failed = false
    let size = measure(url) { failed = true }
    return failed ? nil : size
}

/// 目录和往下 `depth` 层里最新的修改时间（不往深处走，免得扫整个镜像）
public func latestModification(_ url: URL, depth: Int = 2) -> Date? {
    let keys: Set<URLResourceKey> = [.contentModificationDateKey]
    var latest = (try? url.resourceValues(forKeys: keys))?.contentModificationDate
    guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [],
                                                 errorHandler: { _, _ in true }) else { return latest }
    for case let u as URL in e {
        if e.level >= depth { e.skipDescendants() }
        if let d = (try? u.resourceValues(forKeys: keys))?.contentModificationDate, d > (latest ?? .distantPast) { latest = d }
    }
    return latest
}

/// 目录在、但被系统隐私保护拦住（EPERM，要「完全磁盘访问权限」）。不存在、普通的权限位读不了（EACCES）都不算
public func blockedByPrivacy(_ url: URL) -> Bool {
    do {
        _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
        return false
    } catch let e as NSError {
        let posix = (e.userInfo[NSUnderlyingErrorKey] as? NSError) ?? e
        return posix.domain == NSPOSIXErrorDomain && posix.code == Int(EPERM)
    }
}

/// 跨进程互斥：在 `<文件>.lock` 上拿排他 flock，把一次「读 → 改 → 写」包起来（应用和命令行可能同时写同一个记录文件）
public func withFileLock<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(url.path + ".lock", O_CREAT | O_RDWR, 0o644)
    if fd >= 0 { flock(fd, LOCK_EX) }
    defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
    return try body()
}

public func diskStatus(of url: URL) -> DiskStatus? {
    guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
          let total = v.volumeTotalCapacity, let available = v.volumeAvailableCapacity else { return nil }
    return DiskStatus(totalBytes: Int64(total), availableBytes: Int64(available))
}

// MARK: - 外部命令

/// 跑 git / gh / ps 等命令。测试里换成假的。
public protocol CommandRunner {
    /// 返回退出码和标准输出；命令不存在时退出码非 0。
    func run(_ args: [String], cwd: URL?) -> (status: Int32, output: String)
}

public struct ProcessRunner: CommandRunner {
    /// 超时就结束进程并返回退出码 124，免得 gh 卡在网络上时扫描一直转圈
    let timeout: TimeInterval

    /// 原有的 PATH；nil 时用本进程的。`diskslim doctor` 传应用从访达启动时的短 PATH，查到的才和应用里一样
    let basePath: String?

    public init(timeout: TimeInterval = 120, basePath: String? = nil) {
        self.timeout = timeout
        self.basePath = basePath
    }

    public func run(_ args: [String], cwd: URL?) -> (status: Int32, output: String) {
        var env = ProcessInfo.processInfo.environment
        // 从访达、登录项、驿窗挂件启动时 PATH 很短：并上登录 shell 的 PATH（uv 在 ~/.local/bin、pnpm 在 nvm 目录下）和 Homebrew 的位置（L-16）
        env["PATH"] = mergedPath(basePath ?? env["PATH"], LoginShell.cached())
        // 从访达 / 登录项启动时没有区域设置，ps 会把路径里的中文转义成 M-dM-8…，和路径对不上（L-09）
        env["LC_ALL"] = "en_US.UTF-8"
        return execute(URL(fileURLWithPath: "/usr/bin/env"), args, env: env, cwd: cwd, timeout: timeout)
    }
}

/// 跑一个程序，读完标准输出；超时就结束它、返回退出码 124，起不来返回 127
func execute(_ executable: URL, _ args: [String], env: [String: String], cwd: URL? = nil,
             timeout: TimeInterval) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = executable
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return (127, "") }
    // 在后台读完输出，避免输出塞满管道卡死；主线等读完或超时
    var data = Data()
    let done = DispatchGroup()
    done.enter()
    DispatchQueue.global().async {
        data = out.fileHandleForReading.readDataToEndOfFile()
        done.leave()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        _ = done.wait(timeout: .now() + 2)
        return (124, "")
    }
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// 合并 PATH：原有的在前，再接登录 shell 里有、原来没有的，最后补 Homebrew 的两个位置；重复的、空的、不是绝对路径的去掉
public func mergedPath(_ current: String?, _ login: String?) -> String {
    var seen = Set<String>()
    var parts: [String] = []
    for dir in [current ?? "/usr/bin:/bin", login ?? "", "/opt/homebrew/bin:/usr/local/bin"].flatMap({ $0.split(separator: ":") }) {
        let d = String(dir)
        guard d.hasPrefix("/"), seen.insert(d).inserted else { continue }
        parts.append(d)
    }
    return parts.joined(separator: ":")
}

/// 用户的登录 shell 里 PATH 是什么。应用不是从终端启动时拿不到这些（L-16）。
public enum LoginShell {
    static let marker = "__DISKSLIM_PATH__"
    /// 应用从访达启动时的 PATH（没有登录 shell 那些）
    public static let appBasePath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// 进程里共用的一份（第四批 ①）。只在后台跑命令时用到（扫描、清理、撤销都在 `Task.detached` 里），第一次最多等 `path` 的超时
    static let shared = Cache()

    public static func cached() -> String? { shared.get(now: Date()) { path() } }

    /// 取成功就一直用；取失败隔 10 分钟再试：开机自启那一刻机器忙、超时很常见，
    /// 不能一次失败就整个运行期间都找不到 uv、pnpm（审查建议 3）
    final class Cache: @unchecked Sendable {
        static let retryAfter: TimeInterval = 600
        private let lock = NSLock()
        private var hit: String?
        private var missedAt: Date?

        func get(now: Date, resolve: () -> String?) -> String? {
            lock.lock(); defer { lock.unlock() }
            if let hit { return hit }
            if let missedAt, now.timeIntervalSince(missedAt) < Self.retryAfter { return nil }
            hit = resolve()
            missedAt = hit == nil ? now : nil
            return hit
        }
    }

    /// 跑 `<shell> -l -c` 打印 PATH，只取标记后面的部分（配置文件往标准输出打的字不算）。
    /// 不用 `-i`：交互式配置（nvm 等）在本机要 9 秒，还可能等输入。10 秒没回来、退出码不是 0、结果不像 PATH 时返回 nil。
    public static func path(shell: String? = ProcessInfo.processInfo.environment["SHELL"], timeout: TimeInterval = 10) -> String? {
        let sh = (shell?.hasPrefix("/") == true) ? shell! : "/bin/zsh"
        var env = ["HOME": NSHomeDirectory(), "USER": NSUserName(), "SHELL": sh, "LC_ALL": "en_US.UTF-8"]
        if let p = ProcessInfo.processInfo.environment["PATH"] { env["PATH"] = p }
        let r = execute(URL(fileURLWithPath: sh), ["-l", "-c", "printf '\\n\(marker)%s' \"$PATH\""], env: env, timeout: timeout)
        guard r.status == 0, let range = r.output.range(of: marker, options: .backwards) else { return nil }
        let value = r.output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("/"), !value.contains("\n") else { return nil }
        return value
    }
}

/// 从 `root` 往下到 `path` 的每一层里，有没有符号链接。`includingLast` 为 false 时不看最后一层本身。
/// `root` 自己是不是链接不管（那是用户配置的位置）。
public func hasSymlink(_ path: String, under root: URL, includingLast: Bool = true) -> Bool {
    let rootParts = root.standardizedFileURL.pathComponents
    let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    guard parts.count > rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts else { return true }
    let last = includingLast ? parts.count : parts.count - 1
    var current = root.standardizedFileURL
    for i in rootParts.count..<parts.count {
        current.appendPathComponent(parts[i])
        guard i < last else { break }
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil { return true }
    }
    return false
}

// MARK: - 显示格式

/// 界面上的日期统一按北京时间显示（全局坑 G-02）。
public enum BeijingTime {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "M 月 d 日"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "M/d"
        return f
    }()

    public static func monthDay(_ date: Date) -> String { formatter.string(from: date) }
    /// 北京时间的日期，按天归并记录用，如「2026-11-05」
    public static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }
    /// 北京时间第几天（从 1970-01-01 算起）。北京没有夏令时，按 +8 小时整除即可；用来算相隔几天
    public static func dayNumber(_ date: Date) -> Int { Int(((date.timeIntervalSince1970 + 8 * 3600) / 86_400).rounded(.down)) }
    /// 把 `dayKey` 的写法读回日期（当天北京时间 0 点）；格式不对返回 nil
    public static func date(dayKey: String) -> Date? { dayFormatter.date(from: dayKey) }
    /// 图表横轴用，如「11/5」
    public static func shortDay(_ date: Date) -> String { shortDayFormatter.string(from: date) }
    public static func hourMinute(_ date: Date) -> String { timeFormatter.string(from: date) }
}

/// 按 1024 进位，和 `du -h` 一致（访达按 1000 进位，同一块盘在访达里的数更大）：「43 MB」「6.2 GB」。
public func formatBytes(_ bytes: Int64) -> String {
    let mb = Double(bytes) / 1_048_576
    if mb < 1 { return "\(max(bytes / 1024, bytes > 0 ? 1 : 0)) KB" }
    if mb < 1024 { return "\(Int(mb.rounded())) MB" }
    return String(format: "%.1f GB", mb / 1024)
}

/// 带正负号的变化量：「+2.8 GB」「−340 MB」
public func formatDelta(_ bytes: Int64) -> String {
    (bytes < 0 ? "−" : "+") + formatBytes(bytes == .min ? .max : abs(bytes))
}
