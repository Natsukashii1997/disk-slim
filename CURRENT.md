# 当前状态

当前阶段目标：常态维护。第 6 批已收尾：2026-11-19 常浩定 `disk-space-guard` 停用（原目标「第 6 批试用一周收尾，定下 disk-space-guard 去留，之后转常态维护」，2026-11-08 常浩确认，digital-twin#114）。

更新：2026-11-20。整体评估后的第一批整改（issue #18）已随 PR #19 squash 合回 main（`e35d96a`），2026-11-20 23:17 已装机：找不到清理命令的项不再默认勾选、清理命令加「正在装依赖就不清」、构建产物执行前复核补查 Rust 构建目录、文档收口。同一天查实：已装版本的通知权限是「已拒绝」，11-05 以来一条提醒都没发出去；06:03 重启后应用没起来，19:34 已手动启动。钩子的三个 PR（#14、#15、#16）都已合并，`core.hooksPath` 已装回 `scripts/hooks`；#16（commit-msg 钩子换 project-starter 0.5.0，`ccff96c`）当时没写交接节，以 PR 描述为准。Puppeteer 经改动确认后也照 Playwright 改成了需确认。唯一下一步：请常浩在「系统设置 › 通知 › 磁盘瘦身」里打开通知，打开后重跑 `--test-notify`，最后一行要是「已允许」；本机签名变了，下载访问和完全磁盘访问多半也要重给。

之前：2026-11-19。`disk-space-guard` 定为停用（任务保持关闭、不删）。菜单栏图标已去掉，入口只留驿窗侧栏挂件，已随 PR #12 squash 合回 main（`8deed49`）、已装机。之前：2026-11-18。第 0–11 批、缩小键、面板尺寸固定和按钮手感都已合回 main（PR #1、#5、#6、#7、#8）。第 11 批「内存」：「磁盘 | 内存」切换、内存页（定稿一二结合）、一键退出、要你说一句（Claude 会话 / 浏览器 / 重启）、强制退出页，已装机。11-18 19:12 交接会话补做了真屏验收：内存页、强制退出页「退出」和「强制退出」点两下都通过；验收中发现面板切到内存页会长出屏幕底边，已修（`FloatingBall.swift`）并重装复验。常浩看过截图说「开 PR」，开了 PR #7，常浩说「合并」后已 squash 合回 main（`e862639`，2026-11-18 20:00）。20:00 后在新分支 `claude/panel-fixed-size` 做了「面板尺寸固定 + 磁盘顶卡谁占着」和「顶栏按钮点击手感」，已随 PR #8 squash 合回 main（`af6f2a2`，2026-11-18 20:58；PR #7 合并后才做，所以单开了 #8）。（当时的唯一下一步「`disk-space-guard` 要不要停」已在 2026-11-19 定为停用，见下面对应一节。）

## 第一批整改：清不掉却默认勾选的项、三处安全缺口、文档收口（2026-11-20，Claude，常浩看过两份评估后回「做第一批」，Puppeteer 一项单独确认后回「改」，之后回「合并」（经 Agent HUD 送达）；已随 PR #19 squash 合并（`e35d96a`）、已装机（2026-11-20 23:17）、未发布）

