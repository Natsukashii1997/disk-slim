# 开发实录与坑

踩过的坑记在这里，Claude 和 Codex 都读。排障、发布、改脚本之前，先搜一遍：`grep -n 关键词 docs/LESSONS.md`；换个项目也成立的坑在全局 `/Users/nat/Documents/ChatGPT/个人/work/agent-kit/LESSONS.md`（G-xx），也搜一遍。

## 怎么写

- 每轮交接时自问「本轮踩到新坑了吗」：有就在下面追加一条，并在 CURRENT.md 的交接里写「本轮新坑：L-xx」；没有就写「无」。
- 一条一个坑，编号只增不改。写现象、根因、正确做法、证据。证据写到能查的程度（提交号、文件与章节、证据目录）；查不到就写「未核实」，不编。
- 结论被推翻时改条目并注明日期，不删。

## 怎么升级

- 同类坑第 2 次出现：把正确做法写进 AGENTS.md 或 docs/OPERATIONS.md（一句话硬约束进 AGENTS.md，操作细节进 OPERATIONS.md），条目的「升级」改成写到了哪里。
- 能用机器判定的：写成测试或脚本（如 `scripts/check-rules.mjs`），条目注明。
- 换个项目也成立的（不依赖本项目的业务、页面、发布脚本）：提议提升到全局坑 `/Users/nat/Documents/ChatGPT/个人/work/agent-kit/LESSONS.md`，写成 G-xx；原条目保留，末尾加一行「提升：已提升为全局 G-xx（日期）」。只出提案，用户批准才写。
- 「升级」一行开头写五个层级词之一：〔结构〕〔机检〕〔体检〕〔文字〕〔提醒〕，后面写状态（未升级 / 部分升级 / 已升级 / 关闭）和去处；层级变了就改标签，原来的记录保留。坑本身已被代码消除、不再需要升级的写「〔层级〕关闭（日期，依据）：证据」，层级写现在靠什么守住（回归测试没接进必经检查的写〔提醒〕）。层级怎么选见全局 LESSONS「怎么升级」；只能手动跑的测试不算〔机检〕。`scripts/check-rules.mjs` 的 lessons 规则会检查每条都有这一行、开头是层级词。
- 条目超过约 30 条时整理一次：已升级、且之后没再犯的，归档到 `docs/history/`。

---

## L-01 `npm cache clean --force` 清完 `~/.npm` 还剩 1 GB（2026-11-05）

- 现象：清过 npm 缓存后，`~/.npm` 仍有约 1.2 GB；扫描若按整个 `~/.npm` 计算，「npm 缓存」永远显示 1 GB 多，清了也不变。
- 根因：`npm cache clean` 只清 `~/.npm/_cacache`；剩下的大头在 `~/.npm/_npx`，是 npx 运行过的工具，命令不管它。有些 MCP 服务由 npx 启动，正在用这里的文件。
- 正确做法：「npm 缓存」只算 `.npm/_cacache`、用官方命令清；`.npm/_npx` 单列为「需确认」，提示先关掉 Claude、Codex 再清（`Sources/DiskSlimCore/KnownPlaces.swift`）。
- 证据：2026-11-05 `du -shx ~/.npm/*`：`_npx` 1.0G、`_cacache` 144M；扫描输出见 `~/Library/Application Support/disk-slim/evidence/2026-11-05-scan.txt`。
- 升级：〔提醒〕关闭（2026-11-19，积压清单组 15）：核实坑已被代码消除：`Sources/DiskSlimCore/KnownPlaces.swift` 第 42 行起「npm 缓存」只算 `.npm/_cacache`、用官方命令清，第 59 行把 `.npm/_npx` 单列为需确认；没有专门报红的回归测试，靠清理清单的写法守住。此前：〔提醒〕未升级。原记录：未升级。

## L-02 测试里比较临时目录路径失败：`/var` 与 `/private/var`（2026-11-05）

- 现象：worktree「正在编译」判定的单元测试失败，`ps` 输出里明明有该 worktree 的路径。
- 根因：macOS 的临时目录在 `/var/folders/...`，`/var` 是指向 `/private/var` 的符号链接；扫描时拿到的路径和测试拼出来的路径写法不同，字符串比较不相等。
- 正确做法：拿路径和外部输出做字符串比较时，同时比原路径和 `resolvingSymlinksInPath()` 后的路径（`WorktreeScanner.blockers`）。
- 证据：第 1 批 `swift test` 首跑失败记录（本会话）；修复后 12/12 通过。
- 升级：〔提醒〕未升级（已批：积压清单组 10，与 L-03、L-09 合并提升为全局 G-38）。原记录：未升级。
- 提升：已提升为全局 G-38（2026-11-19，agent-kit#83）。

