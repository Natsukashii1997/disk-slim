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
- 根因：未查明。工具链是 CommandLineTools 里的 Swift 6.4（没有完整 Xcode），宏插件目录存在；怀疑和增量编译缓存有关，未核实。
- 正确做法：遇到这条报错原样重跑一次 `swift test`；连续两次都报再停下来查。交接里如实写出现过几次。
- 证据：第 2 批交接「测试」一行；第 3 批连跑记录（本会话）。
- 升级：同类第 2 次，已写进 AGENTS.md「运行」。

## L-05 清理命令腾出的空间远小于目录大小，首页「可清」被高估（2026-11-05）

- 现象：用户在应用里点「清理建议项」，首页写可清 1.0 GB，实际只释放 144 MB（全是 npm）；`pnpm store prune` 释放 0（469 MB 全有项目在用），`brew cleanup -s` 释放 0（283 MB 是 Homebrew 自己要留的）。下次打开这两项还会默认勾选，每次都白点。
- 根因：清理命令类的项用「目录大小」当「可清大小」，但命令只删其中一部分，事先算不出。
- 正确做法：用操作记录校正：最近 30 天同一条命令上次实际释放不到 10 MB，就不再默认勾选，说明里写上次的结果（`Sources/DiskSlimCore/History.swift`，测试 `HistoryTests`）。
- 证据：`~/Library/Application Support/disk-slim/history.json` 11:54 那一批；修复后扫描 `evidence/2026-11-05-scan-after-fix.txt`。
- 升级：未升级。

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
