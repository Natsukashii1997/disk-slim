# 磁盘瘦身（disk-slim） 协作约定（Codex / Claude 必读）

macOS 小工具（2026-11-19 起不在菜单栏显示，入口是驿窗侧栏的扫帚浮游兽挂件），帮常浩批量清理下载文件夹和看不见的缓存、构建产物，并在空间变少或突然暴涨时提醒；第 11 批起也看内存，替他挑出闲着又占内存的程序一键退出。进入顺序：本文件 → [CURRENT.md](CURRENT.md)（当前状态与唯一下一步）。需求以 [docs/PRD.md](docs/PRD.md) 为准。所有面向用户的文字用简体中文。本文件只放怎么开始和做什么事之前读哪份；操作细节在 [docs/OPERATIONS.md](docs/OPERATIONS.md)，按需读对应一节。

## 做什么事之前读哪份

| 要做的事 | 先读 |
|---|---|
| 改需求、加功能 | [docs/PRD.md](docs/PRD.md) |
| 排障、改脚本、装 launchd 或定时任务 | 先 `grep -n 关键词 docs/LESSONS.md`，再搜全局坑 `/Users/nat/Documents/ChatGPT/个人/work/agent-kit/LESSONS.md` |
| 开需求、拆任务、实现、审查 | 下面「Agent skills」一节 |
| 读代码、给东西起名字 | [GLOSSARY.md](GLOSSARY.md)：代码里的词和界面上的词怎么对应 |
| 改已定内容（外观、文案、行为、规则） | [docs/DECIDED.md](docs/DECIDED.md)：碰到里面任何一项先单独发「改动确认」 |
| 写交接、验收别人的交接 | [docs/templates/handoff.md](docs/templates/handoff.md) 骨架；[OPERATIONS](docs/OPERATIONS.md)「交接写法」「报告与验收」 |

项目长出接口、样式、发布等文档后，在这张表里加一行。

## 分工

- 以用户每轮明确授权的范围为准；授权外的不做。
- 一次只做一件授权的事；范围外的问题记进交接，不顺手修。
- 并行的会话各开独立 worktree，不在同一目录改代码；做不到时照全局坑 G-04，只提交自己的改动。

## 运行

```sh
node --test tests/*.test.mjs     # 交接格式 + 通用规则（含自测）
node scripts/check-rules.mjs     # 只跑通用规则检查
git config core.hooksPath scripts/hooks   # 装提交、推送前的必经检查（每个克隆、每台电脑各一次；不用 --no-verify 绕过）
```

```sh
scripts/test.sh                              # 单元测试（Swift Testing）；不要直接用 swift test，原因见 L-04
swift build -c release                       # 编译
.build/release/diskslim scan                 # 只读扫描真实磁盘，按区域和分组列出；不删任何东西
.build/release/diskslim scan --json          # 同上，输出 JSON
.build/release/diskslim clean                # 预览默认勾选的项会怎么处理，不执行
.build/release/diskslim clean --yes          # 真正执行；只有用户在本轮明确同意清理真实磁盘时才能跑
.build/release/diskslim undo                 # 撤销最近一次：把移到废纸篓的放回原处
.build/release/diskslim growth               # 最近 7 天可用空间和谁涨了多少；只读每日记录 usage.json，不扫描
.build/release/diskslim memory               # 内存压力、谁占着、替你判断的三段；只读，不退出任何程序
.build/release/diskslim doctor               # 自检：已装版本（提交号）、应用在不在跑、状态和记录文件、提醒送达、清理命令找不找得到；只读
# 自测一律用沙盒：加 --home <沙盒>/home --work <沙盒>/home/work，沙盒放在证据目录下
scripts/bundle.sh                            # 打包应用到 dist/DiskSlim.app（本机签名、写入提交号，不安装、不启动）
scripts/install.sh                           # 打包并装到 /Applications/DiskSlim.app 后启动；先复制后替换、失败回滚；应用正在清理时不替换
.build/debug/DiskSlimApp --snapshot <目录>    # 用真实扫描离屏渲染各页面 PNG（只有浅色），只读，不清理
dist/DiskSlim.app/Contents/MacOS/DiskSlimApp --test-notify   # 用示例数据把每种提醒各发一条系统通知，标题带「示例」；只发通知，不扫描、不清理
```

本机只有命令行工具、没有完整 Xcode；`swift build` 会打几行 `ld: warning: search path ... not found`，不影响结果。

## 结构