- 时间：开工 `2026-11-20 19:33`。★ 来由：当天做了接手成本评估和 Fable 5.2 High 的整体方案评估，合并成三批整改，常浩选先做第一批（issue #18）。
- 改了哪些文件：`Sources/DiskSlimCore/KnownPlaces.swift`（Puppeteer 改成需确认；`applyAvailability`：清理命令找不到的项不勾选、不能勾，说明写去终端怎么清；四条清理命令加 `busyWhen`；新类型 `Busy` 按词解析进程命令行）、`Scan.swift`（扫描接上 `applyAvailability`；执行前复核补查 Rust 构建目录）、`WorktreeScanner.swift`（抽出 `notRustBuild`，扫描和复核共用）、`Cleaner.swift`、`SafetyGuard.swift`（在用特征改用 `Busy`）、`Model.swift`（`Finding.revised`，`History.swift`、`Weekly.swift` 两处重复的重建改用它）、`tests/DiskSlimCoreTests/CleanupCommandTests.swift`（新增 9 项）；文档：`GLOSSARY.md`（新建）、`AGENTS.md`、`docs/PRD.md`、`docs/LESSONS.md`（L-16）、本文件（旧节归档到 `docs/history/CURRENT-2026-11-05至11-07.md`、修正三处过期状态）；过期注释和文案：`Alerts.swift`、`Store.swift`、`System.swift`、`Notifier.swift`（示例通知文案对齐真实文案）、`Package.swift`、`scripts/bundle.sh`。
- 测试：`scripts/test.sh` 原样 `✔ Test run with 300 tests in 39 suites passed`（原 290 项，新增 10 项；新测试先写，实现前编译不过）；`node --test tests/*.test.mjs` 原样 `ℹ pass 10` / `ℹ fail 0`；`node scripts/check-rules.mjs`「通用规则检查通过」；`swift build -c release` `Build complete!`。★
- 验证：真实磁盘只读扫描两次（本 worktree 编出的发布版命令行）。模拟应用的环境 `env -i HOME=$HOME USER=$USER PATH=/usr/bin:/bin:/usr/sbin:/sbin .build/release/diskslim scan`：uv 缓存、pnpm 存储写「没找到 … 命令，这里清不了」，默认勾选 2 项 11.5 GB；终端环境：uv 照常勾选，默认勾选 3 项 11.7 GB。证据 `evidence/batch1-2026-11-20/scan-app-env.txt`、`scan-terminal-env.txt`。验证环境：命令行是真实磁盘上的真实扫描；「应用里」是用命令行加短 PATH 模拟的替身，未在已装应用的面板里看（没装机）。「正在装依赖就不清」「复核补查」只有单元测试（替身通过），没在真实环境里撞一次。
- 通知诊断（真实环境）：`/Applications/DiskSlim.app/Contents/MacOS/DiskSlimApp --test-notify` 四条都是「没有通知权限：Notifications are not allowed for this application」，最后一行「通知权限：已拒绝」（`evidence/batch1-2026-11-20/test-notify.txt`）。19:34 `open -a` 启动应用，`status.json` 恢复更新。打开通知权限要常浩在系统设置里做。
- 独立审查（L-06）：只读审查员没找到会删错东西的问题，报中 3、低 7。已修：中 1（uv 的假设反了：有 `uv run`、uvx 在跑时 `uv cache clean` 会一直等锁，用隔离缓存目录实测到「Cache is currently in-use, waiting…」，改成只要有 uv 进程就先不清；证据 `evidence/batch1-2026-11-20/uv-lock-realtest.txt`）、中 2（在用特征漏掉 `pnpm --filter web install`、`pip3.12 install`、`python -m pip -q install`、`npm add` 等形态：改成按词解析并补全别名）、低（去掉 `pnpm dlx`；`check-ignore` 改查 `target/`，目录已不在时不再误报「没被忽略」，临时仓库实测；`revised` 拆成两个重载，`.none` 不会被当成「不改」；说明文字改成「没找到 … 命令，这里清不了」；补一条用真实 `ProcessRunner` 跑 `which` 的测试）。没修、记为遗留：中 3（应用里 `which pip3` 找到的是命令行工具自带的旧 pip 21.2.4，它不认新 pip 的缓存目录，清不掉；pip 缓存现在只有 2 MB、没列出来，没触发；修法是改成直接删目录，属于换清理方式，等常浩定）；命令行里只是提到安装命令的进程（如 `sh -c "npm install && vite"`）也会拦；变成清不了的项在涨幅排行里点不进下钻页；用假 runner 跑整次扫描的旧测试里命令类项都成了「找不到」，目前没有断言受影响。审查证据 `evidence/batch1-review-2026-11-20/`。
- 装机与验收（2026-11-20 23:17，常浩回「装机」，经 Agent HUD 送达）：`scripts/install.sh` 退出码 0，已装的可执行文件时间 23:17:55，进程在跑，`status.json` 23:17:56 更新（`evidence/batch1-2026-11-20/install.txt`）。验收句「面板『先不动』里 uv、pnpm 两项的说明」：替身通过。用已装的可执行文件离屏渲染，`env -i` 短 PATH 下两项标「不能清」、说明是「没找到 … 命令，这里清不了；装了的话可以在终端里运行 …」，「替你挑好的」里缓存只剩 npm（`snapshot-installed-appenv/`）。没在真实面板上看：控制磁盘瘦身窗口的授权被拒。★ 装机后发现一处和之前说法不一致：经 `open` 启动的应用会带上调用方的 PATH，这时 uv、pnpm 找得到、照常勾选（`snapshot-installed-launchservices/`）；现在运行的这一份就是 `install.sh` 用 `open` 启动的，多半属于这种。「已装应用里 uv、pnpm 一直清不掉」是推断，`history.json` 里没有这种跳过记录；从访达、登录项、驿窗挂件启动时才是短 PATH。已更正 L-16。范围外发现（只在离屏渲染里看到，未在真屏核实）：「先不动的」页里不能勾选的行上下有大块空白。
- 截图：无界面改动，无。只做了电脑版。
- 发布与回读：未发布、未装机。装机后要看：面板「先不动」里 uv、pnpm 两项的说明；打开通知权限后再跑一次 `--test-notify`。
- 与授权不一致之处、遗留问题、范围外发现：① 「Puppeteer 照 Playwright 改成需确认」碰到已定内容（`KnownPlacesTests` 写着 2026-11-19 积压清单组 6「Puppeteer 这次不动，仍是安全、默认勾选」），单独发了改动确认，常浩回「改」后才做：现在是需确认、不默认勾选、不进自动清理，说明改成「删了不会自动重新下载」（按 Puppeteer 的已知行为判断，本机没有 `~/.cache/puppeteer`，没实测）。② 「测试文件按被测对象改名」没做，挪到第二批：几份审查测试里混着多个被测对象，只改文件名不解决问题，要按对象拆开重组。③ 事前没列、做的时候补报的行为变化：在用特征从「含这段字」改成按词解析（先认出程序，再看后面的词里有没有安装类子命令），也作用在 Homebrew 判断上（真实 brew 进程照常命中）。④ 没解决：通知被拒时首页看不到提示；应用没在跑时没有东西会发现；找不到的命令没有去登录 shell 里再找。都列在评估的后续批次里。⑤ `AGENTS.md`「范围外的问题不顺手修」与全局规则第 3 节相反、要不要建 `docs/DECIDED.md`，等常浩定。⑥ 主目录 `.claude/worktrees/` 下还有 `4-decide-for-me`、`agent-abadd0feb190ef9b2` 两个旧 worktree，没动。
- 本轮新坑：L-16。★

## 推送前钩子：从 worktree 推送不再把测试的 git 操作落到本仓库（2026-11-20，Claude，常浩回「停用并修」；已随 PR #15 squash 合并（`457c09d`），无需发布）

- 时间：开工 `2026-11-20 11:36`。★ 来由：今天装的推送前钩子（骨架 0.4.0）从 worktree 推送时，git 把本仓库的位置（`GIT_DIR`）带进钩子，钩子跑的 `tests/hooks.test.mjs` 在临时目录建仓库、提交、推送都继承了它。临时仓库实测：推送的分支多出测试的 3 个提交，主目录变成裸仓库、不能用，测试却全过。本仓库 11:36 检查时还没中招，钩子已临时停用。
- 改了哪些文件：`scripts/hooks/pre-push`（跑检查前 `unset $(git rev-parse --local-env-vars)`）、`tests/hooks.test.mjs`（自己的 git 调用不继承这些变量；新增一条从 worktree 真推的用例，旧钩子下失败）。和骨架 0.4.1（my-skills#116）一致。
- 测试：在本 worktree 里 `sh scripts/hooks/pre-push`（规则检查加本项目的测试命令）退出码 0：`通用规则检查通过`，`node --test tests/*.test.mjs` 原样 `ℹ pass 9` / `ℹ fail 0`，`scripts/test.sh` 通过；`node --test tests/hooks.test.mjs` 单跑 `ℹ pass 4` / `ℹ fail 0`，换回旧钩子时新用例失败（在骨架上验证，见 my-skills#116）。
- 验证环境：替身（临时 git 仓库、本机裸仓库、真实的 worktree 和推送）。本仓库的 `core.hooksPath` 现在是停用状态，本 PR 合并、主目录更新后再装回，装后从 worktree 真推一次再算验收。（2026-11-20 晚复核：PR 已合并，`git config core.hooksPath` 返回 `scripts/hooks`，已装回。）
- 外部前提与实测：依赖 git 在 worktree 里给钩子带 `GIT_DIR`、以及 `git rev-parse --local-env-vars` 列出要清的变量，都在临时仓库实测过。
- 与授权不一致之处、遗留问题、范围外发现：停用钩子用的是 `git config --unset core.hooksPath`，装回是 `git config core.hooksPath scripts/hooks`。
- 本轮新坑：无（跨项目的坑，已向常浩提全局坑提案，未写入）。

## 装提交、推送前的必经检查钩子（2026-11-20，Claude，常浩批复盘 P4、P6「批（按改过的）」；已随 PR #14 squash 合并（`2d1d978`），无需发布）