## L-03 macOS 不区分大小写：只差大小写的目录、目标、可执行文件会撞在一起（2026-11-05）

- 现象：① 第 1 批把 Swift 测试写到 `Tests/`，实际落进已有的 `tests/`；② 第 3 批把应用代码写到 `Sources/DiskSlim/`，实际和命令行的 `Sources/diskslim/main.swift` 混在一个目录，编译报重复声明；分开目录后，可执行文件 `DiskSlim` 和 `diskslim` 在 `.build/` 里又撞成同一个文件，链接失败。
- 根因：macOS 默认的 APFS 不区分大小写，`DiskSlim` 和 `diskslim` 是同一个路径；写文件、SwiftPM 的目标目录和产物目录都会悄悄合并。
- 正确做法：目录名、SwiftPM 目标名、可执行文件名之间不能只差大小写。现在命令行在 `Sources/DiskSlimCLI`（目标 `diskslim`），应用在 `Sources/DiskSlimApp`（目标 `DiskSlimApp`），测试路径在 `Package.swift` 写明。撞名后要 `rm -rf .build` 清掉旧产物。
- 证据：提交 `44d4bb2`（测试目录）；第 3 批编译错误「invalid redeclaration of 'total'」「no such file or directory ... diskslim-p.build/.../main.o」。
- 升级：〔文字〕已升级：AGENTS.md「规则」（目录名、目标名、可执行文件名不能只差大小写）。另已批：积压清单组 10，并入全局 G-38。原记录：同类第 2 次，已写进 AGENTS.md「规则」。换个项目也成立，提议提升为全局 G-xx（待用户批准）。
- 提升：已提升为全局 G-38（2026-11-19，agent-kit#83）。

## L-04 `swift test` 偶发「plugin for module 'TestingMacros' not found」（2026-11-05）

- 现象：`swift test` 编译测试时偶尔报找不到 Swift Testing 的宏插件，什么都不改重跑一次就通过；第 2、3 批各出现一次，连跑三次是「通过、失败、通过」。
- 根因（2026-11-05 独立测试员查明）：只有 CommandLineTools、没有完整 Xcode 时，SwiftPM 只把 Observation、SwiftMacros 两个插件路径传给编译器，没传 Swift Testing 的；能不能找到插件看缓存状态，所以时好时坏。
- 正确做法：一律用 `scripts/test.sh` 跑测试，它补上 `-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`。
- 证据：第 2、3 批记录；测试员在新 worktree 里连续 3 次复现、加参数后每次通过；修复后本项目 `scripts/test.sh` 43 项一次通过。
- 升级：〔提醒〕不升级（2026-11-19，积压清单组 16）：本机只有这一个 Swift 项目，已统一用 `scripts/test.sh`，不再往上升；AGENTS.md「运行」里「不要直接用 swift test，原因见 L-04」那句还在（第 30 行），照旧有效。此前：〔文字〕已升级：AGENTS.md「运行」（一律用 `scripts/test.sh`，不直接用 `swift test`）。原记录：已写进 AGENTS.md「运行」（改为 `scripts/test.sh`）。换个只装 CommandLineTools 的 Swift 项目也成立，可一起提议提升为全局 G-xx。

## L-05 清理命令腾出的空间远小于目录大小，首页「可清」被高估（2026-11-05）

