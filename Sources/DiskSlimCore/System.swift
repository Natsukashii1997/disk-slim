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
    public init() {}

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
        // 先读完再等退出，避免输出塞满管道卡死
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
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

    public static func monthDay(_ date: Date) -> String { formatter.string(from: date) }
}

/// 按 1024 进位，和 `du -h`、访达一致的写法：「43 MB」「6.2 GB」。
public func formatBytes(_ bytes: Int64) -> String {
    let mb = Double(bytes) / 1_048_576
    if mb < 1 { return "\(max(bytes / 1024, bytes > 0 ? 1 : 0)) KB" }
    if mb < 1024 { return "\(Int(mb.rounded())) MB" }
    return String(format: "%.1f GB", mb / 1024)
}