- 时间：开工 `2026-11-20 11:02`。★ 来由：跨项目复盘 P6「检查脚本接进必经环节」：没有 CI 的仓库装 pre-push 钩子；P4 的 commit-msg 钩子一起装。钩子来自起步骨架 0.4.0（my-skills#112）。
- 改了哪些文件：`scripts/hooks/pre-push`（推送前跑 `node scripts/check-rules.mjs` 和 `node --test tests/*.test.mjs && scripts/test.sh`）、`scripts/hooks/commit-msg` + `commit-msg.mjs`（修复类提交正文要有「同类：」一行）、`tests/hooks.test.mjs`（单测 + 临时仓库真跑）、`AGENTS.md`（加安装命令 `git config core.hooksPath scripts/hooks`）；本文件。
- 测试：`node --test tests/hooks.test.mjs` 原样 `ℹ pass 3` / `ℹ fail 0`；在本 worktree 里 `sh scripts/hooks/pre-push` 退出码 0（证据 `~/session-retro/2026-10-18_2026-11-18/evidence/p6-hooks/disk-slim.txt`）。
- 验证环境：替身（临时 git 仓库、本机裸仓库）；本仓库的 `core.hooksPath` 合并后才在本机装，装后真推一次再算验收。
- 外部前提与实测：依赖 git 的 `core.hooksPath` 和钩子退出码，已在临时仓库实测。
- 与授权不一致之处、遗留问题、范围外发现：无。
- 本轮新坑：无。

## 定下 disk-space-guard 停用（2026-11-19，Claude，常浩问「停不停是啥意思」，听完解释说「就停，记下来」；已提交、无需发布）

- 时间：开工 `2026-11-19 15:50`（按会话记录；写交接时 `date '+%F %H:%M'` 为 15:58）。★ 来由：PRD 第 6 批约定试用一周后问常浩要不要停每日巡检任务 `disk-space-guard`（Claude 桌面应用定时任务，`~/.claude/scheduled-tasks/disk-space-guard`，每天 10:05 查空间、低于 60 GB 自动清构建产物和包缓存）。
- 改了哪些文件：本文件（阶段目标改为常态维护、本节）、`docs/PRD.md`（第 7 节第 6 批一行补结论）。没改定时任务本身。
- 测试：`node --test tests/*.test.mjs` 原样结果 `ℹ pass 5` / `ℹ fail 0`；`node scripts/check-rules.mjs` 输出「通用规则检查通过」。没改代码，Swift 测试未跑。
- 验证：`list_scheduled_tasks` 读到 `disk-space-guard` 为 `enabled: false`，最后一次运行 `2026-11-15 10:05`（北京时间）；之后是谁关的查不到，推断是常浩在定时任务里手动关的。文档原写「还没停」，和现状不符，这次以常浩的决定为准，统一成「停用」。
- 截图：无。
- 发布与回读：无需发布。任务保持关闭、没删，想恢复在 Claude 桌面应用的定时任务里重新打开即可。
- 与授权不一致之处、遗留问题、范围外发现：
  - 停用后没有任何东西会每天自动清理：磁盘瘦身的「自动清理缓存和构建产物」默认关，空间少了只发通知。要保留每天自动清，常浩自己在提醒设置里打开。
  - 老任务清的 `brew cleanup -s`、Playwright 浏览器，磁盘瘦身的自动清理不包括（Playwright 自 PR #9 起是「需确认」）。
  - 验收标准「用户使用一周无误删」：常浩没报过误删，我没逐条核对操作记录。
- 本轮新坑：无。

## 去掉菜单栏图标，入口只留驿窗侧栏挂件（2026-11-19，Claude，常浩发截图说「取消上面这个，不用呈现，只保留我侧边的按钮一个入口就行」，之后说「提交并开 PR」「合并」；已随 PR #12 squash 合并（`8deed49`）、已装机、未发布）

- 时间：开工 `2026-11-19 11:45`（按会话记录；写交接时 `date '+%F %H:%M'` 为 12:01）。★ 来由：菜单栏上的「57G」和侧栏挂件重复，常浩只要侧边的扫帚浮游兽一个入口。
- 改了哪些文件：
  - `Sources/DiskSlimApp/DiskSlimApp.swift`：去掉 `MenuBarExtra` 和 `MenuBarLabel`；不再用 SwiftUI `App`，改成 `@main enum DiskSlimMain` 直接跑 `NSApplication`（用空设置场景占位会弹出透明的「Settings」窗口，L-15）；`Store`、悬浮球、每日循环改在 `AppDelegate` 启动完时建。
  - `Sources/DiskSlimApp/FloatingBall.swift`、`Views.swift`：删掉只给菜单栏弹窗用的收起代码（`collapse`、`WindowBox`、`WindowReader`、`dismiss`），缩小键直接 `closePanel()`；提醒设置页三处说明改掉菜单栏说法。
  - `Sources/DiskSlimCore/Alerts.swift`、`Sources/DiskSlimApp/Notifier.swift`：通知文字「点菜单栏的磁盘瘦身」改成「点侧边的扫帚浮游兽」。
  - 注释、命令行提示、一个测试名里的「菜单栏」：`FloatGeometry.swift`、`System.swift`、`Scan.swift`、`DiskSlimCLI/main.swift`、`FloatGeometryTests.swift`。
  - `docs/PRD.md`（第 3 节开头、3.1、3.4、3.5）、`AGENTS.md`、`docs/LESSONS.md`（L-15）、本文件。
- 测试：`scripts/test.sh` 原样结果 `✔ Test run with 290 tests in 37 suites passed`（`test-2.log`）；`node --test tests/*.test.mjs` 原样结果 `ℹ pass 5` / `ℹ fail 0`；`node scripts/check-rules.mjs` 输出「通用规则检查通过」；`--snapshot` 离屏截图照常出 31 张、退出码 0。
- 验证（装机后真屏）：
  - 菜单栏：辅助功能查进程的菜单栏条数，磁盘瘦身为 0（对照：菜单栏有图标的微信是 2）。截图对比不可靠：常浩的菜单栏有收纳工具，装前「57G」被收在「«」里。
  - 第一次装机发现多了「磁盘瘦身 Settings」透明窗口（900×450），改成 AppKit 启动后重装，刚启动时按进程号列全部窗口为空。
  - 用挂件发的同一种链接 `diskslim://panel/toggle` 连发 3 次，`status.json` 的 `panelOpen` 按 true → false → true 交替；面板开在 x=70 y=60、368×810，扫描结果正常（`panel-open.png`）。中途两次对不上，是采样那几秒常浩在点别处，面板按「点了外面」收起。
  - 真实鼠标点顶栏「—」：悬停有淡灰底（`minus-zone.png`），点下 `panelOpen` true → false。
  - 没在驿窗里亲手点挂件验，只用了它发的同一条链接。
