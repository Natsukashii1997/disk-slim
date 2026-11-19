import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { checkRules } from '../scripts/check-rules.mjs';

test('仓库符合通用规则（scripts/check-rules.mjs）', () => {
  assert.deepEqual(checkRules(process.cwd()), []);
});

test('通用规则能抓到违规样本，合规样本不误报', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'check-rules-'));
  const write = (file, text) => {
    fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
    fs.writeFileSync(path.join(root, file), text);
  };
  try {
    write('src/a.js', 'show(item.createdAt.slice(0, 16));\nshow(beijingTime(item.createdAt));\nshow(item.updatedAt.slice(11, 16)); // 北京时间\n');
    write('server/index.mjs', "server.listen(port);\nserver.listen(port, '127.0.0.1');\n");
    write('package.json', JSON.stringify({ dependencies: { 'left-pad': '1.0.0' } }, null, 2));
    assert.deepEqual(checkRules(root).map(v => `${v.file}:${v.line} ${v.kind}`), ['src/a.js:1 time', 'server/index.mjs:1 listen', 'package.json:3 deps']);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('LESSONS 每条要有以层级词开头的「升级」行：缺行和不带层级词都报错，合规条目和格式样例不误报', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'check-rules-'));
  // L-03 摘自本项目 docs/LESSONS.md 补层级词之前（b742c26）的真实升级行；L-15 缺升级行是构造样本（本项目历史上没有缺行的条目）
  // L-18：标题反引号里的 <…> 是真实内容，不能当格式样例跳过（骨架原写法漏报；剪藏插件 L-02 标题里的 `<all_urls>` 是真实例子）
  const lessons = [
    '# 开发实录与坑', '', '## 怎么写', '', '---', '',
    '## L-03 macOS 不区分大小写：只差大小写的目录、目标、可执行文件会撞在一起（2026-11-05）', '', '- 现象：略。',
    '- 升级：同类第 2 次，已写进 AGENTS.md「规则」。换个项目也成立，提议提升为全局 G-xx（待用户批准）。', '',
    '## L-15 构造样本：没有升级行（2026-11-19）', '', '- 现象：略。', '- 正确做法：略。', '',
    '## L-18 构造样本：标题反引号里带 `<占位>` 的真实条目没有升级行（2026-11-19）', '', '- 现象：略。', '',
    '## L-16 合规：未升级的也要带层级词（2026-11-19）', '', '- 现象：略。', '- 升级：〔提醒〕未升级（待批：积压清单组 16）。', '',
    '## L-17 合规：已升级写明去处（2026-11-19）', '', '- 现象：略。', '- 升级：〔文字〕已升级：AGENTS.md「规则」。', '',
    '---', '', '格式：', '', '```markdown', '## L-01 <一句话现象>（<YYYY-MM-DD>）', '', '- 升级：未升级。', '```', '',
  ].join('\n');
  try {
    fs.mkdirSync(path.join(root, 'docs'));
    fs.writeFileSync(path.join(root, 'docs/LESSONS.md'), lessons);
    assert.deepEqual(checkRules(root).map(v => `${v.file}:${v.line} ${v.kind} ${v.text}`), [
      'docs/LESSONS.md:10 lessons L-03 的「升级」没以层级词开头：- 升级：同类第 2 次，已写进 AGENTS.md「规则」。换个项目也成立，提议提升为全局 G-xx（待用户批准）。',
      'docs/LESSONS.md:12 lessons L-15 缺「- 升级：」一行',
      'docs/LESSONS.md:17 lessons L-18 缺「- 升级：」一行',
    ]);
    assert.match(checkRules(root)[0].rule, /〔提醒〕未升级/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