- 现象：用户在应用里点「清理建议项」，首页写可清 1.0 GB，实际只释放 144 MB（全是 npm）；`pnpm store prune` 释放 0（469 MB 全有项目在用），`brew cleanup -s` 释放 0（283 MB 是 Homebrew 自己要留的）。下次打开这两项还会默认勾选，每次都白点。
- 根因：清理命令类的项用「目录大小」当「可清大小」，但命令只删其中一部分，事先算不出。
- 正确做法：用操作记录校正：最近 30 天同一条命令上次实际释放不到 10 MB，就不再默认勾选，说明里写上次的结果（`Sources/DiskSlimCore/History.swift`，测试 `HistoryTests`）。
- 证据：`~/Library/Application Support/disk-slim/history.json` 11:54 那一批；修复后扫描 `evidence/2026-11-05-scan-after-fix.txt`。
- 升级：〔提醒〕关闭（2026-11-19，积压清单组 15）：核实坑已被代码消除：`Sources/DiskSlimCore/History.swift` 的 `applyHistory` 按操作记录校正（30 天内同一条命令上次释放不到 10 MB 就不默认勾选），扫描入口 `Scan.swift` 第 25 行接上；靠测试 `HistoryTests` 守住，测试未接进必经检查（本项目没有提交前钩子和 CI）。此前：〔提醒〕部分升级（已写测试 `HistoryTests`，未接进必经检查）。原记录：未升级。

## L-06 独立审查和测试发现的安全与正确性问题（2026-11-05）

- 现象：两个独立 agent（只读审查 + worktree 里的对抗测试）找到：① `brew cleanup -s` 默认会删已安装软件的旧版本、自动卸载没人依赖的软件，却被当成「安全的缓存」默认勾选；② worktree 目录是符号链接时，会把工作区以外真实的 `target/` 删掉；③ 撤销时有一项放不回就整批标成已撤销；④ `history.json` 损坏时被当成空记录，下次清理整个覆盖；⑤ 「24 小时内编译过」只看 `target/` 前两层，增量编译改的更深层文件看不到；⑥ 应用里扫描未完成时清理、清理中撤销，会显示过期结果或互相覆盖记录；以及名字以 `.zip` 结尾的文件夹被当压缩包、npx 标「需确认」却直接删、最近大文件可勾选、外部命令没超时、只按分支名认「已合并」、非 Rust 的 `target/` 也会被当构建产物、`--home` 沙盒下清理命令仍作用于真机。
- 根因：自己写的测试只覆盖了自己想到的输入；安全门只按路径字面核对；外部工具的副作用没去读源码。
- 正确做法：已全部修复（提交见交接）。以后：引入任何外部清理命令前先读它的源码或 `--dry-run` 看副作用；路径类安全检查一律考虑符号链接、`..`、大小写；每批做完让独立 agent 审查和对抗测试一次。
- 证据：测试员的 11 个对抗用例并入 `tests/DiskSlimCoreTests/ReviewAdversarialTests.swift`（修复前 5 个失败，修复后全过）；Homebrew 源码 `/opt/homebrew/Library/Homebrew/cleanup.rb:471`；用户 11:54 那次 `brew cleanup -s` 没有改动 Cellar（目录修改时间仍为 10 月 16 日）。
- 升级：〔文字〕已升级：AGENTS.md「规则」（引入外部清理命令前先读源码或 `--dry-run`；每批做完让独立 agent 只读审查和对抗测试）；对抗用例在 `ReviewAdversarialTests`，未接进必经检查。积压清单没列这一条。原记录：「每批做完让独立 agent 审查和测试」写进 AGENTS.md「规则」。

## L-07 每日对比里「没量到」被当成 0，「最近 7 天」按 7×24 小时滚动多出第 8 天（2026-11-05）

- 现象：独立审查和对抗测试发现，涨幅排行在某天少了一个位置（下载文件夹没权限读、缓存刚跨过 50 MB 列出门槛）时，会报「下载文件夹 +10 GB」「其他 −11 GB」这类虚假大涨大跌；「最近 7 天」把 6 天 23 小时前、已经是第 8 个日期的记录也画进曲线；另有同一天后写的旧时间记录盖掉新记录、记录文件读失败时被一条新记录覆盖、离屏截图会挪走真实的坏记录文件、极端数值相减溢出崩溃。
- 根因：把「没有这一项」和「这一项是 0」混为一谈（`allocatedSize` 吞掉读错误返回 0、列出门槛决定了有没有这一项）；按日期展示的东西用了时长窗口；读文件时没区分「不存在」和「读不了」。
- 正确做法：大小读不全就记「没量到」（`allocatedSizeIfReadable` 返回 nil）；对比两天时只单列两边都有的位置，只在一边出现的不到 1 GB 归进「其他」、下载文件夹一律归进「其他」；按北京日期（`BeijingTime.dayNumber`）切窗口；写入前文件在但读不了就报错不写；差值一律用不会溢出的加减。
- 证据：`tests/DiskSlimCoreTests/GrowthAdversarialTests.swift`（对抗测试员写的 46 项，修复前 13 项失败）、`UsageTests.swift` 新增 5 项；沙盒输出 `evidence/2026-11-05-growth-sandbox/growth-output-after-review.txt`。
- 升级：〔提醒〕部分升级（已写测试 `GrowthAdversarialTests`、`UsageTests`，未接进必经检查；已批：积压清单组 11，与 L-08 合并提升为全局 G-39）。原记录：未升级。「缺测值不能当 0、按日期展示就按日期切」换个项目也成立，提议提升为全局 G-xx，等用户批准。
- 提升：已提升为全局 G-39（2026-11-19，agent-kit#83）。

