import Foundation

// 记录文件（history / usage / decisions / alerts / memory .json）读写时共用的小工具。
// 跨进程的文件锁 `withFileLock` 在 System.swift。

/// 解码失败时得到 nil，不让一条坏数据拖垮整份
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(T.self) }
}

/// 文件在但读不了时抛错：用户数据文件写之前调用，免得把读不到的旧内容覆盖掉
func refuseIfUnreadable(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path), (try? Data(contentsOf: url)) == nil {
        throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url.path])
    }
}

/// 读一次记录文件的结果
public struct Loaded<Value> {
    /// 读出来的内容；没有文件、读不了、内容坏了时为 nil
    public let value: Value?
    /// 内容坏了、已改名留底的位置
    public let backup: URL?
    /// 文件在但读不了（权限、读错误），或坏了却挪不走。`update` 遇到它会拒写；`save` / `write` 只拦「读不了」
    public let unreadable: Bool
}

/// 一个 JSON 记录文件：五份记录（操作记录、每日空间、保留决定、提醒、内存）共用同一套读、留底、加锁写。
/// - 日期一律存成 ISO 8601 文本，北京时间显示另由 `BeijingTime` 负责。
/// - 内容坏了先改名留底成 `<名字>-damaged-<时间>-<8位>.json.bak` 再当没有记录，下次写入就不会把它覆盖掉（L-06、L-08）。
/// - 写都在 `<文件>.lock` 的跨进程锁里，应用和命令行同时写时不会互相覆盖。
public struct RecordFile<Value: Codable> {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// `readOnly` 为 true 时（命令行查看、离屏截图、扫描时顺带读）坏文件不挪，只当没有记录
    public func load(readOnly: Bool = false) -> Loaded<Value> {
        guard FileManager.default.fileExists(atPath: url.path) else { return Loaded(value: nil, backup: nil, unreadable: false) }
        guard let data = try? Data(contentsOf: url) else { return Loaded(value: nil, backup: nil, unreadable: true) }
        if let value = try? Self.decoder.decode(Value.self, from: data) { return Loaded(value: value, backup: nil, unreadable: false) }
        if readOnly { return Loaded(value: nil, backup: nil, unreadable: false) }
        guard let backup = try? setAside() else { return Loaded(value: nil, backup: nil, unreadable: true) }
        return Loaded(value: nil, backup: backup, unreadable: false)
    }

    /// 整份写入（加锁）
    public func save(_ value: Value) throws {
        try withFileLock(url) { try write(value) }
    }

    /// 加锁后「读 → 改 → 写」：`change` 拿到的是锁内重读的最新内容。
    /// 文件在但读不了时抛错不写。
    @discardableResult
    public func update(_ change: (Loaded<Value>) throws -> Value) throws -> Value {
        try withFileLock(url) {
            let latest = load()
            if latest.unreadable { throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
            let value = try change(latest)
            try write(value)
            return value
        }
    }

    /// 不加锁的写：只在已经拿着锁时用（`update`、撤销）
    public func write(_ value: Value) throws {
        try refuseIfUnreadable(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(value).write(to: url, options: .atomic)
    }

    private func setAside() throws -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(name)-damaged-\(stamp)-\(UUID().uuidString.prefix(8)).json.bak")
        try FileManager.default.moveItem(at: url, to: backup)
        return backup
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
