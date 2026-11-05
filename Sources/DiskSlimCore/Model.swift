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

/// 这一项要怎么清。第 1 批只记录，第 2 批执行。
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

    public init(area: Area, category: String, title: String, detail: String,
                paths: [String], bytes: Int64, risk: Risk, suggested: Bool, cleanup: Cleanup) {
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
    }
}

public struct DiskStatus: Codable {
    public let totalBytes: Int64
    public let availableBytes: Int64
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

    public init(scannedAt: Date, seconds: Double, disk: DiskStatus?, findings: [Finding], downloadsBytes: Int64? = nil, trashBytes: Int64? = nil) {
        self.scannedAt = scannedAt
        self.seconds = seconds
        self.disk = disk
        self.findings = findings
        self.downloadsBytes = downloadsBytes
        self.trashBytes = trashBytes
    }

    public var suggestedBytes: Int64 {
        findings.filter(\.suggested).reduce(0) { $0 + $1.bytes }
    }
}