## L-08 Swift 自动生成的 Codable 不用属性默认值：缺一个键整份读不出来（2026-11-05）

- 现象：对抗测试发现，`alerts.json` 少了一个开关、或 `decisions.json` 里一条「下周再问」的日期写坏，整份文件就按默认值处理：用户关掉的提醒重新打开、同一天的提醒重发，所有「保留」丢掉、保留过的下载文件重新被默认勾选，点「清理建议项」就会移走。
- 根因：结构体属性写了默认值，但编译器合成的 `init(from:)` 仍要求每个键都在、每个值都合法，任何一处失败整个解码抛错，外面的 `try?` 再把它变成「全部默认」。
- 正确做法：用户数据文件的结构体手写 `init(from:)`，逐个字段 `decodeIfPresent ?? 默认值`；字典里逐条宽松解码（坏一条丢一条，见 `Weekly.swift` 的 `Lenient`）；整份读不出来时先改名留底再写。
- 证据：`tests/DiskSlimCoreTests/AlertsAdversarialTests.swift` 里 `autoClean字段缺失_…`、`sent字段缺失_…`、`某个开关缺失_…`、`某个下周再问的日期坏了_…`、`缺snoozed字段_…`，修复前失败、修复后通过。
- 升级：〔提醒〕部分升级（已写测试 `AlertsAdversarialTests`，未接进必经检查；已批：积压清单组 11，已并入全局 G-39）。原记录：未升级。换个项目也成立，提议提升为全局 G-xx，等用户批准。
- 提升：已提升为全局 G-39（2026-11-19，agent-kit#83）。

## L-09 安装脚本认不出自己的进程：`ps` 在 C 区域设置下把路径里的中文转义成 `M-dM-8…`（2026-11-05）

- 现象：`scripts/install.sh` 第一次真机安装时，旧的 dist 版进程没被停掉，菜单栏同时出现两份磁盘瘦身；脚本照常打印「已安装并启动」。
- 根因：脚本用 `ps -p <pid> -o comm=` 取可执行文件路径再和期望路径比；脚本环境是 C 区域设置，`ps` 把「个人」输出成 `M-dM-8M-*M-dM-:M-:`，字符串永远对不上。
- 正确做法：取进程路径时加 `LC_ALL=en_US.UTF-8`；装完用 `pgrep -fl` 核对只剩一份，不能只看脚本的成功提示。
- 补充（全面审查 B1）：Swift 里起子进程同样要设。菜单栏应用从访达 / 登录项启动时环境里根本没有 LANG / LC_*，`ProcessRunner` 跑 `ps` 也会转义，导致「有进程在用这个构建产物」永远认不出；已在 `ProcessRunner` 里统一设 `LC_ALL=en_US.UTF-8`，测试 `FullReviewTests` 覆盖。
- 证据：`evidence/2026-11-05-install.txt`（两份并存）、`evidence/2026-11-05-install-2.txt`（修复后只剩新装的一份）。
- 升级：〔提醒〕部分升级（已写测试 `ProcessRunnerLocaleTests`（原 `FullReviewProcessTests`，2026-11-20 测试重组时改名） 的 `没有区域设置时_正在使用的构建产物不该被删`，只管 `ProcessRunner`，`scripts/install.sh` 没有测试；未接进必经检查；已批：积压清单组 10，已并入全局 G-38）。原记录：未升级。路径带中文的项目都会踩，提议提升为全局 G-xx，等用户批准。
- 提升：已提升为全局 G-38（2026-11-19，agent-kit#83）。

## L-10 安全门只管「要清的路径」，工具自己新加的工作目录（暂存目录）漏了符号链接检查（2026-11-05）

