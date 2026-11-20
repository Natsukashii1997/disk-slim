import Foundation

/// 在哪一块找到的：看得见的下载文件夹，还是看不见的缓存与构建产物。
public enum Area: String, Codable {
    case downloads
    case hidden
}

/// 风险等级（docs/PRD.md 4.2）。
public enum Risk: String, Codable {
    /// 可再生，删了会自动重新生成
    case safe
    /// 需要用户逐项确认
    case confirm
    /// 只展示，工具永不删除
    case readOnly
}

/// 这一项要怎么清。
public enum Cleanup: Codable, Equatable {
    /// 移到废纸篓（用户文件一律走这条）
    case trash
    /// 直接删除可再生的目录（构建产物、浏览器下载）
    case remove
    /// 用工具自带的清理命令
    case command([String])
    /// 不能清
    case none
}

extension Cleanup {
    /// 真能执行：不是「不能清」，也不是空命令
    public var runnable: Bool {
        switch self {
        case .none: return false
        case .command(let args): return !args.isEmpty
        default: return true
        }
    }
}

public struct Finding: Codable, Identifiable {
    public let id: String
    public let area: Area
    /// 分组名，界面按它分组，如「安装包」
    public let category: String
    public let title: String
    public let detail: String
    public let paths: [String]
    public let bytes: Int64
    public let risk: Risk
    /// 是否默认勾选
    public let suggested: Bool
    public let cleanup: Cleanup
    /// 最近一次用过的时间（虚拟机这类按「还用不用」判断的才有）
    public var lastUsed: Date?

    public init(area: Area, category: String, title: String, detail: String,
                paths: [String], bytes: Int64, risk: Risk, suggested: Bool, cleanup: Cleanup, lastUsed: Date? = nil) {
        self.id = category + "|" + paths.joined(separator: "|")
        self.area = area
        self.category = category
        self.title = title
        self.detail = detail
        self.paths = paths
        self.bytes = bytes
        self.risk = risk
        // 安全底线：只展示的项不可能被勾选，也没有清理方式
        self.suggested = risk == .readOnly ? false : suggested
        self.cleanup = risk == .readOnly ? .none : cleanup
        self.lastUsed = lastUsed
    }

    /// 同一项换个说明、勾选状态或清理方式（按历史、按用户的决定、按命令在不在调整时用）；路径、大小、分组不变，`id` 也就不变
    public func revised(detail: String, suggested: Bool) -> Finding {
        revised(detail: detail, suggested: suggested, cleanup: cleanup)
    }

    public func revised(detail: String, suggested: Bool, cleanup: Cleanup) -> Finding {
        Finding(area: area, category: category, title: title, detail: detail, paths: paths, bytes: bytes, risk: risk,
                suggested: suggested, cleanup: cleanup, lastUsed: lastUsed)
    }
}

/// 首页三段（docs/PRD.md 3.2）：替用户判断好，用户只回答「还用不用」。
public enum Bucket: Equatable {
    /// 替你挑好的：默认勾选、能执行，一键清
    case picked
    /// 要你说一句：只有用户知道还要不要（下载里久没打开的文件、一个月没用的虚拟机）
    case ask
    /// 先不动：在用、留着保底、清了也没用，写明原因
    case keep
    /// 对话记录等只展示的
    case records
}

extension Finding {
    /// 虚拟机多久没用才问用户
    public static let unusedDays = 30

    /// 归到哪一段。`kept` 是用户在卡片上选过「保留」的，一律先不动
    public func bucket(now: Date, kept: Bool = false) -> Bucket {
        if risk == .readOnly { return .records }
        if kept { return .keep }
        if suggested && cleanup.runnable { return .picked }
        if area == .downloads && cleanup.runnable { return .ask }
        if let used = lastUsed, now.timeIntervalSince(used) > Double(Self.unusedDays) * 86_400 { return .ask }
        return .keep
    }
}

/// 可用空间的三档：和驿窗号码牌同一套阈值（低于 60 GB 提醒，低于 30 GB 警告）
public enum SpaceLevel: Sendable {
    case ok, low, critical

    public init(freeBytes: Int64?) {
        guard let freeBytes else { self = .ok; return }
        let gb = Double(freeBytes) / 1_073_741_824
        self = gb < 30 ? .critical : gb < 60 ? .low : .ok
    }
}

public struct DiskStatus: Codable {
    public let totalBytes: Int64
    public let availableBytes: Int64

    public init(totalBytes: Int64, availableBytes: Int64) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }
}

public struct ScanReport: Codable {
    public let scannedAt: Date
    public let seconds: Double
    public let disk: DiskStatus?
    public let findings: [Finding]
    /// 下载文件夹整体占用（涨幅追踪用；旧的扫描结果里没有）
    public var downloadsBytes: Int64?
    /// 废纸篓占用（涨幅追踪用：移到废纸篓的东西清空前还占空间）；读不了时为 nil
    public var trashBytes: Int64?
    /// 因为隐私权限读不了、要「完全磁盘访问权限」的位置（目录不存在、或只是里面个别子项读不了都不算）
    public var needsAccess: [String]?

    public init(scannedAt: Date, seconds: Double, disk: DiskStatus?, findings: [Finding], downloadsBytes: Int64? = nil, trashBytes: Int64? = nil,
                needsAccess: [String]? = nil) {
        self.scannedAt = scannedAt
        self.seconds = seconds
        self.disk = disk
        self.findings = findings
        self.downloadsBytes = downloadsBytes
        self.trashBytes = trashBytes
        self.needsAccess = needsAccess
    }

    public var suggestedBytes: Int64 {
        findings.filter(\.suggested).reduce(0) { $0 + $1.bytes }
    }
}
