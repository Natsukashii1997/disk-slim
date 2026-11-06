# 磁盘瘦身（disk-slim） 协作约定（Codex / Claude 必读）

macOS 菜单栏小工具，帮常浩批量清理下载文件夹和看不见的缓存、构建产物，并在空间变少或突然暴涨时提醒。进入顺序：本文件 → [CURRENT.md](CURRENT.md)（当前状态与唯一下一步）。需求以 [docs/PRD.md](docs/PRD.md) 为准。所有面向用户的文字用简体中文。本文件只放怎么开始和做什么事之前读哪份；操作细节在 [docs/OPERATIONS.md](docs/OPERATIONS.md)，按需读对应一节。

## 做什么事之前读哪份

| 要做的事 | 先读 |
|---|---|
| 改需求、加功能 | [docs/PRD.md](docs/PRD.md) |
| 排障、改脚本、装 launchd 或定时任务 | 先 `grep -n 关键词 docs/LESSONS.md`，再搜全局坑 `/Users/nat/Documents/ChatGPT/个人/work/agent-kit/LESSONS.md` |
| 开需求、拆任务、实现、审查 | 下面「Agent skills」一节 |
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
# 自测一律用沙盒：加 --home <沙盒>/home --work <沙盒>/home/work，沙盒放在证据目录下
scripts/bundle.sh                            # 打包菜单栏应用到 dist/DiskSlim.app（本机签名，不安装、不启动）
scripts/install.sh                           # 打包并装到 /Applications/DiskSlim.app 后启动；先复制后替换、失败回滚；应用正在清理时不替换
.build/debug/DiskSlimApp --snapshot <目录>    # 用真实扫描离屏渲染各页面 PNG（浅色 / 深色），只读，不清理
dist/DiskSlim.app/Contents/MacOS/DiskSlimApp --test-notify   # 用示例数据把每种提醒各发一条系统通知，标题带「示例」；只发通知，不扫描、不清理
```

本机只有命令行工具、没有完整 Xcode；`swift build` 会打几行 `ld: warning: search path ... not found`，不影响结果。

## 结构

```
AGENTS.md            入口（本文件）
CURRENT.md           当前状态与唯一下一步；每轮交接写在顶部
docs/PRD.md          需求（含调研结论、规则、分批计划）
Package.swift        SwiftPM：DiskSlimCore（规则与模型）、diskslim（命令行）、DiskSlimApp（菜单栏应用）、DiskSlimCoreTests
Sources/
  DiskSlimCore/      Model（Finding、风险等级、清理方式）、System（元数据、大小、命令、格式）、
                     DownloadsScanner、WorktreeScanner、KnownPlaces（缓存 / 需确认 / 只展示）、History（按上次实际释放校正清理命令）、Usage（每日记录、7 天曲线、谁涨了多少）、Alerts（提醒开关与规则、自动清理挑项）、Weekly（每周卡片、保留 / 下周再问）、Scan（总入口、执行前复核）、
                     SafetyGuard（执行前重新核对路径和命令的白名单）、Cleaner（执行、操作记录、撤销）、FloatGeometry（悬浮球与面板位置、空间三档）
  DiskSlimCLI/       命令行 `diskslim`（scan / clean / undo）
  DiskSlimApp/       菜单栏应用：Store（扫描、勾选、清理、撤销、提醒、自动清理）、Views（首页 + 下钻、涨幅页、本周待决定、提醒设置、确认、提示）、Notifier（系统通知，只在打包版）、Snapshot（离屏截图）、FloatingBall（桌面悬浮球：贴边小窗、点开面板、拖动贴边）
tests/DiskSlimCoreTests/  各条规则的单元测试（Swift；和 Node 测试同在 tests/）
assets/floating-ball.png  悬浮球图标（打包时复制成 Contents/Resources/ball.png）
design/fuyou-icon/   悬浮球定稿图与生图需求（中间稿和参考图只留本机，不进仓库）
docs/
  design/ui-v1.html  三版菜单栏界面预览（A 容量仪表 / B 涨幅雷达 / C 待清理收件箱）
  agents/            Matt Pocock 技能读的约定：issue 看板、分流标签、领域文档
  LESSONS.md         本项目的坑（排障、改脚本前先搜）
  OPERATIONS.md      操作手册：交接写法、报告与验收
  templates/handoff.md  交接一节的骨架
scripts/
  bundle.sh          打包 dist/DiskSlim.app
  install.sh         装到「应用程序」并启动（只替换我们自己的那份）
  test.sh            跑 Swift 单元测试（补上测试宏插件路径，L-04）
  check-rules.mjs    通用规则检查（只查机器能判定的）
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

## 交接格式

每轮完成后，在 CURRENT.md 顶部新增一节（旧节保留在下面，过长时归档到 `docs/history/`），骨架照抄 [docs/templates/handoff.md](docs/templates/handoff.md)；`tests/handoff-format.test.mjs` 会检查顶部一节有没有日期、「时间：开工」「测试：」「本轮新坑：」三行，新坑编号在 LESSONS 里要存在。每一行怎么写、报告与验收的防伪造五条见 [OPERATIONS](docs/OPERATIONS.md)「交接写法」「报告与验收」；没做就写「未做」。
