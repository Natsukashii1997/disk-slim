# 当前状态

更新：2026-11-05。第 1 批「扫描引擎」完成，在分支 `feat/scan-engine`。唯一下一步：用户确认后做第 2 批「清理执行与安全」（预览、进废纸篓、工具命令、日志、撤销），见 [docs/PRD.md](docs/PRD.md) 第 7 节。

## 第 1 批：扫描引擎与命令行工具（2026-11-05，Claude，用户同意做第 1 批；已提交到 `feat/scan-engine`、无需发布）

- 时间：开工 `2026-11-05 11:22`（估计值：本轮开工时漏了用 `date` 记录，取首次提交之后、本轮收尾 `date` 11:28 之前）。来由：PRD 第 7 节第 1 批，先做只读扫描、不做界面。
- 改了哪些文件：新建 `Package.swift`；`Sources/DiskSlimCore/`（`Model.swift` 数据模型与「只展示项不可清」的强制；`System.swift` Spotlight 元数据、占用大小、外部命令、北京时间与大小格式；`DownloadsScanner.swift` 下载区四类规则；`WorktreeScanner.swift` worktree 构建产物四条件；`KnownPlaces.swift` 缓存 / 需确认 / 只展示；`Scan.swift` 总入口）；`Sources/diskslim/main.swift` 命令行；`Tests/DiskSlimCoreTests/` 四个测试文件；改 `AGENTS.md`（运行命令、结构）、`docs/LESSONS.md`（L-01、L-02）。
- 测试：`swift test` 原样结果 `✔ Test run with 12 tests in 4 suites passed`；`node --test tests/*.test.mjs` 原样结果「ℹ tests 4 ℹ pass 4 ℹ fail 0」；`node scripts/check-rules.mjs` 输出「通用规则检查通过」。首跑 `swift test` 有 5 处失败：2 处是测试把小文件的块大小（4 KB）当成了大文件，改了测试的阈值；3 处是 L-02 的路径问题，改了代码。
- 验证：真实磁盘只读扫描（`.build/release/diskslim scan`），用时 2.8 秒，可用 80.6 GB / 460.4 GB；输出存 `~/Library/Application Support/disk-slim/evidence/2026-11-05-scan.txt` 与 `.json`（185 项）。和今天上午手动排查对账：Codex 备份 10.9 GB（手动 11 GB）、Colima 4.4 GB、Cowork 虚拟机 10.3 GB（手动 10 GB）、Claude 对话 4.4 GB、Codex 对话 31.5 GB（手动 31 GB）、Homebrew 283 MB、pnpm 469 MB，一致；上午已清的 14 个 worktree 构建产物、uv、pip、Playwright、Puppeteer 都不再出现。
- 截图：无界面改动，无。
- 发布与回读：无需发布。
- 与授权不一致之处、遗留问题、范围外发现：① 扫描发现 postpane 一小时内又新增 `50-strip-tokens`、`52-agent-panel` 两个 worktree，加上 `48-approval-list` 共 22.7 GB 构建产物，可用空间从 91 GB 掉到 80.6 GB，根因仍是每个 worktree 独立全量编译，需要在 postpane 里改，本项目不动；② 「正在编译」只能认出命令行里带 worktree 路径的进程，在 worktree 里直接 `cargo build` 的认不出，靠「24 小时内编译过」兜底（`WorktreeScanner.swift` 注释）；③ 下载区「久未打开」有 150 多项，多数是几百 KB 的截图和文档，界面上要默认折叠、按大小排序（第 3 批处理）；④ 界面预览 `docs/design/ui-v1.html` 里写「已解压」的两个压缩包是示例，实际旁边没有文件夹；⑤ 上午手动排查看到、但 PRD 规则里没有的：`~/.cache/codex-runtimes` 2.2 GB、`~/Library/Caches` 下各应用缓存（Google 1.9 GB、DoubaoWork 1.3 GB、两个自动更新缓存约 1.8 GB），要不要加规则等用户定；⑥ GitHub 远端仍未建。
- 本轮新坑：L-01、L-02。

## 项目起步：铺协作骨架（2026-11-05，Claude，用户同意铺骨架；已提交（首次提交）、无需发布）

- 时间：开工 `2026-11-05 11:18`（`date '+%F %H:%M'` 记录）。来由：用「项目起步」（agent-kit 的 `skills/project-starter`）铺协作骨架。
- 改了哪些文件：新建 `AGENTS.md`（入口与导航表）、`CURRENT.md`（本文件）、`docs/LESSONS.md`（坑的写法与三级升级）、`docs/OPERATIONS.md`（交接写法、报告与验收）、`docs/templates/handoff.md`（交接骨架）、`tests/handoff-format.test.mjs`（交接格式测试）、`scripts/check-rules.mjs` 与 `tests/check-rules.test.mjs`（通用规则检查及自测）；已有文件未改。
- 测试：`node --test tests/*.test.mjs` 原样结果 「ℹ tests 4 ℹ pass 4 ℹ fail 0」；`node scripts/check-rules.mjs` 输出 「通用规则检查通过」。
- 验证：只铺文档与测试，无界面。
- 截图：无。
- 发布与回读：无需发布。
- 与授权不一致之处、遗留问题、范围外发现：① GitHub 远端未建，用户同意后再建私有仓库 `Natsukashii1997/disk-slim` 并建 5 个分流标签；② `scripts/check-rules.mjs` 在 `SCAN` 里加了 `Sources`（保留 `src`、`server`，自测要用）、把 `.swift` 加进扫描范围，其中的时间规则正则仍按 JS 写法，对 Swift 基本不起作用，第 1 批写出 Swift 代码后再看要不要补 Swift 版规则；③ AGENTS.md 删了「本机服务只监听 127.0.0.1」（本项目没有服务），依赖规则改成「先在交接里说明理由」，新增「安全底线」一条；④ 新建 `docs/PRD.md`（需求、调研、规则、分批计划）和 `docs/design/ui-v1.html`（三版界面预览）；⑤ 未登记进 `digital-twin/projects.json`，那是另一个项目，需要的话用户点名再加。
- 本轮新坑：无。