```
AGENTS.md            入口（本文件）
CURRENT.md           当前状态与唯一下一步；每轮交接写在顶部，旧节归档在 docs/history/
GLOSSARY.md          词汇表：代码里的词和界面上的词怎么对应
docs/PRD.md          需求（含调研结论、规则、分批计划）
Package.swift        SwiftPM：DiskSlimCore（规则与模型）、diskslim（命令行）、DiskSlimApp（桌面应用）、DiskSlimCoreTests
Sources/
  DiskSlimCore/      Model（Finding、风险等级、清理方式、空间三档和 30 / 60 GB 阈值）、Kind（分组名常量、每一项的类型、给人看的名字）、System（元数据、大小、命令、格式）、
                     DownloadsScanner、WorktreeScanner、KnownPlaces（缓存 / 需确认 / 只展示）、History（按上次实际释放校正清理命令）、Usage（每日记录、7 天曲线、谁涨了多少）、Alerts（提醒开关与规则、自动清理挑项）、Weekly（每周卡片只问「要你说一句」、周报时间）、Decisions（保留 / 下周再问和 decisions.json）、Persistence（五份记录文件统一的读、留底、加锁写 `RecordFile`）、Scan（总入口、执行前复核）、
                     SafetyGuard（执行前重新核对路径和命令的白名单）、Cleaner（执行、操作记录、撤销）、FloatGeometry（悬浮球与面板位置）、Pendant（给驿窗挂件的状态文件、diskslim:// 链接解析、点挂件防抖）、Doctor（`diskslim doctor` 自检、打包写进的版本 `AppBuild`）、
                     Memory（读内存压力、交换、进程，按应用和 Claude Code 会话合计）、MemoryRecord（memory.json：曲线、最后使用、忙闲）、MemoryRules（阈值和应用名单）、MemoryPlan（内存三段）、MemoryGuard（动手前核对）、RunningApps（读运行中的普通应用）
  DiskSlimCLI/       命令行 `diskslim`（scan / clean / undo / growth / memory）
  DiskSlimApp/       桌面应用（AppKit 启动，没有 SwiftUI 场景，L-15）：Store（扫描、勾选、清理、撤销、提醒、自动清理）、Views（首页「替你判断」：雾光顶卡 + 替你挑好的 / 要你说一句 / 先不动；下钻页、涨幅页、提醒设置、确认、提示）、Notifier（系统通知，只在打包版）、Snapshot（离屏截图）、FloatingBall（桌面悬浮球：贴边小窗、点开面板、拖动贴边）、PanelController（面板窗口：建窗口、摆位置、点外面收起）、
                     Store+Memory.swift（`extension Store`：内存读数、采样、一键退出、收会话、强制退出、重启提醒）、MemoryViews（「磁盘 | 内存」切换、内存页、强制退出页）
tests/DiskSlimCoreTests/  各条规则的单元测试（Swift；和 Node 测试同在 tests/）。文件按被测对象命名，`…AdversarialTests` 和带 Adversarial 的套件是独立审查留下的对抗用例
assets/floating-ball.png  悬浮球图标（打包时复制成 Contents/Resources/ball.png）
design/fuyou-icon/   悬浮球定稿图与生图需求（中间稿和参考图只留本机，不进仓库）
docs/
  design/ui-v1.html  三版菜单栏界面预览（A 容量仪表 / B 涨幅雷达 / C 待清理收件箱）
  design/ui-v2～v5-*.html  第 10 批「替你判断」的逻辑、排版、收紧、顶卡配色预览（定稿 v5「雾光」）
  design/ui-v8-memory.html、ui-v9-memory-polish.html  第 11 批内存页预览（定稿 v9「一二结合」）
  agents/            Matt Pocock 技能读的约定：issue 看板、分流标签、领域文档
  LESSONS.md         本项目的坑（排障、改脚本前先搜）
  DECIDED.md         已定内容登记表（常浩选定、验收过的；要改先单独确认）
  OPERATIONS.md      操作手册：交接写法、报告与验收
  templates/handoff.md  交接一节的骨架
scripts/
  bundle.sh          打包 dist/DiskSlim.app
  install.sh         装到「应用程序」并启动（只替换我们自己的那份）
  test.sh            跑 Swift 单元测试（补上测试宏插件路径，L-04）
  check-rules.mjs    通用规则检查（只查机器能判定的）
  hooks/             提交、推送前的必经检查（commit-msg、pre-push），用 `git config core.hooksPath scripts/hooks` 装
tests/               node:test 测试
```

## Agent skills