- 截图：`~/Library/Application Support/disk-slim/evidence/2026-11-19-no-menubar/`。
- 发布与回读：未发布。`scripts/install.sh` 两次退出码 0（`install-1.log`、`install-2.log`），只有一个进程。签名又变了，「完全磁盘访问权限」要删旧条目再加。
- 与授权不一致之处、遗留问题、范围外发现：
  - 驿窗没开、悬浮球又关着时，面板没有入口（以前还能点菜单栏）。没加别的补救入口，等常浩定。
  - 没有 `docs/DECIDED.md`；菜单栏图标原是 PRD 3.1 定的，这次按常浩本轮点名去掉。
- 本轮新坑：L-15。

## 顶栏 ↻ 和 — 加点击手感（2026-11-18，Claude，常浩说「右上角按钮点击要有点击的质感，现在都不知道有没有点」，看过三版预览说「选甲 系统灰底」，之后说「看过了，提交」「开新 PR」「合并」；已随 PR #8 squash 合并（`af6f2a2`）、已装机、未发布）

- 时间：开工 `2026-11-18 20:30`（按会话记录；写交接时 `date '+%F %H:%M'` 为 20:51）。★ 来由：点 ↻、— 没有任何按下的变化，扫描要十几秒，看不出点上没有。三版预览 `docs/design/ui-v10-button-press.html`（https://claude.ai/artifact/TDMgKsbAfgmMDVwmtrnAY5），三版平时样子都不变（缩小键定稿「同款线条、无底」不动），选甲。
- 改了哪些文件：
  - `Sources/DiskSlimApp/Views.swift`：新增 `TopBarButton`（22×22 圆角 6 的底，悬停黑 6%、按下黑 14%，图标变深；上下各收回 4 点，顶栏不变高；悬停状态用 `@StateObject`，因为 `@State` 宏插件用不了）和 `Spinning`（`TimelineView` 一圈 0.9 秒）；顶栏 ↻ 和 — 改用它，缩小键原来手写的 18×18 点击区由样式统一给 22×22。
  - `Sources/DiskSlimApp/Store.swift`：加 `memReading`；`MemoryStore.swift` 的 `refreshMemory` 开始时置 true，最新一次读完、且满 0.8 秒后置 false（读内存往往不到半秒，太快看不出转）。
  - `docs/PRD.md` 3.2、`docs/design/ui-v10-button-press.html`、本文件。
- 测试：`scripts/test.sh` 原样结果 `✔ Test run with 289 tests in 37 suites passed`（`test-2.log`）；`node --test tests/*.test.mjs` 原样结果 `ℹ pass 4` / `ℹ fail 0`；`node scripts/check-rules.mjs` 输出「通用规则检查通过」。
- 验证：装机后真屏（面板开在左侧 x=74，点前 `topat` 确认最上层是磁盘瘦身），用新写的 `mouse` 分开发移动、按下、松开的真实事件：
  - 「—」平时无底 → 停上去淡灰底 → 按住灰底加深 → 拖出去再松手不触发、恢复无底，面板没收起（`real2/states-min.png`）。悬浮面板不在前台时悬停也有效（预览里担心的情况没出现）。
  - 内存页点 ↻：0.15 秒、0.45 秒两张截图图标角度不同（在转），约 2 秒后停在正位；鼠标移开灰底消失（`real2/states-refresh.png`）。
  - 磁盘页 ↻ 一直在转：重装后系统又弹「想访问“下载”文件夹」，扫描停在「正在扫描…」等授权，转圈如实反映这个状态。
- 截图：`~/Library/Application Support/disk-slim/evidence/2026-11-18-fixed-size/real2/`。
- 发布与回读：未发布。`scripts/install.sh` 退出码 0（`install-2.log`），只有一个进程。签名又变了，「下载」访问、完全磁盘访问权限、通知权限要常浩重给。
- 与授权不一致之处、遗留问题、范围外发现：
  - 内存页 ↻ 至少转 0.8 秒是我加的（预览里只写「扫描中一直转」），为了点了能看出来。
  - 每 5 分钟后台读一次内存时，内存页开着的话 ↻ 也会转 0.8 秒。
  - 下钻页左上「返回」没加同样的手感，这次没要求，没动。
- 本轮新坑：无。

## 面板尺寸固定 + 磁盘顶卡补「谁占着」（2026-11-18，Claude，常浩发截图要求「磁盘页和内存页大小一致，切换不变大小，多的折叠或滚动」并说磁盘页可补信息，之后说「看过了，提交」「开新 PR」「合并」；已随 PR #8 squash 合并（`af6f2a2`）、已装机、未发布）

- 时间：开工 `2026-11-18 20:00`（按会话记录；写交接时 `date '+%F %H:%M'` 为 20:12）。★ 来由：切「磁盘 | 内存」时面板在约 620 点和 754 点之间跳；常浩要两页同一尺寸，以后加内容也在这个尺寸里滚动。
- 改了哪些文件：
  - `Sources/DiskSlimApp/Views.swift`：新增 `panelHeight`（810 点，屏幕可用高度不够时让出上下各 12 点），`PanelView` 固定 368×810；`Scroller` 改成铺满剩余高度（`minHeight: 0`，L-14），加 `inset`、`spacing` 参数；首页顶栏、切换条、页脚钉住，中间放进 `Scroller`；磁盘顶卡下半加「谁占着」（`diskTop`：按用途合并、下载文件夹按整个文件夹、废纸篓有东西才列，取前 5）；抽出 `ShareBar`（和内存页共用的长短条）；提醒页设置列表放进 `Scroller`。
  - `Sources/DiskSlimApp/MemoryViews.swift`：内存页页脚抽成 `MemoryFooter`（钉在底部）；顶卡长短条改用 `ShareBar`；强制退出页列表放进 `Scroller`。
  - `docs/PRD.md` 3.2（尺寸固定规则、顶卡「谁占着」）、`docs/LESSONS.md`（L-14）、本文件。
