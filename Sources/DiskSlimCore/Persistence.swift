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