- 现象：第 7 批为了「先改名再删」加了暂存目录 `<history.json 所在目录>/deleting`，每次清理开头补删里面的残留。审查员把 `deleting` 换成指向别处的符号链接，跑一次清理，链接指向的目录被永久清空，自动清理也会触发。
- 根因：SafetyGuard 只核对 Finding 里要清的路径；工具内部新加的、会被删除的目录没走同一套检查，补删又不分来源，见什么删什么。
- 正确做法：工具自己会删东西的任何目录，同样要 `lstat` 确认它和上一层不是符号链接、确实是目录；补删只删自己放进去的（名字是 UUID、放了一小时以上）；挪动只用 `rename(2)`，跨卷（EXDEV）不复制，改为原地删。
- 证据：`tests/DiskSlimCoreTests/Batch7ReviewTests.swift` 的 `暂存目录是符号链接时_…`，修复前失败、修复后通过；审查员沙盒演练 `evidence/review-batch7-20261105/clean-symlink-staging.txt`。
- 升级：〔提醒〕部分升级（已写测试 `Batch7ReviewTests` 的 `暂存目录是符号链接时_…`，未接进必经检查；已批：积压清单组 14，已提升为全局 G-41）。原记录：未升级。「新加的删除路径也要过安全门」换个项目也成立，提议提升为全局 G-xx，等用户批准。
- 提升：已提升为全局 G-41（2026-11-19，agent-kit#83）。

## L-11 用 computer-use 点自绘的悬浮球，结果不能当真（2026-11-06）

- 现象：第 8 批真屏实测时，后台 `app_click` 能打开面板，全屏 `left_click` 点球却打不开，球还被挪走过一次，看上去像球坏了；换成自己发系统级鼠标事件后，点开、拖动全都正常。
- 根因：① 后台 `app_click` 走无障碍「按下」，直接调 `accessibilityPerformPress`，绕过了球自己的 `mouseDown` 拖动判断和全局点击监听；② 全屏 `left_click` 会把指针挪过去点、再挪回原处，球的拖动循环可能把这当成超过 4 点的拖动；③ 全屏控制期间 Claude 在屏幕右侧（约 x 1380–1900、y 50–770）放了一个 level 3 的浮窗，和球同层且在上面，右边的球点不到；④ 截图会隐藏未授权的应用，前台应用跟着变，焦点测试被搅乱。
- 正确做法：测自绘的点击、拖动控件和焦点时，先退出全屏控制，用 CGEvent 往 `.cghidEventTap` 发按下、拖动、松开和按键（脚本见 `evidence/2026-11-06-floating-ball-realscreen/click.swift`）；窗口位置和是否在屏上用 `CGWindowListCopyWindowInfo` 回读，前台应用用 `lsappinfo front` 回读，不靠截图判断状态；截图只留作证据。
- 证据：`evidence/2026-11-06-floating-ball-realscreen/`（截图与脚本）；CURRENT.md 第 8 批「真屏实测」一条。
- 升级：〔提醒〕未升级（已批：积压清单组 9，与驿窗 L-09、L-11 合并提升为全局 G-37）。原记录：未升级。「computer-use 的点击不能代表真实鼠标」换个项目也成立，提议提升为全局 G-xx，等用户批准。
- 提升：已提升为全局 G-37（2026-11-19，agent-kit#83）。

## L-12 SwiftUI 细线图标按钮点不中、菜单栏弹窗不能直接关窗口（2026-11-18）

- 现象：首页顶栏加缩小键「—」后真屏实测，CGEvent 点在横线上时灵时不灵；菜单栏图标弹出的面板用 `window.close()` 收起后，下次点菜单栏图标第一下打不开、要点两下；改用 `NSStatusBarButton.performClick`、`NSApp.deactivate()` 都收不起。
- 根因：① `.buttonStyle(.plain)` 的按钮只认图标画出来的像素，`minus` 只有一两个像素高，差一个像素就落空；② `MenuBarExtra(.window)` 自己记着「开着」，绕过它关窗口，它不知道，下一下点击被当成「收起」；③ 测试自身的坑：面板内容长到出滚动条时顶栏的键整体左移约 19 点，菜单栏读数变窄（47G→43G）图标也左移，固定坐标会点空。
- 正确做法：细线、小图标做按钮时给 label 加 `.frame(...)` 和 `.contentShape(Rectangle())`；菜单栏弹窗里要收起就用 `@Environment(\.dismiss)`，不要自己关窗口；真屏点击前先截图定位目标（`evidence/2026-11-18-minimize/findmin.py`），点之前再确认窗口还在屏上，否则会点到用户屏幕上别的窗口。
- 证据：`evidence/2026-11-18-minimize/`（`final-realscreen.txt`、`diag-log.txt` 诊断日志、截图与脚本）；CURRENT.md「面板顶栏加缩小键」一节。
- 升级：〔提醒〕未升级（已批：积压清单组 9，第③点并入全局 G-37；①② 是 SwiftUI 专属，不提升）。原记录：未升级。「细线图标按钮要放大点击区」「MenuBarExtra 用 dismiss 收起」换个 SwiftUI 项目也成立，提议提升为全局 G-xx，等用户批准。
- 提升：已提升为全局 G-37（2026-11-19，agent-kit#83）：只提升第③点。

