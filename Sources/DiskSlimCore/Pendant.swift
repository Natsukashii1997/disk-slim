import CoreGraphics
import Foundation

// 第 9 批：接进驿窗侧栏。驿窗在随手记猫球下面挂一颗扫帚球（挂件），
// 号码牌上的数字和颜色读这里写的状态文件；点挂件时驿窗用 diskslim:// 链接叫磁盘瘦身把自己的面板开在挂件旁边。
// 两边只通过这个文件和这条链接说话，不开本地网络端口。

extension SpaceLevel {
    /// 写进状态文件的名字，驿窗按它选号码牌颜色
    public var name: String {
        switch self {
        case .ok: "ok"
        case .low: "low"
        case .critical: "critical"
        }
    }
}

/// `~/Library/Application Support/disk-slim/status.json`：可用空间、档位、写入时间。
/// 应用每次读可用空间（打开面板、每 5 分钟、扫描完）都重写一次；驿窗看到超过 1 小时没更新就当作不知道。
public struct StatusFile: Codable, Equatable, Sendable {
    public var version = 1
    public var availableBytes: Int64
    public var totalBytes: Int64
    public var level: String
    public var updatedAt: Date

    public init(disk: DiskStatus, now: Date) {
        availableBytes = disk.availableBytes
        totalBytes = disk.totalBytes
        level = SpaceLevel(freeBytes: disk.availableBytes).name
        updatedAt = now
    }

    public static func url(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/disk-slim/status.json")
    }

    /// 时间写成带时区的 ISO 8601（驿窗那边用 Rust 读）；整份先写临时文件再换上，读的一方不会读到半份
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: .atomic)
    }

    public static func read(from url: URL) -> StatusFile? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(StatusFile.self, from: d)
    }
}

/// 驿窗发来的 `diskslim://panel/toggle?x=…&y=…&w=…&h=…`：挂件那颗球在屏幕上的位置，
/// 单位是点，原点在主屏左上角、y 朝下（驿窗那边的坐标）。
public enum PanelLink {
    public static let scheme = "diskslim"

    /// 解析出挂件的位置（仍是左上原点）；不是这条链接、缺参数、不是有限数或大小不合理时返回 nil
    public static func anchor(from url: URL) -> CGRect? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "panel", url.path == "/toggle",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> Double? {
            guard let s = items.first(where: { $0.name == name })?.value, let v = Double(s), v.isFinite else { return nil }
            return v
        }
        guard let x = value("x"), let y = value("y"), let w = value("w"), let h = value("h"),
              w > 0, h > 0, w <= 400, h <= 400, abs(x) < 100_000, abs(y) < 100_000 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// 左上原点（y 朝下）换成 AppKit 的左下原点（y 朝上）；`primaryHeight` 是主屏的高
    public static func appKitRect(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}

/// 点驿窗挂件的那一下，对磁盘瘦身来说也是「点了面板外面」：全局点击监听先把面板收起，
/// 紧接着链接才到。判断是不是同一下，看收起面板的那次点击是不是落在挂件上，而不是只靠时间猜：
/// 机器卡的时候链接可能晚到一两秒，点别处收起后马上去点挂件也不该被吞掉。
public enum PanelToggle {
    public enum Action: Equatable, Sendable { case open, close, none }

    /// 因为点了外面而收起：那次点击的位置（和挂件同一套屏幕坐标）和时间（开机后的秒数，不受改系统时间影响）
    public struct OutsideClick: Equatable, Sendable {
        public var point: CGPoint
        public var uptime: TimeInterval
        public init(point: CGPoint, uptime: TimeInterval) {
            self.point = point
            self.uptime = uptime
        }
    }

    /// 收起后多久内到的链接还可能是同一下点击（链接经 LaunchServices 转一道，机器卡时会慢）
    public static let window: TimeInterval = 3
    /// 点击位置和挂件之间的容差（点）：鼠标按下后可能轻微移动，挂件也可能刚好在晃
    public static let slack: CGFloat = 6

    public static func decide(isOpen: Bool, lastOutside: OutsideClick?, anchor: CGRect, now: TimeInterval) -> Action {
        if isOpen { return .close }
        if let c = lastOutside, now >= c.uptime, now - c.uptime < window,
           anchor.insetBy(dx: -slack, dy: -slack).contains(c.point) { return .none }
        return .open
    }
}
