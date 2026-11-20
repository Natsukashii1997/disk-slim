import Foundation

/// 用操作记录校正「清理命令」类的项：命令能腾出多少事先算不准（pnpm 只删没人用的包、
/// Homebrew 会留着自己要用的），目录有多大不等于能清多少。
/// 最近 `days` 天里同一条命令上次实际释放不到 `minFreed`，就不再默认勾选，并写明上次的结果。
public func applyHistory(_ findings: [Finding], history: [Batch], now: Date,
                         days: Double = 30, minFreed: Int64 = 10 * 1_048_576) -> [Finding] {
    findings.map { f in
        guard case .command = f.cleanup, f.suggested else { return f }
        let last = history
            .filter { now.timeIntervalSince($0.at) < days * 86_400 }
            .sorted { $0.at > $1.at }
            .lazy
            .compactMap { b in b.items.first { $0.cleanup == f.cleanup && $0.outcome == .done }.map { (b.at, $0) } }
            .first
        guard let (at, item) = last, item.freedBytes < minFreed else { return f }
        return f.revised(detail: "\(BeijingTime.monthDay(at))清理过，只释放了 \(formatBytes(item.freedBytes))，剩下的都还在用", suggested: false)
    }
}