## L-13 内存页离屏截图整张发灰；读进程环境变量会看到登录凭据；闲着的 Claude 会话也一直用 CPU（2026-11-18）

- 现象：① 第 11 批内存页的离屏截图（`--snapshot`）整张像蒙了一层灰，橙字变土黄，磁盘页同一次截图正常。② 想把 Claude Code 会话进程对上桌面版会话，用 `ps eww` 看环境变量，输出里有 `CLAUDE_CODE_OAUTH_TOKEN` 明文。③ 想按「CPU 时间不涨」判断会话闲着，实测 73 秒里闲了几天的会话也用了 1.3～1.9 秒 CPU，和刚用过的差不多。
- 根因：① 系统给的应用图标（`NSWorkspace.icon(forFile:)`）不论直接交给 `Image(nsImage:)` 还是先 `cgImage(forProposedRect:)` 再画，`ImageRenderer` 出来的整张图都变灰；关掉图标对照（`DS_NOICON`）就正常，推断是图标位图的色彩空间带歪了整张渲染（未查到文档）。② 桌面版把登录令牌放在子进程环境变量里。③ 会话进程空闲时也有固定的后台开销（约 2%）。
- 正确做法：① 图标先画进自己建的 sRGB 位图（`CGContext` + `NSGraphicsContext`）再用，见 `MemoryViews.swift` 的 `AppIcon.bitmap`。② 不读别的进程的环境变量；要对应会话只用命令行参数或桌面版自己的会话记录，而且这两样也对不准（一半会话命令行里没有编号，有编号的常指向父会话），本应用最终不做对应。③ 忙闲按整棵进程树每 5 分钟采样、CPU 用到 5% 以上才算忙，12 小时没忙算闲（`MemoryRecord.sample`）。
- 证据：`evidence/2026-11-18-memory/`（`snap1`～`snap3`、`snap-noicon` 对照截图；`cc-cpu-1.txt`、`cc-cpu-2.txt` 两次 CPU 时间）。
- 升级：〔提醒〕未升级（已批：积压清单组 14，第②点提升为全局 G-42，agent-kit#83另在 Bash 预检里拦读别的进程环境变量的命令；①③ 不提升）。原记录：未升级。① 换个 SwiftUI 项目也成立，提议提升为全局 G-xx，等用户批准。
- 提升：已提升为全局 G-42（2026-11-19，agent-kit#83）：只提升第②点。


## L-14 固定高度的面板里，中间区域被内容撑破，顶栏和页脚被挤出去（2026-11-18）

- 现象：面板定成 368×810 后，离屏截图里内容多的页（磁盘页加了「谁占着」、内存页有「替你挑好的」）顶栏和页脚都不见了：整列比 810 点高，被居中裁掉上下。
- 根因：中间区域写的是 `.frame(maxHeight: .infinity)`，没写 `minHeight`。SwiftUI 的弹性 frame 不给下限时，下限就是子视图自己的高度，内容多高它就多高，外面的固定 frame 压不住；`ScrollView` 也一样要给下限才会老实缩到剩余高度。
- 正确做法：要「铺满剩下的、放不下就滚」的区域一律写 `.frame(minHeight: 0, maxHeight: .infinity)`（见 `Views.swift` 的 `Scroller`）；离屏截图模式下 `ScrollView` 画不出来，换成普通堆叠时同样加 `minHeight: 0` 再 `.clipped()`。验收看顶栏和页脚是否都在、所有面板截图是否同一高度。
- 证据：`evidence/2026-11-18-fixed-size/snap1`（撑破）、`snap2`（修后 27 张面板截图都是 1620 像素高）。
- 升级：〔提醒〕不升级（2026-11-19，积压清单组 16）：SwiftUI 专属，本机只有这一个 SwiftUI 项目；已有统一组件 `Sources/DiskSlimApp/Views.swift` 第 46 行 `Scroller`。此前：〔提醒〕未升级。原记录：未升级。换个 SwiftUI 项目也成立，提议提升为全局 G-xx，等用户批准。

