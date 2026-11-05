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
- 条目超过约 30 条时整理一次：已升级、且之后没再犯的，归档到 `docs/history/`。

---

## L-01 `npm cache clean --force` 清完 `~/.npm` 还剩 1 GB（2026-11-05）

- 现象：清过 npm 缓存后，`~/.npm` 仍有约 1.2 GB；扫描若按整个 `~/.npm` 计算，「npm 缓存」永远显示 1 GB 多，清了也不变。
- 根因：`npm cache clean` 只清 `~/.npm/_cacache`；剩下的大头在 `~/.npm/_npx`，是 npx 运行过的工具，命令不管它。有些 MCP 服务由 npx 启动，正在用这里的文件。
- 正确做法：「npm 缓存」只算 `.npm/_cacache`、用官方命令清；`.npm/_npx` 单列为「需确认」，提示先关掉 Claude、Codex 再清（`Sources/DiskSlimCore/KnownPlaces.swift`）。
- 证据：2026-11-05 `du -shx ~/.npm/*`：`_npx` 1.0G、`_cacache` 144M；扫描输出见 `~/Library/Application Support/disk-slim/evidence/2026-11-05-scan.txt`。
- 升级：未升级。

## L-02 测试里比较临时目录路径失败：`/var` 与 `/private/var`（2026-11-05）

- 现象：worktree「正在编译」判定的单元测试失败，`ps` 输出里明明有该 worktree 的路径。
- 根因：macOS 的临时目录在 `/var/folders/...`，`/var` 是指向 `/private/var` 的符号链接；扫描时拿到的路径和测试拼出来的路径写法不同，字符串比较不相等。
- 正确做法：拿路径和外部输出做字符串比较时，同时比原路径和 `resolvingSymlinksInPath()` 后的路径（`WorktreeScanner.blockers`）。
- 证据：第 1 批 `swift test` 首跑失败记录（本会话）；修复后 12/12 通过。
- 升级：未升级。

## L-03 macOS 不区分大小写：只差大小写的目录、目标、可执行文件会撞在一起（2026-11-05）

- 现象：① 第 1 批把 Swift 测试写到 `Tests/`，实际落进已有的 `tests/`；② 第 3 批把应用代码写到 `Sources/DiskSlim/`，实际和命令行的 `Sources/diskslim/main.swift` 混在一个目录，编译报重复声明；分开目录后，可执行文件 `DiskSlim` 和 `diskslim` 在 `.build/` 里又撞成同一个文件，链接失败。
- 根因：macOS 默认的 APFS 不区分大小写，`DiskSlim` 和 `diskslim` 是同一个路径；写文件、SwiftPM 的目标目录和产物目录都会悄悄合并。
- 正确做法：目录名、SwiftPM 目标名、可执行文件名之间不能只差大小写。现在命令行在 `Sources/DiskSlimCLI`（目标 `diskslim`），应用在 `Sources/DiskSlimApp`（目标 `DiskSlimApp`），测试路径在 `Package.swift` 写明。撞名后要 `rm -rf .build` 清掉旧产物。
- 证据：提交 `44d4bb2`（测试目录）；第 3 批编译错误「invalid redeclaration of 'total'」「no such file or directory ... diskslim-p.build/.../main.o」。
- 升级：同类第 2 次，已写进 AGENTS.md「规则」。换个项目也成立，提议提升为全局 G-xx（待用户批准）。

## L-04 `swift test` 偶发「plugin for module 'TestingMacros' not found」（2026-11-05）

- 现象：`swift test` 编译测试时偶尔报找不到 Swift Testing 的宏插件，什么都不改重跑一次就通过；第 2、3 批各出现一次，连跑三次是「通过、失败、通过」。
- 根因（2026-11-05 独立测试员查明）：只有 CommandLineTools、没有完整 Xcode 时，SwiftPM 只把 Observation、SwiftMacros 两个插件路径传给编译器，没传 Swift Testing 的；能不能找到插件看缓存状态，所以时好时坏。
- 正确做法：一律用 `scripts/test.sh` 跑测试，它补上 `-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`。
- 证据：第 2、3 批记录；测试员在新 worktree 里连续 3 次复现、加参数后每次通过；修复后本项目 `scripts/test.sh` 43 项一次通过。
- 升级：已写进 AGENTS.md「运行」（改为 `scripts/test.sh`）。换个只装 CommandLineTools 的 Swift 项目也成立，可一起提议提升为全局 G-xx。

## L-05 清理命令腾出的空间远小于目录大小，首页「可清」被高估（2026-11-05）

- 现象：用户在应用里点「清理建议项」，首页写可清 1.0 GB，实际只释放 144 MB（全是 npm）；`pnpm store prune` 释放 0（469 MB 全有项目在用），`brew cleanup -s` 释放 0（283 MB 是 Homebrew 自己要留的）。下次打开这两项还会默认勾选，每次都白点。
- 根因：清理命令类的项用「目录大小」当「可清大小」，但命令只删其中一部分，事先算不出。
- 正确做法：用操作记录校正：最近 30 天同一条命令上次实际释放不到 10 MB，就不再默认勾选，说明里写上次的结果（`Sources/DiskSlimCore/History.swift`，测试 `HistoryTests`）。
- 证据：`~/Library/Application Support/disk-slim/history.json` 11:54 那一批；修复后扫描 `evidence/2026-11-05-scan-after-fix.txt`。
- 升级：未升级。