- 测试：`scripts/test.sh` 原样结果 `✔ Test run with 289 tests in 37 suites passed`（`test-1.log`）；`node --test tests/*.test.mjs` 原样结果 `ℹ pass 4` / `ℹ fail 0`；`node scripts/check-rules.mjs` 输出「通用规则检查通过」。没给 `diskTop` 加单元测试：它在 App 目标里，测试目标只覆盖 DiskSlimCore。
- 验证：
  - 离屏截图：第一轮（`snap1`）内容多时顶栏页脚被挤掉，修后（`snap2`）27 张面板截图都是 1620 像素高（810 点），顶栏页脚都在；对照图 `compare-1.png`（磁盘首页 / 内存真实 / 内存示例 / 要你说一句展开 / 强制退出 / 提醒）。
  - 真屏（装机后用挂件链接把面板开在屏幕左侧 x=74，每次点前 `topat` 确认最上层是磁盘瘦身，点后 `pidwins` 读窗口）：磁盘页 → 点「内存」→ 展开「先不动」→ 真实滚轮往下滚 10 格 → 点「磁盘」→ 进「提醒」，窗口始终 `x=74 y=60 w=368 h=810`；内存页展开后在面板里滚动，顶栏、切换条、页脚不动（`real/03`～`08`、`pair-memory.png`）。
  - **磁盘页扫描完的真屏样子没验到**：重装后签名变了，系统弹「“DiskSlim”想访问“下载”文件夹中的文件」，扫描一直停在「正在扫描…」等这个回答；这是授权，要常浩自己点。磁盘页带「谁占着」的样子只有离屏截图。20:12:42 面板被收起（点了面板外面，推断是常浩在用电脑），之后没再点屏。
- 截图：`~/Library/Application Support/disk-slim/evidence/2026-11-18-fixed-size/`（`snap1`、`snap2`、`compare-1.png`、`real/`）。
- 发布与回读：未发布。`scripts/install.sh` 退出码 0（`install-1.log`），只有一个进程。签名变了：要在弹窗点「允许」，「完全磁盘访问权限」删旧条目再加，通知权限也要重开（提醒页已提示「系统没允许发通知」）。
- 与授权不一致之处、遗留问题、范围外发现：
  - 面板高度定 810 点而不是内存页原来的 754 点：磁盘页加了「谁占着」后约 791 点，内存页有一项「替你挑好的」时约 808 点，定 754 点这两种常见情况都要滚。内存页没东西挑时底下会空出约 50 点。
  - 刚扫描、内容少的时候（「扫描完就有」）白卡下面留白较多，属固定尺寸的代价。
  - 先在 `claude/memory` 上提交（a0a4ed0）时才发现 PR #7 已在 20:00 合并；常浩说「开新 PR」后，从最新 main 开 `claude/panel-fixed-size` 挑入，CURRENT.md 顶部一行冲突以 main 为准合并。
- 本轮新坑：L-14。

## 第 11 批：内存（2026-11-18，Claude，常浩提出「一键优化内存、直接替我判断，不行就一键打开强制退出窗口」，两轮预览后选「甲」、再发图定「一二结合」，看过分批计划说「按计划开工」；已随 PR #7 squash 合并（`e862639`）、已装机、未发布）

- 时间：开工 `2026-11-18 14:10`（`date '+%F %H:%M'` 记录）。★ 来由：常浩电脑 24 GB 内存，交换文件用到 29.6 / 30 GB，最大头是 43 个 Claude Code 会话；想要应用替他判断该关什么、一键处理，并且不用再记 ⌥⌘Esc。预览 `docs/design/ui-v8-memory.html`（https://claude.ai/artifact/XxVjd2mDXeJDiQAM8DnTcR，三版位置，选甲）、`docs/design/ui-v9-memory-polish.html`（https://claude.ai/artifact/54kvgJmwZH4iEmXzBcAv3h，常浩发图定「一二结合」）。
- 改了哪些文件：
  - 规则（DiskSlimCore）：新增 `Memory.swift`（读内存压力 / 交换 / 开机时间，列本用户进程的 phys_footprint 和 CPU 时间含已退出子进程，按父进程链和路径算回应用，Claude Code 会话连同插件合成一项，虚拟机单列）、`MemoryPlan.swift`（`MemoryRecord` 记曲线、最后使用、应用和会话忙闲、几个「别问」，`memory.json` 读写；三段规则；`MemoryGuard` 动手前核对）、`RunningApps.swift`。
  - 应用（DiskSlimApp）：新增 `MemoryStore.swift`（每 5 分钟采样、记切到前台、一键退出、浏览器退出、强制退出两下、收会话前隔 3 秒复查再发 SIGTERM、今晚 22:00 重启提醒）、`MemoryViews.swift`（切换条、内存页、强制退出页、图标转 sRGB 位图）；`Store.swift`（内存状态、启动时重置开始记录时间）、`Views.swift`（首页接切换条、顶栏内存页写「HH:mm 看过」、`Spark` 可铺满、`ChipButton` 加红色、截图里不挂取窗口的视图）、`DiskSlimApp.swift` 和 `FloatingBall.swift`（打开面板回磁盘页、读一次内存；真屏验收后又补：面板尺寸一变就收回屏内）、`Snapshot.swift`（30～37 号内存截图）。
  - 命令行：`diskslim memory`（只读）。
  - 测试：新增 `MemoryTests.swift`、`MemoryReviewTests.swift`（审查对抗测试，按修好后的规则断言）。
  - 文档：`docs/PRD.md`（3.6、4.4、第 5 节内存底线、第 7 节第 11 批）、`AGENTS.md`（简介、命令、结构、AI 接入里加 Claude Code 会话进程这个数据对象）、`docs/LESSONS.md`（L-13）、两份设计预览、本文件。