## L-15 SwiftUI 应用拿空的设置场景占位，启动时自己弹出一个透明窗口挡在屏幕中间（2026-11-19）

- 现象：去掉 `MenuBarExtra` 后，SwiftUI 的 `App` 至少要一个场景，放了 `Settings { EmptyView() }` 占位。装机后多出一个「磁盘瘦身 Settings」窗口（900×450，第 0 层，在屏幕上），内容是空的、截图看不见，但它确实盖在屏幕中间。
- 根因：只剩设置场景时，SwiftUI 启动会把它当主窗口打开；`LSUIElement` 和 `.accessory` 只管不进程序坞，不拦窗口。
- 正确做法：应用不需要 SwiftUI 场景时（只有自己管的 NSPanel、悬浮窗），不用 `App`，改成 `@main enum` + `NSApplication.shared.run()`，`AppDelegate` 用静态常量留住（`NSApplication.delegate` 是弱引用）。验收时按进程号列它的全部窗口（`CGWindowListCopyWindowInfo` 加 `.optionAll`），不只看截图。
- 证据：`evidence/2026-11-19-no-menubar/winfo.swift` 的输出（修前有「磁盘瘦身 Settings」窗口，修后刚启动时一个窗口都没有）。
- 升级：〔提醒〕未升级。换个 SwiftUI 项目也成立，提议提升为全局 G-xx，等用户批准。

## L-16 提醒从安装起一条没发出去、重启后应用没在跑，半个月没人发现；从「应用程序」启动找不到 uv、pnpm（2026-11-20）

