# 词汇表

代码里的词和界面上的词怎么对应。读代码、起名字前先看；同一个意思只用这里的词。标「易混」的是现有命名里容易看错的地方。

## 一项东西从扫到到清掉

| 界面上 | 代码里 | 意思 |
|---|---|---|
| 一项 | `Finding` | 扫描找到的一个可以处理的东西：一个文件、一个缓存目录、一个 worktree 的 `target/` |
| 下载文件夹 / 看不见的 | `Area.downloads` / `Area.hidden` | 在哪一块找到的。「看不见的」指缓存、构建产物、备份、虚拟机、对话记录 |
| 分组 | `Finding.category` | 界面按它分组的中文名，如「安装包」「包管理器缓存」。分组名只在 `Kind.swift` 的 `Category` 里写一遍；判断「这一项是什么」用 `Finding.kind`，不拿文案去比，给人看的名字（`friendlyName`、`pickedLabel`、`Usage.partName`）都从它派生，`FindingKindTests` 逐字锁着 |
| 安全 / 需确认 / 只展示 | `Risk.safe` / `.confirm` / `.readOnly` | 风险等级。只展示的任何路径都删不了。易混：标 `safe` 不等于能清，能不能清看 `cleanup` |
| 怎么清 | `Cleanup.trash` / `.remove` / `.command` / `.none` | 移到废纸篓 / 直接删（只给可再生的目录）/ 跑工具自带的清理命令 / 清不了 |
| 默认勾选 | `Finding.suggested` | 扫描规则建议清它。扫描器给初值，之后三道调整：命令找不到（`applyAvailability`）、上次几乎没释放（`applyHistory`）、用户选过保留（`applyDecisions`） |
| 现在勾着 | `Store.selected` | 用户此刻在界面上勾着的项，初值是所有默认勾选的 |
| 能不能勾 | `Finding.selectable`（应用层） | 不是只展示、而且有清理方式。易混：核心层另有 `Cleanup.runnable`，意思几乎一样 |

## 首页三段

| 界面上 | 代码里 | 意思 |
|---|---|---|
| 替你挑好的 | `Bucket.picked` | 默认勾选、能执行，一键清 |
| 要你说一句 | `Bucket.ask` | 只有用户知道还要不要：下载里久没打开的、一个月没用的虚拟机 |
| 先不动 | `Bucket.keep` | 在用、留着保底、清了也没用，或清不了；每项写明原因 |
| 对话记录 | `Bucket.records` | 只展示的。易混：说「三段」，枚举有四个值 |
| 保留（卡片上的按钮） | `Decisions.kept` | 用户说留着：不再问、不再默认勾选，涨了超过 1 GB 重新问。存在 `decisions.json` |
| 下周再问 | `Decisions.snoozed` | 到下一次周报前不催 |
| 「保留」标签（访达里打的） | `DownloadsRules.keepTag` | 下载文件夹里打了这个标签的文件不扫 |

易混：`picked` 在别处还有三个意思，`Store.picked(_ page)` 是「这一页里现在勾着的」，`Alerts.autoCleanPicks` 是「自动清理会清的」，`MemoryPlan.picked` 是内存页的「替你挑好的」。`Page.keep` 这一页除了先不动的，还列着看不见的里要问的项。

## 记录文件

都在 `~/Library/Application Support/disk-slim/`。

| 文件 | 代码里 | 记什么 |
|---|---|---|
| `history.json` | `OperationLog`、`Batch`、`ItemResult`（在 `Cleaner.swift`） | 每次清理一批的结果，撤销靠它。易混：`History.swift` 里只有按上次结果校正勾选的 `applyHistory` |
| `usage.json` | `UsageLog`、`UsageSample`（`Usage.swift`） | 每天一份可用空间和各位置大小。界面和命令行叫「涨幅」（`growth`、`GrowthPage`），是同一个功能 |
| `decisions.json` | `DecisionLog`、`Decisions`（`Decisions.swift`） | 保留、下周再问 |
| `alerts.json` | `AlertStore`、`AlertState`（`Alerts.swift`） | 提醒开关、每条提醒上次发在哪天、自动清理上次时间 |
| `memory.json` | `MemoryLog`、`MemoryRecord`（`MemoryRecord.swift`） | 内存曲线、应用最后使用时间、会话忙闲、几个「别问」 |
| `status.json` | `StatusFile`（`Pendant.swift`） | 给驿窗挂件读的可用空间和档位 |

易混：核心层的 `…Log` / `AlertStore` 是一个 JSON 文件的读写；应用层的 `Store` 是整个界面的状态，`Store+Memory.swift` 是它的扩展。`MemoryUsage` 是内存归属，和 `Usage`（磁盘涨幅）无关。

## 能不能删，查四道

| 哪一道 | 代码里 | 查什么 |
|---|---|---|
| 安全门 | `SafetyGuard.refusal` | 路径和命令在不在白名单里、有没有符号链接。不信任传进来的 `Finding` |
| 执行前复核 | `Scan.recheck` | 扫描后会变的：下载项新标了「保留」；构建产物还是不是 Rust 构建目录、在不在用 |
| 工具在不在跑 | `Place.busyWhen`、`SafetyGuard.busyMarkers` | Homebrew 正在下载、npm 等正在装依赖时不清 |
| 目录在不在用 | `Cleaner` 直接删除那一支 | 有进程从里面运行（`ps`、`lsof`），或 cargo 正在编译（拿不到锁） |

## 空间和内存的档位

| 界面上 | 代码里 | 意思 |
|---|---|---|
| 可用空间三档（绿 / 橙 / 红） | `SpaceLevel.ok` / `.low` / `.critical`（在 `Model.swift`） | 可用空间 60 GB 以上 / 低于 60 GB / 低于 30 GB。两个阈值只写在 `SpaceLevel.lowBytes`、`criticalBytes`，提醒规则和界面颜色都从这里取 |
| 正常 / 偏紧 / 告急（内存） | `MemoryLevel` | 照系统自己的内存压力档位 |
| 刚开始记 | `learning` | 还看不出闲不闲。易混：应用是开始记录不满 4 小时，Claude 会话是第一次见到不满 12 小时 |
| 忙 | `busy`、`ActivityTrack` | 一个采样间隔里整棵进程树 CPU 用到 5% 以上；间隔太长看不准的也算忙 |

## 入口和面板

| 界面上 | 代码里 | 意思 |
|---|---|---|
| 挂件 | `Pendant.swift`：`StatusFile`、`PanelLink`、`PanelToggle` | 驿窗侧栏的扫帚浮游兽，现在唯一默认开着的入口。点它时驿窗发 `diskslim://panel/toggle` |
| 悬浮球 | `FloatingBall`、`BallView` | 桌面上贴边的球，默认关 |
| 面板 | `FloatingPanel`、`PanelView` | 挂件和悬浮球点开的是同一个面板。易混：面板的开关和摆放都写在 `FloatingBall` 类里 |
| 磁盘 / 内存 | `PanelTab` | 面板顶上的切换 |
| 下钻页 | `Page` | 首页之外的页面 |

## 交接和注释里的简称

- 「第 N 批」：`docs/PRD.md` 第 7 节的分批计划。
- 「B1～B12」：`docs/reviews/2026-11-05-全面审查与优化建议.md` 的问题编号。
- 「审查高 / 中 / 低 N」：第 11 批内存的独立审查编号，清单在 `CURRENT.md`「第 11 批：内存」一节。
- 「L-xx」：`docs/LESSONS.md`；「G-xx」：全局坑 `agent-kit/LESSONS.md`。