## L-06 独立审查和测试发现的安全与正确性问题（2026-11-05）

- 现象：两个独立 agent（只读审查 + worktree 里的对抗测试）找到：① `brew cleanup -s` 默认会删已安装软件的旧版本、自动卸载没人依赖的软件，却被当成「安全的缓存」默认勾选；② worktree 目录是符号链接时，会把工作区以外真实的 `target/` 删掉；③ 撤销时有一项放不回就整批标成已撤销；④ `history.json` 损坏时被当成空记录，下次清理整个覆盖；⑤ 「24 小时内编译过」只看 `target/` 前两层，增量编译改的更深层文件看不到；⑥ 应用里扫描未完成时清理、清理中撤销，会显示过期结果或互相覆盖记录；以及名字以 `.zip` 结尾的文件夹被当压缩包、npx 标「需确认」却直接删、最近大文件可勾选、外部命令没超时、只按分支名认「已合并」、非 Rust 的 `target/` 也会被当构建产物、`--home` 沙盒下清理命令仍作用于真机。
- 根因：自己写的测试只覆盖了自己想到的输入；安全门只按路径字面核对；外部工具的副作用没去读源码。
- 正确做法：已全部修复（提交见交接）。以后：引入任何外部清理命令前先读它的源码或 `--dry-run` 看副作用；路径类安全检查一律考虑符号链接、`..`、大小写；每批做完让独立 agent 审查和对抗测试一次。
- 证据：测试员的 11 个对抗用例并入 `tests/DiskSlimCoreTests/ReviewAdversarialTests.swift`（修复前 5 个失败，修复后全过）；Homebrew 源码 `/opt/homebrew/Library/Homebrew/cleanup.rb:471`；用户 11:54 那次 `brew cleanup -s` 没有改动 Cellar（目录修改时间仍为 10 月 16 日）。
- 升级：「每批做完让独立 agent 审查和测试」写进 AGENTS.md「规则」。

## L-07 每日对比里「没量到」被当成 0，「最近 7 天」按 7×24 小时滚动多出第 8 天（2026-11-05）

- 现象：独立审查和对抗测试发现，涨幅排行在某天少了一个位置（下载文件夹没权限读、缓存刚跨过 50 MB 列出门槛）时，会报「下载文件夹 +10 GB」「其他 −11 GB」这类虚假大涨大跌；「最近 7 天」把 6 天 23 小时前、已经是第 8 个日期的记录也画进曲线；另有同一天后写的旧时间记录盖掉新记录、记录文件读失败时被一条新记录覆盖、离屏截图会挪走真实的坏记录文件、极端数值相减溢出崩溃。
- 根因：把「没有这一项」和「这一项是 0」混为一谈（`allocatedSize` 吞掉读错误返回 0、列出门槛决定了有没有这一项）；按日期展示的东西用了时长窗口；读文件时没区分「不存在」和「读不了」。
- 正确做法：大小读不全就记「没量到」（`allocatedSizeIfReadable` 返回 nil）；对比两天时只单列两边都有的位置，只在一边出现的不到 1 GB 归进「其他」、下载文件夹一律归进「其他」；按北京日期（`BeijingTime.dayNumber`）切窗口；写入前文件在但读不了就报错不写；差值一律用不会溢出的加减。
- 证据：`tests/DiskSlimCoreTests/GrowthAdversarialTests.swift`（对抗测试员写的 46 项，修复前 13 项失败）、`UsageTests.swift` 新增 5 项；沙盒输出 `evidence/2026-11-05-growth-sandbox/growth-output-after-review.txt`。
- 升级：未升级。「缺测值不能当 0、按日期展示就按日期切」换个项目也成立，提议提升为全局 G-xx，等用户批准。

## L-08 Swift 自动生成的 Codable 不用属性默认值：缺一个键整份读不出来（2026-11-05）

- 现象：对抗测试发现，`alerts.json` 少了一个开关、或 `decisions.json` 里一条「下周再问」的日期写坏，整份文件就按默认值处理：用户关掉的提醒重新打开、同一天的提醒重发，所有「保留」丢掉、保留过的下载文件重新被默认勾选，点「清理建议项」就会移走。
- 根因：结构体属性写了默认值，但编译器合成的 `init(from:)` 仍要求每个键都在、每个值都合法，任何一处失败整个解码抛错，外面的 `try?` 再把它变成「全部默认」。
- 正确做法：用户数据文件的结构体手写 `init(from:)`，逐个字段 `decodeIfPresent ?? 默认值`；字典里逐条宽松解码（坏一条丢一条，见 `Weekly.swift` 的 `Lenient`）；整份读不出来时先改名留底再写。
- 证据：`tests/DiskSlimCoreTests/AlertsAdversarialTests.swift` 里 `autoClean字段缺失_…`、`sent字段缺失_…`、`某个开关缺失_…`、`某个下周再问的日期坏了_…`、`缺snoozed字段_…`，修复前失败、修复后通过。
- 升级：未升级。换个项目也成立，提议提升为全局 G-xx，等用户批准。

---

格式：

```markdown
## L-01 <一句话现象>（<YYYY-MM-DD>）

- 现象：
- 根因：
- 正确做法：
- 证据：
- 升级：未升级。
```