- 测试：`scripts/test.sh` 原样结果 `✔ Test run with 289 tests in 37 suites passed`；`node --test tests/*.test.mjs` 原样结果 `ℹ pass 4` / `ℹ fail 0`；`node scripts/check-rules.mjs` 输出「通用规则检查通过」。
- 验证：
  - 「收掉会话」实测（之二）：开测试会话「磁盘瘦身内存测试会话（可归档）」，回复后对它的进程（pid 2006，只有它是新开的 Haiku 进程，工作目录是本项目）发 SIGTERM，约 6 秒退出；再发消息，桌面版自动 `Resuming session`、载入原记录，回答里记得第 1 条（`evidence/2026-11-18-memory/kill-test*.txt`）。结束那一刻桌面版记了一条 error（退出码 143），对话记录里没有报错，界面上当时有没有红字没看到。
  - `diskslim memory` 只读跑真实机器，分段合理（`cli-memory-1.txt`）；刚开始记录时都写「刚开始记」，不会误挑。
  - 离屏截图两轮对照预览：`snap4`、`snap5`（真实与示例的内存页、展开态、强制退出点一下、退出后提示）。中途发现图标让整张截图发灰，改成重画 sRGB 位图（L-13）。
  - 真屏验收（11-18 19:12，交接会话；证据 `evidence/2026-11-18-memory/real/`，`notes.txt` 记了每一步）：每次点之前先截图确认是面板，再用新写的 `topat` 查点击位置最上层的窗口确实是磁盘瘦身；点完用 `pidwins` 和 `pgrep -x Calculator` 回读。① 挂件链接叫开，默认停在磁盘页，「内存」旁亮橙点（`01-open.png`）；② 切到内存页，和定稿「一二结合」一致（`04-memory-left.png`）；③ 页脚「强制退出…」打开列表（`05-forcequit.png`）；对自己后台打开的计算器点「退出」，`pgrep` 回读已退出，约 3 秒后列表刷新、计算器从列表消失（`08-after-quit-3s.png`）；④ 重开计算器，点「强制退出」第一下只变红色「确认强制退出」，计算器还在（`11-armed.png`），第二下后计算器退出（`12-after-force.png`）。全程只退出过自己开的计算器。
  - 验收中发现并修复：挂件在屏幕右上（链接 y=220）时，面板切到内存页从 691 点长到 754 点，顶边不动、往下长，底边到 974，超出 956 点高的屏幕，页脚「强制退出…」被切掉一半（`02-memory.png`）。原因：内容变高时窗口被 SwiftUI 直接撑高，没走 `placePanel` 里的收回屏内（推断：`preferredContentSize` 的 KVO 这时没触发，没加日志核实）。修法：`FloatingBall.swift` 监听面板 `NSWindow.didResizeNotification`，尺寸一变就按 `FloatGeometry.panel` 同一规则只挪位置（`keepPanelInside`）。重装后同样步骤复验：顶边收到 190，底边停在 944，页脚完整（`13-fixed-right.png`）。修后 `scripts/test.sh` `✔ Test run with 289 tests in 37 suites passed`（`test-5.log`），Node `ℹ pass 4` / `ℹ fail 0`，规则检查通过，`scripts/install.sh` 退出码 0（`install-2.log`）。
  - 真屏时的意外：屏幕右侧有 PostPane（`/Applications/PostPane.app`）的一个透明窗口（层级 26，x=413～1353，整屏高）盖在面板上面。第一下点「内存」生效了，之后两下点「磁盘」(1221,279) 没反应，推断落进了 PostPane 的窗口，点到了什么未查。发现后改为把面板开在屏幕左侧、每次点前查最上层窗口。
  - 装机后应用常驻、写出 `memory.json`（第一份：1 个曲线点、6 个会话、11 个应用）；用挂件链接开、关面板正常。**真屏点击没做**：前台是常浩的 WPS 文档，截面板区域截到的是文档，再按坐标点会点进文档里，停了；截到的那张图已删。没有退出过常浩的任何程序（只开过、关过自己开的计算器）。
- 截图：`~/Library/Application Support/disk-slim/evidence/2026-11-18-memory/snap5/`（30～37 号是内存页）。
- 发布与回读：未发布。`scripts/install.sh` 退出码 0（`install-1.log`），只有一个进程。签名变了，「完全磁盘访问权限」要删旧条目再加。
- 独立审查（L-06）：只读审查员报高 2、中 5、低 5。已修：高 1（收会话前复查忙闲）、高 2（ChatGPT 桌面版的 bundle id 就是 `com.openai.codex`，里面跑 Codex 任务，改为不挑；应用也按进程树记忙闲，4 小时内在后台忙过的不挑）、中 3（每次启动重新看满 4 小时）、中 4、中 5（采样间隔过长或 CPU 合计变小当忙过，CPU 含已退出子进程）、中 7（Docker、OrbStack、UTM、OBS、JetBrains 等归「可能有任务在跑」）、低 8～11。中 6 改的是 PRD 文字：强制退出页和系统 ⌥⌘Esc 一样列系统自带应用，一键退出照旧不挑它们。没改：低 12（切到别的应用就写一次 `memory.json`，文件只有几 KB）。审查员中途误覆盖并删掉了已提交的 `ReviewAdversarialTests.swift`，已从 HEAD 恢复，`git status` 核对过。
- 与授权不一致之处、遗留问题、范围外发现：
  - 计划里写「默认停磁盘页」，照做；替你挑好的要等应用常驻满 4 小时、且记到程序 4 小时没在后台忙，第一次装好后这段时间里内存页「替你挑好的」是空的，属预期。
  - 内存页没有「留着」按钮（磁盘页有），计划没写，没做。
  - 测试会话「磁盘瘦身内存测试会话（可归档）」还在侧栏，等常浩同意后归档。
  - 挂件链接在应用刚重启后第一次发不出面板、连发时会「再开一次」，缩小键那批就记过，没查。
- 本轮新坑：L-13。

## 面板顶栏加缩小键（2026-11-18，Claude，常浩在驿窗会话里提出要缩小键，三版预览选甲「同款线条」后说「选甲，按计划开工」，之后说「你现在就查」；已提交到 `claude/minimize-button`、PR 待合并、已装机、未发布）

- 时间：开工 `2026-11-18 11:09`（`date '+%F %H:%M'` 记录）。★ 来由：常浩想在面板右上角刷新键旁加一个缩小键，点了面板收回去；三版预览 `docs/design/ui-v7-minimize.html`（线上 https://claude.ai/artifact/XB74D2pfX8Kb6Wn43iX91o），选甲：和 ↻ 一样的灰色细线「—」，无底。
- 改了哪些文件：
  - `Sources/DiskSlimApp/Views.swift`：首页顶栏 ↻ 右边加缩小键（`minus`，`.help("缩小")`，label 给 18×18 点击区）；`WindowBox` + `WindowReader` 记下按钮所在的窗口；`@Environment(\.dismiss)` 给菜单栏弹窗用。
  - `Sources/DiskSlimApp/FloatingBall.swift`：`collapse(_:dismissMenu:)`：在悬浮面板（挂件或球叫开的）里点的就 `closePanel()`，状态文件 `panelOpen` 写回 false；在菜单栏弹出的面板里点的交给 `dismiss()`。
  - `docs/design/ui-v7-minimize.html`（三版预览）、`docs/PRD.md` 3.4（收起方式补一句缩小键）、`docs/LESSONS.md`（L-12）、本文件。
- 测试：`scripts/test.sh` 原样结果 `✔ Test run with 253 tests in 34 suites passed`；`node --test tests/*.test.mjs` 原样结果 `ℹ pass 4` / `ℹ fail 0`；`node scripts/check-rules.mjs` 输出「通用规则检查通过」。
- 验证：装机后在真屏上用 CGEvent 发真实点击（L-11），每次先截图定位「—」、点前再确认窗口在屏上，窗口用 `CGWindowListCopyWindowInfo` 按进程号回读：
  - 诊断版（临时加日志，记录点击是否送到面板、按钮是否收到、走哪一支）：挂件叫开的面板 10/10 收起（含菜单栏与挂件交替、重启应用后第一次打开），菜单栏弹出的面板 3/3 收起，日志里两条路各走各的分支。
  - 最终版（去掉日志后重装）：菜单栏与挂件交替各 3 轮，全部收起；菜单栏面板每轮点一下图标就能再打开；`panelOpen` 跟着写回 false；只有一个进程。
  - 过程中的失败及处理：① 第一版按鼠标位置找窗口，时灵时不灵，改成记下按钮所在窗口；② 菜单栏面板用 `window.close()` 收起后，下次点图标要点两下，`performClick`、`deactivate` 都不行，改用 `dismiss()`；③ 横线太细点不中，加点击区（L-12）；④ 加点击区后最终版挂件面板有两次没收起（其中一次是接手的子 agent 补验），诊断版在同样顺序下复现不出来；当时常浩同时在用电脑，原因未查清。
