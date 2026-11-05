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
