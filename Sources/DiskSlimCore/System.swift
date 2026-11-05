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

/// 文件或目录实际占用的磁盘空间（目录递归累加，不跟随符号链接）。
public func allocatedSize(_ url: URL) -> Int64 {
    let keys: [URLResourceKey] = [.isDirectoryKey, .totalFileAllocatedSizeKey]
    guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
    if values.isDirectory != true { return Int64(values.totalFileAllocatedSize ?? 0) }
    guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
    var total: Int64 = 0
    for case let child as URL in e {
        total += Int64((try? child.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
    }
    return total
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

    public init(timeout: TimeInterval = 120) { self.timeout = timeout }

    public func run(_ args: [String], cwd: URL?) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        var env = ProcessInfo.processInfo.environment
        // 从菜单栏应用启动时 PATH 很短，补上 Homebrew 的位置
        env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
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
    /// 图表横轴用，如「11/5」
    public static func shortDay(_ date: Date) -> String { shortDayFormatter.string(from: date) }
    public static func hourMinute(_ date: Date) -> String { timeFormatter.string(from: date) }
}

/// 按 1024 进位，和 `du -h`、访达一致的写法：「43 MB」「6.2 GB」。
public func formatBytes(_ bytes: Int64) -> String {
    let mb = Double(bytes) / 1_048_576
    if mb < 1 { return "\(max(bytes / 1024, bytes > 0 ? 1 : 0)) KB" }
    if mb < 1024 { return "\(Int(mb.rounded())) MB" }
    return String(format: "%.1f GB", mb / 1024)
}