- 截图：`~/Library/Application Support/disk-slim/evidence/2026-11-18-minimize/`（`final-A-open.png` 挂件面板、`final-B-open.png` 菜单栏面板、`snap/` 离屏截图、`final-realscreen.txt` 每轮结果、`diag-log.txt` 诊断日志、`click` `pidwins` `findmin.py` 测试脚本）。
- 发布与回读：未发布。`scripts/install.sh` 最终一次退出码 0（`install-final-2.log`），`pgrep` 只有一个进程。本轮重装了多次，每次签名都会变，「完全磁盘访问权限」要常浩删掉旧条目再加回。
- 与授权不一致之处、遗留问题、范围外发现：
  - 补验时接手的子 agent 没先确认面板在屏上就点了一下 (1579,303)，落在常浩屏幕上别的窗口里，点到了什么未查。
  - 测试中多次移动了常浩的鼠标、开关了面板。
  - 范围外：重启应用 3 秒内发第一次挂件链接，有一次面板没出来（第二次正常），原因没查，和缩小键无关。
- 本轮新坑：L-12。

## 第 10 批之三：删掉深色、重扫期间文案、色带跟着变色（2026-11-18，Claude，常浩看过分批计划说「按计划开工，直接删除深色模式就行，我只保留目前这一个模式」，之后说「跳过，直接合并」；已提交并随 PR #5 合并、已装机、未发布）

- 时间：开工 `2026-11-18 11:05`（按会话记录；测试完 `date '+%F %H:%M'` 为 11:11）。★ 来由：PR #5 收尾。看完彩带离屏截图（1.3、2.4 秒、放完、深色，动效都没问题），修清理后重扫期间的文案；深色截图里发现两处毛病（扫描中「一键清理」看着能点、提示条和面板一样黑），常浩决定不修，直接删掉深色。
- 改了哪些文件：
  - `Sources/DiskSlimApp/Views.swift`：`Tone` 只留浅色，删掉深色配色和 `colorScheme` 读取；`PanelView` 固定浅色（`.environment(\.colorScheme, .light)` + `.preferredColorScheme(.light)`）；新增 `Tone.level`，色带可用那段低于 30 GB 红、低于 60 GB 橙、60 GB 以上绿（顶卡大数字不变：60 GB 以上仍是正文色）；还没有扫描结果时「要你说一句」「先不动」写「扫描完就有」、「先不动」不显示 0 KB，页脚写「对话记录 · 扫描完就有」。
  - `Sources/DiskSlimApp/FloatingBall.swift`：悬浮球叫开的面板窗口固定浅色外观。
  - `Sources/DiskSlimApp/Snapshot.swift`：只出浅色，文件名不再带「-浅色 / -深色」；彩带截图带上「正在扫描」状态（之前截图写「还没扫描」是因为没模拟这个状态，应用里清理后本来就显示「正在扫描…」）；新增 18、19 号示例截图看 72 GB（绿）、22 GB（红）。
  - `Sources/DiskSlimCore/Model.swift`：`DiskStatus` 加公开的构造函数，给截图用示例数字。
  - `docs/PRD.md` 3.2、第 7 节第 10 批；`AGENTS.md` 截图命令说明；本文件。
- 测试：`scripts/test.sh` 原样结果 `✔ Test run with 253 tests in 34 suites passed`；`node --test tests/*.test.mjs` 原样结果 `ℹ pass 4` / `ℹ fail 0`；`node scripts/check-rules.mjs` 输出「通用规则检查通过」。改 `Model.swift` 后又全量跑了一遍，结果相同。
- 验证：离屏截图 `snap5-light-only/` 两轮：彩带 0.5 / 1.3 / 2.4 秒与放完、首页、要你说一句、清理前确认、72 GB / 22 GB 示例都看过——重扫期间顶部「正在扫描…」、两段和页脚「扫描完就有」，色带与数字同色（橙 / 绿 / 红），浅色界面其余部分与改前一致。装机后用 `diskslim://panel/toggle` 在真屏打开面板（`real-2-light-only.png`）：浅色，47.8 GB 橙色数字、色带橙色。真屏彩带未看：刚清理过，「替你挑好的」为空、「一键清理」点不了；常浩说「跳过，直接合并」，凭离屏截图验收，下次真实清理时顺便看。没有运行任何真实清理。
- 截图：`~/Library/Application Support/disk-slim/evidence/2026-11-18-decide-for-me/`（`snap5-light-only/`、`real-2-light-only.png`；`snap4-confetti/` 是删深色前的旧图）。
- 发布与回读：未发布。`scripts/install.sh` 退出码 0（`install-light-only.log`），`pgrep` 只有 `/Applications/DiskSlim.app` 一个进程。签名变了，面板上「废纸篓读不了」，要常浩在「完全磁盘访问权限」里删旧条目再加。
- 与授权不一致之处、遗留问题、范围外发现：
  - 计划里「深色两处小毛病」改成整个删掉深色，按常浩这轮的话做。
  - 「要你说一句」扫描中原来写「现在没有要问你的」，同属扫描中误报「没有」，一并改成「扫描完就有」（计划里没列，顺手改）。
  - 离屏「清理前确认」截图在「替你挑好的」为空时画出「确认清理 0 项」，只是截图直接塞了空列表；应用里列表为空时不会弹确认框，没改。
  - 菜单栏图标和数字跟着系统菜单栏走，不在「只留浅色」范围内。
- 本轮新坑：无。

## 第 10 批之二：清理完成放彩带（2026-11-18，Claude，常浩在三版动效预览里选「二版 彩带雨」；已提交到 `claude/4-decide-for-me`、未装机、未发布）