开发流程用 Matt Pocock skills（`~/.agents/skills/`）：大活走 `to-spec` → `to-tickets` → `implement` / `tdd` → `code-review` → PR；小改（一张 issue、一天内做完）跳过 `to-spec`。Claude 用 `/技能名`，Codex 用 `$技能名`；这几个技能只在点名时加载，不会自动触发。

### Issue tracker

需求、规格与任务用本仓库 GitHub Issues。见 `docs/agents/issue-tracker.md`。

### Triage labels

五个默认分流标签。见 `docs/agents/triage-labels.md`。

### Domain docs

single-context：根目录 `GLOSSARY.md` 与 `docs/adr/`，用到时再建。见 `docs/agents/domain.md`。

改动怎么走、分支怎么起名、交接写在哪、怎么合并：见 `/Users/nat/Documents/ChatGPT/个人/work/agent-kit/工程流程.md`。

## 规则

- 验证用的备份、日志等证据放 `~/Library/Application Support/disk-slim/evidence/`，不放 `/tmp`（全局坑 G-01）；私人数据与完整日志不进仓库。
- 新增 Swift 包依赖，先在交接里说明理由，经用户同意再加。
- 目录名、SwiftPM 目标名、可执行文件名之间不能只差大小写（macOS 不区分大小写，会悄悄合并，L-03）。
- 引入外部清理命令前，先读它的源码或用 `--dry-run` 看清副作用；每批做完让独立 agent 做一次只读审查和对抗测试（L-06）。
- 安全底线（[docs/PRD.md](docs/PRD.md) 第 5 节）：用户文件只移到废纸篓，不直接删除、不自动清空废纸篓；「只展示」的项任何路径都删不了；清理前可预览、留日志、可撤销；不用 `sudo`。
- 界面上的时间经统一的格式化函数按北京时间显示，不直接截取 ISO 字符串（全局坑 G-02）。

## AI 接入

本应用当前不调用 AI：扫描、分级、清理、提醒、内存判断都由本机规则完成，没有任何内容由 AI 替本应用产出（2026-11-07 核实，2026-11-18 第 11 批复核）。会启动的外部程序都不是 AI：已知位置表里的缓存清理命令（`npm`、`uv`、`pnpm`、`pip3`）和查它们在不在的 `which`；判断 worktree 状态的 `gh pr list`、`git`（只读）；判断在不在用的 `ps`、`lsof`。

- 数据对象（来源是本机目录，只统计占用空间、按风险分级，不读内容，不算执行方；定义在 `KnownPlaces.swift`、`WorktreeScanner.swift`）：
  - 只展示，任何路径都删不了：Claude 对话记录 `~/.claude/projects`；Codex 对话记录 `~/.codex/sessions`、`~/.codex/archived_sessions`。
  - 需确认：Codex 备份 `~/.codex/recovery`（勾选后逐份移到废纸篓）；Cowork 虚拟机 `~/Library/Application Support/Claude/vm_bundles`（本应用不清，只提示去 Claude 设置 › 存储里处理）。
  - 可清理：各项目 `.claude/worktrees/*/target`（Claude 会话 worktree 里的 Rust 构建产物）。
  - 内存（第 11 批，定义在 `Memory.swift`、`MemoryPlan.swift`）：Claude 桌面版的 Claude Code 会话进程（`…/claude-code/…/MacOS/claude`）连同插件进程，只统计内存和 CPU 时间，不读对话内容、命令行参数和环境变量；用户在「要你说一句」点「收掉」时给闲着 12 小时以上的会话进程发 SIGTERM，下次发消息桌面版自动续上。
- 对外开放：无 AI 接口（没有 MCP）。`~/Library/Application Support/disk-slim/status.json` 和 `diskslim://panel/toggle` 链接只给驿窗挂件读状态、开面板，不是给 AI 的接口。
- 第一次加 AI 功能时，按全局规则 P-13（`~/.claude/CLAUDE.md` 第 14 节「应用里的 AI 接入写进设置」）补设置栏，并改写本节。

## 交接格式

每轮完成后，在 CURRENT.md 顶部新增一节（旧节保留在下面，过长时归档到 `docs/history/`），骨架照抄 [docs/templates/handoff.md](docs/templates/handoff.md)；`tests/handoff-format.test.mjs` 会检查顶部一节有没有日期、「时间：开工」「测试：」「本轮新坑：」三行，新坑编号在 LESSONS 里要存在。每一行怎么写、报告与验收的防伪造五条见 [OPERATIONS](docs/OPERATIONS.md)「交接写法」「报告与验收」；没做就写「未做」。
