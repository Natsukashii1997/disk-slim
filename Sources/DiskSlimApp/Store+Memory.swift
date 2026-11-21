import AppKit
import DiskSlimCore
import Foundation

// 第 11 批：内存页的读数和动作（docs/PRD.md 3.6、4.4、第 5 节）。
// 退出程序只在用户点了按钮之后；强制退出要点两次；不清系统缓存，不用 sudo。

extension Store {
    /// 记每个应用最后一次被切到前台的时间（应用常驻，所以能一直记）
    func startMemoryTracking() {
        guard !readOnly, activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let id = app.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                self.mem.record.activated(id, at: Date())
                self.saveMemoryRecord()
            }
        }
    }

    func saveMemoryRecord() {
        guard !readOnly else { return }
        try? memoryLog.save(mem.record)
    }

    /// 读一次内存（打开面板、切到内存页、退出程序之后）；不记曲线点
    func refreshMemory(then done: (@MainActor () -> Void)? = nil) {
        let apps = RunningApps.current()
        memGeneration += 1
        let generation = memGeneration
        mem.reading = true
        let started = Date()
        Task.detached {
            let status = readMemoryStatus()
            let usage = MemoryAttribution.usage(listProcesses(), apps: apps)
            await MainActor.run {
                // 后发的那次已经回来过了：这份是旧的，不用它（done 照样调，免得等它的动作卡住）
                if generation == self.memGeneration {
                    self.applyMemory(status: status, usage: usage)
                    // 读内存往往不到半秒：↻ 至少转 0.8 秒，点了能看出来
                    let rest = max(0, 0.8 - Date().timeIntervalSince(started))
                    DispatchQueue.main.asyncAfter(deadline: .now() + rest) {
                        MainActor.assumeIsolated { if generation == self.memGeneration { self.mem.reading = false } }
                    }
                }
                done?()
            }
        }
    }

    /// 每 5 分钟一次：读数、记曲线点和会话忙闲、到点发重启提醒
    func sampleMemory() {
        refreshMemory {
            guard !self.readOnly, let status = self.mem.status, let usage = self.mem.usage else { return }
            let now = Date()
            self.mem.record.sample(status, sessions: usage.sessions, apps: usage.apps, at: now)
            self.remindRestartIfDue(now: now)
            self.saveMemoryRecord()
            self.applyMemory(status: status, usage: usage)
        }
    }

    func applyMemory(status: MemoryStatus?, usage: MemoryUsage) {
        mem.status = status
        mem.usage = usage
        mem.at = Date()
        mem.plan = MemoryPlan.make(usage: usage, status: status, record: mem.record, now: Date())
    }

    private func replan() {
        guard let usage = mem.usage else { return }
        mem.plan = MemoryPlan.make(usage: usage, status: mem.status, record: mem.record, now: Date())
    }

    // MARK: 动作

    /// 「一键退出」：先重读一遍，只退出重读后仍在「替你挑好的」里、而且这一下之前就在的那些
    func quitPicked() {
        guard !readOnly, !mem.working, let before = mem.plan?.picked, !before.isEmpty else { return }
        mem.working = true
        refreshMemory {
            let still = (self.mem.plan?.picked ?? []).filter { a in before.contains { $0.app.pid == a.app.pid && $0.app.bundleID == a.app.bundleID } }
            let asked = still.filter { self.terminate($0.app, force: false) }
            self.afterQuit(asked)
        }
    }

    /// 浏览器那一问、强制退出页的「退出」：和 ⌘Q 一样
    func quit(_ a: AppMemory) {
        guard !readOnly, !mem.working else { return }
        mem.working = true
        afterQuit(terminate(a.app, force: false) ? [a] : [])
    }

    /// 强制退出：第一下只是「确认强制退出」，第二下才执行
    func forceQuit(_ a: AppMemory) {
        guard !readOnly else { return }
        if mem.forceArmed != a.key { mem.forceArmed = a.key; return }
        mem.forceArmed = nil
        mem.working = true
        afterQuit(terminate(a.app, force: true) ? [a] : [], forced: true)
    }

    /// 只认 pid 和 bundle id 都对得上的那个进程；系统、磁盘瘦身自己、驿窗不退（MemoryGuard）
    private func terminate(_ app: RunningApp, force: Bool) -> Bool {
        let running = NSRunningApplication(processIdentifier: app.pid)
        guard let running, MemoryGuard.mayTerminate(app, selfPID: getpid(), currentBundleID: running.bundleIdentifier) else { return false }
        return force ? running.forceTerminate() : running.terminate()
    }

    /// 等几秒看是不是真的退出了：还开着的多半在问要不要保存
    private func afterQuit(_ asked: [AppMemory], forced: Bool = false) {
        guard !asked.isEmpty else {
            mem.working = false
            ui.toast = Toast(text: "没有退出任何程序：它们刚被用过或已经关了。", canUndo: false)
            refreshMemory()
            return
        }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let left = asked.filter { a in NSRunningApplication(processIdentifier: a.app.pid).map { !$0.isTerminated } ?? false }
            let gone = asked.filter { a in !left.contains(a) }
            var parts: [String] = []
            if !gone.isEmpty {
                parts.append("\(forced ? "已强制退出" : "已退出") \(gone.map(\.app.name).joined(separator: "、"))，腾出约 \(formatBytes(gone.reduce(0) { $0 + $1.bytes }))")
            }
            if !left.isEmpty { parts.append("\(left.map(\.app.name).joined(separator: "、")) 还没退出，可能在问你要不要保存") }
            self.ui.toast = Toast(text: parts.joined(separator: "；") + (gone.isEmpty ? "" : "。要用时照常打开"), canUndo: false)
            self.mem.working = false
            self.refreshMemory()
        }
    }

    /// 「要你说一句」：`yes` 是主按钮（收掉 / 退出 / 今晚提醒我），否则是第二个（留着 / 还在用 / 这周别问）
    func answer(_ ask: MemoryAsk, yes: Bool) {
        guard !readOnly else { return }
        let now = Date()
        switch ask {
        case .sessions(let keys, let bytes):
            if yes { endSessions(keys, bytes: bytes) } else { mem.record.sessionsQuietUntil = now.addingTimeInterval(86_400) }
        case .browser(let a):
            if yes { quit(a) } else { mem.record.browserQuietUntil[a.app.bundleID] = now.addingTimeInterval(86_400) }
        case .restart:
            if yes {
                let at = MemoryRules.tonight(now)
                mem.record.restartRemindAt = at
                mem.record.restartQuietUntil = at
                ui.toast = Toast(text: "好，\(BeijingTime.hourMinute(at)) 提醒你重启。", canUndo: false)
            } else {
                mem.record.restartQuietUntil = now.addingTimeInterval(7 * 86_400)
            }
        }
        saveMemoryRecord()
        replan()
    }

    /// 收掉闲着的 Claude 会话：给会话进程发「请退出」（SIGTERM），和 Claude 桌面版内存紧时自己回收闲会话是同一个效果；
    /// 下次在 Claude 里给这个会话发消息，它会重新接上（全局坑 G-24）。发之前按 pid + 启动时间再核对一遍
    /// 动手前再看一眼（审查高 1）：隔 3 秒读两次进程，这几秒里、以及上次采样以来忙过的都不收
    private func endSessions(_ keys: [String], bytes: Int64) {
        mem.working = true
        let record = mem.record
        Task.detached {
            let before = listProcesses()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let after = listProcesses()
            let pids = MemoryGuard.quietSessionPids(keys, before: before, after: after, seconds: 3, record: record, now: Date())
            let sizes = Dictionary(MemoryAttribution.usage(after, apps: []).sessions.map { ($0.pid, $0.bytes) }, uniquingKeysWith: { a, _ in a })
            let freed = pids.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
            for pid in pids { kill(pid, SIGTERM) }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                let skipped = keys.count - pids.count
                var text = pids.isEmpty ? "没有收掉任何会话" : "收掉了 \(pids.count) 个闲着的 Claude 会话，腾出约 \(formatBytes(freed))。在 Claude 里给它发消息就会接上"
                if skipped > 0 { text += "；\(skipped) 个刚动过或已经不在了，没收" }
                self.ui.toast = Toast(text: text + "。", canUndo: false)
                self.mem.working = false
                self.refreshMemory()
            }
        }
    }

    private func remindRestartIfDue(now: Date) {
        guard let at = mem.record.restartRemindAt, at <= now, Notifier.shared.available else { return }
        mem.record.restartRemindAt = nil
        mem.record.restartQuietUntil = now.addingTimeInterval(86_400)
        let swap = mem.status.map { formatBytes($0.swapUsedBytes) } ?? "很多"
        Notifier.shared.send(title: "该重启一下电脑了", body: "交换文件占着 \(swap) 磁盘，重启一次就能拿回来，内存也会松快。")
    }
}