- 时间：开工 `2026-11-18 11:00`（按会话记录）。★ 来由：常浩清完一次后说「如果完成清理，可以放个烟花什么的」；三版预览 `docs/design/ui-v6-celebrate.html`（线上 https://claude.ai/artifact/L8TBXp9sWYfSwiJec2XoNJ），选二版。
- 改了哪些文件：`Store.swift`（`Celebration`：手动清理腾出了空间才放，清完马上重读可用空间，结果提示晚 1.2 秒弹，彩带放完刷新一次停帧，约 9 秒后收掉「+X GB」；自动清理不放）、`Views.swift`（`ConfettiView` 彩带雨 90 片、`CelebrationClock` 按真实时间或离屏定格、顶卡数字 1.4 秒从清理前滚到清理后、「+X GB」标签、「刚腾出 / 废纸篓里还有」；系统「减少动态效果」时只换数字）、`Snapshot.swift`（14～17 号彩带定格截图）、`docs/design/ui-v6-celebrate.html`。
- 测试：`scripts/test.sh` 原样结果 `✔ Test run with 253 tests in 34 suites passed`；`node --test tests/*.test.mjs` 原样结果 `ℹ pass 4` / `ℹ fail 0`。
- 验证：离屏截图 `evidence/2026-11-18-decide-for-me/snap4-confetti/`，0.5 秒那张看过（彩带在飘、数字滚到一半、「+45.3 GB」出来）；1.3、2.4 秒和放完、深色那几张还没看。没装机，真屏没看过动效。
- 截图：同上。
- 发布与回读：未发布，未装机。
- 与授权不一致之处、遗留问题、范围外发现：
  - 常浩那次清理（10:54）11 项全部成功，直接腾出 45.3 GB、6.7 GB 进废纸篓；之后驿窗新开 `384-hermes-jobs` 几分钟编出 5.2 GB，`nostalgic-bartik-8bdeee` 也在长，可用空间回落到 37 GB。根治要驿窗各 worktree 共用编译目录，属驿窗项目。
  - 清理后重扫期间：顶部写「还没扫描」应为「正在扫描…」，「先不动」写「没有 · 0 KB」、对话记录 0 KB，应写「扫描完就有」；顶卡色带里可用那段固定红色，数字是橙色时应跟着变。
- 本轮新坑：无。

## 第 10 批「替你判断」：三条规则 + 首页雾光两块式（2026-11-18，Claude，常浩选定逻辑甲、排版「一黑一白」、顶卡「雾光」，规则①②③改④不改，说「雾光，按计划开工」；已提交到 `claude/4-decide-for-me`、已装机、未发布）

- 时间：开工 `2026-11-18 10:20`（`date '+%F %H:%M'` 记录）。★ 来由：常浩不懂技术，面板上「要你决定 89.7 GB」「本周待决定 28 GB」没法判断，要应用替他做 99% 的判断（issue #4）。设计预览四轮都在 `docs/design/ui-v2～v5-*.html`，定稿 v5「雾光」。
- 改了哪些文件：
  - 规则（`8af91d9`）：`WorktreeScanner.swift`（没在用的编译文件，PR 没合并或有未提交改动也默认勾选，标需确认、不进自动清理；`git status` 失败仍不清；删掉不用的 `idleSince`）、`KnownPlaces.swift`（Codex 备份按修改时间留最新一份、30 天前的旧份默认勾选；虚拟机记最近使用日期）、`Model.swift`（`Finding.lastUsed`、三段归类 `Bucket`）、`Weekly.swift`（周报只问「要你说一句」里能执行的）、`Alerts.swift`（周报文案）。
  - 界面（`b802bd2`）：`Views.swift`（首页雾光顶卡 + 白卡「替你挑好的 / 要你说一句 / 先不动」，删本周待决定页和 4 个不用的旧配色）、`Store.swift`（页面换成 picked / downloads / keep / records，按三段取数据，`openTrash` 只打开不清空）、`Snapshot.swift`、`DiskSlimApp.swift`、`FloatingBall.swift`（开面板时收起抽屉）。
  - 审查修复（`a6cbaef`）：「替你挑好的」每项加「留着」，「要你说一句」补回「下周再问」，扫描时间统一传入，虚拟机说明与分段同一判断、最近使用看到第三层，「先不动的」页与首页同一批，`applyHistory` 保住 `lastUsed`。
  - 文档：`docs/PRD.md`（3、3.2、3.3、4.2、第 7 节加第 10 批）、`AGENTS.md`（结构说明）、本文件。测试：`WorktreeTests`、`AlertsTests`、`AlertsAdversarialTests` 按新规则改写，`KnownPlacesTests` 新增 8 条。
- 测试：`scripts/test.sh` 原样结果 `✔ Test run with 253 tests in 34 suites passed`；`node --test tests/*.test.mjs` 原样结果 `ℹ pass 4` / `ℹ fail 0`；`node scripts/check-rules.mjs` 输出「通用规则检查通过」。
- 验证：`diskslim scan` 只读扫描真实磁盘：默认勾选 10 项共 51.8 GB（4 个 worktree 编译文件 45.0 GB、5 份旧 Codex 备份 6.7 GB、npm 缓存 123 MB），和预览一致；Colima、Cowork 都显示 11 月 15～18 日用过、归「先不动」。离屏截图三轮浅色、深色对照预览。装机后用 `diskslim://panel/toggle` 在真屏打开面板，新首页正常渲染、正在扫描；系统弹出「DiskSlim 想访问文稿文件夹」，要常浩自己点「允许」，所以带真实数据的真屏截图还没拍到。没有运行任何真实清理。
- 截图：`~/Library/Application Support/disk-slim/evidence/2026-11-18-decide-for-me/`（`snap1`～`snap3` 离屏截图，`real-1-home.png` 真屏，`install.log`）。
- 发布与回读：未发布（GitHub 只推分支、开 PR）。`scripts/install.sh` 退出码 0，`pgrep` 只有一个进程（88871）。
- 独立审查（L-06）：只读审查员报中 1、低 9，无高。已修 M1、L1、L2、L3、L5、L8、L9；未改：L4（最新一份不到 50 MB 时会多留一份，偏保守，可接受）、L6（首页角标含「下周再问」的和虚拟机，周报不含，按设计）、L7（「让我挑」进下载页时安装包已勾着，旧行为，确认框只列数量；都进废纸篓可撤销，记作后续）。
- 与授权不一致之处、遗留问题、范围外发现：
  - 「下周再问」原来在本周待决定页，删页后补到「要你说一句」里；确认框的「需确认」提示改成只在自己从「先不动」挑了需确认项时出现。
  - 扫描中「先不动」写「没有」、对话记录写 0 KB，应写「扫描完就有」，下次顺手改。
  - 磁盘只剩约 2.6 GB（10:47），别的程序在持续写入；驿窗测试证据两周 21 GB，建议另开驿窗任务处理。
- 本轮新坑：无。

---

更早的交接（2026-11-05 至 11-07：第 0–9 批、审查修复 B1–B12、「AI 接入」一节）归档在 [docs/history/CURRENT-2026-11-05至11-07.md](docs/history/CURRENT-2026-11-05至11-07.md)。