- 现象：三件事同一天查出来。① `alerts.json` 从 11-05 起没变过，`sent` 里只有首次运行写的那一条，而这期间 `usage.json` 有 6 份每日记录低于 30 GB（最低 10.0 GB），一条低空间提醒都没发出去。② 11-20 06:03 重启后应用没起来，`status.json` 停在 06:00，当天周五 18:00 的周报漏发。③ 应用的环境里找不到 uv、pnpm 时，这两项照样默认勾选，点了只会被跳过（「没装 uv，跳过」）。这一条是按代码和环境变量推出来的，`history.json` 里没有出现过这种跳过（见下面「更正」）。
- 根因：① 通知权限是「已拒绝」（`--test-notify` 最后一行原样输出），应用只在提醒设置页红字提示，首页看不到；规则测试 108 项都过，但「确认收到通知」这条验收一直没做成。② 开机自启默认关，巡检又放在应用内定时器里，应用不在跑时没有任何别的东西会发现。③ 从「应用程序」或登录项启动时 PATH 很短，`ProcessRunner` 只补了 Homebrew；uv 在 `~/.local/bin`，pnpm 在 nvm 目录下，都找不到，而按历史校正只看成功过的记录，跳过的永远保持勾选。在终端里跑命令行一切正常，所以自测看不出来。
- 正确做法：① 提醒类功能的验收看落盘的送达记录（`alerts.json` 的 `sent` 有没有新增），不只看规则测试；装机后跑一次 `--test-notify`，最后一行必须是「已允许」。② 「应用在不在跑」要有应用以外的东西看着（体检项或自检命令），等常浩定。③ 「终端里好、应用里不好」先比两边的 PATH（同全局坑 G-19）；要靠外部命令的项，扫描时就查命令在不在（`applyAvailability`），自测用 `env -i HOME=$HOME PATH=/usr/bin:/bin:/usr/sbin:/sbin .build/release/diskslim scan` 模拟应用的环境。
- 证据：`evidence/review-2026-11-20/`（独立评估的命令输出）、`evidence/batch1-2026-11-20/test-notify.txt`（四条「没有通知权限」加「通知权限：已拒绝」）、`scan-app-env.txt` 与 `scan-terminal-env.txt`（同一时刻两种环境的扫描，默认勾选 2 项对 3 项）。
- 更正（2026-11-20 23:30，装机后）：应用的 PATH 取决于谁启动它，不是「装进应用程序就一定短」。用 `open` 从终端或 agent 会话启动（`scripts/install.sh` 最后一步就是）会带上调用方的 PATH，uv、pnpm 找得到，照常勾选、也真能清；从访达、登录项、驿窗挂件启动才是短 PATH。证据：同一份已装的可执行文件离屏渲染两次，`env -i` 短 PATH 下两项标「不能清」（`evidence/batch1-2026-11-20/snapshot-installed-appenv/6-先不动的.png`），`open -n -g /Applications/DiskSlim.app --args --snapshot …` 下 uv 在「替你挑好的」、pnpm 可勾（`snapshot-installed-launchservices/`）。所以同一台电脑上这两项能不能清，重启前后可能不一样；`applyAvailability` 让两种情况下显示都和实际一致，但没有消除差异。根治要在启动时取一次登录 shell 的 PATH，等常浩定（2026-11-22 常浩定做，第四批 issue #26：`LoginShell.path`，用 `-l` 不用 `-i`，交互式配置本机要 9 秒）。教训：「应用里是什么环境」不能只靠 `env -i` 模拟，要按它平时被启动的方式起一次。
- 补充（2026-11-22，查权限时）：权限也一样。从 agent 会话的终端直接跑 `/Applications/DiskSlim.app/Contents/MacOS/DiskSlimApp --snapshot …`，完全磁盘访问算在启动它的 Claude 头上（系统按「责任进程」判），常浩已经给了权限，首页照样提示「废纸篓读不了」；改用 `open -n -W --stdout <文件> /Applications/DiskSlim.app --args --snapshot <目录>` 起，提示就没了，下载文件夹里久未打开的文件也读得到了（`evidence/permissions-2026-11-22/snapshot/` 与 `snapshot-open/` 对照）。通知权限按应用包标识算，两种起法结果相同。教训：核对已装应用的权限，用 `open -n` 起，不直接跑包里的可执行文件。
- 升级：〔机检〕部分升级（2026-11-20，issue #18）：③ 已由 `CleanupCommandTests`「找不到清理命令的_不勾选」守住；① ② 未升级，建议加自检命令 `diskslim doctor` 或自动化体检项，等常浩定。③ 的排查思路换个项目也成立，已有全局 G-19 覆盖，不另提。

## L-17 各目录大小加起来远超已用空间，按 du 估的「能腾出」大多是虚的（2026-11-26）

- 现象：系统临时目录里 Chrome 的 `com.google.Chrome.code_sign_clone` 显示 222 GB（155 份整包克隆），删掉其中 142 份，`df` 可用空间没有增加（15.1 → 13.8 GB，期间别的程序在写盘）；`~/Sandbox/2026-11-22-postpane-508-red/target` 显示 21 GB，删掉只多出 6.1 GB。全盘各目录 `du` 加起来 547 GB，数据卷实际只用了 433.6 GB。
- 根因：APFS 克隆（`clonefile`、`cp -c`）互相共用数据块，`du` 每一份都按全额算；要等所有共用者都删掉，块才会释放。Chrome 每次启动都做一份签名克隆，正在运行的那一份还用着旧版本的块。和 issue #27（硬链接重复计算）是同一类问题：「显示大小」不等于「删掉能腾出」。
- 正确做法：给常浩报「能腾出多少」之前，先分清显示大小和实际能回收的空间；拿不准的写区间，或写「删了再用 df 实测」。清理时每一项前后都记 `df -k`，按差值报告。Chrome 签名克隆不再当清理对象推荐。
- 证据：`evidence/cleanup-2026-11-26/`（`df-before.txt`、`df-after-chrome.txt`、`df-before-sandbox.txt`、`df-after-sandbox.txt`、`df-before-caches.txt`、`df-after-caches.txt`、`chrome-clones-deleted.txt`、`caches-deleted.txt`）。
- 升级：〔文字〕未升级。「显示大小≠能腾出」换个项目也成立（任何磁盘清理），可提议提升为全局，等常浩定。

---

格式：

```markdown
## L-01 <一句话现象>（<YYYY-MM-DD>）

- 现象：
- 根因：
- 正确做法：
- 证据：
- 升级：〔提醒〕未升级。
```
