#!/usr/bin/env node
// 从 CHANGELOG.md 里取出某个版本那一节，供 GitHub Release 的说明使用。
//
//   node scripts/changelog-section.mjs 0.3.0            # 打到 stdout
//   node scripts/changelog-section.mjs 0.3.0 notes.md   # 写到文件
//
// 为什么不用 GitHub 自动生成的 release notes 就完事：提交信息是写给维护者看的
// （"修 X 的回归"），发布说明是写给使用者看的（"你现在能做什么、装的时候要注意什么"），
// 两者受众不同。自动生成的内容仍然会作为补充附在后面（见 release.yml 的
// generate_release_notes）。
//
// 认得的标题形式（与 Keep a Changelog 一致）：
//   ## [0.3.0] — 2026-10-13
//   ## [0.3.0](https://…) (2026-10-13)
//   ## 0.3.0
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const version = (process.argv[2] || '').replace(/^v/, '');
const outPath = process.argv[3];

if (!version) {
  console.error('用法：node scripts/changelog-section.mjs <版本号> [输出文件]');
  process.exit(2);
}

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const changelogPath = join(root, 'CHANGELOG.md');

let text;
try {
  text = readFileSync(changelogPath, 'utf8');
} catch (err) {
  console.error(`读不到 ${changelogPath}：${err.message}`);
  process.exit(1);
}

const lines = text.split('\n');
// 标题里必须出现**同一行**的版本号，避免把正文里提到版本号的行当成标题
const isVersionHeading = (line, v) =>
  /^##\s/.test(line) && new RegExp(`(^|[^0-9.])${v.replace(/\./g, '\\.')}([^0-9.]|$)`).test(line);

let start = -1;
for (let i = 0; i < lines.length; i++) {
  if (isVersionHeading(lines[i], version)) { start = i; break; }
}

if (start === -1) {
  console.error(`CHANGELOG.md 里找不到 ${version} 那一节。`);
  console.error('可用的版本标题：');
  for (const line of lines) {
    if (/^##\s/.test(line)) console.error(`  ${line.trim()}`);
  }
  process.exit(1);
}

let end = lines.length;
for (let i = start + 1; i < lines.length; i++) {
  if (/^##\s/.test(lines[i])) { end = i; break; }
}

const section = lines.slice(start, end).join('\n').trim();
if (!section) {
  console.error(`${version} 那一节是空的。`);
  process.exit(1);
}

// 末尾那两行是给链接引用用的（[0.3.0]: https://…），发布说明里不需要
const body = section
  .split('\n')
  .filter((line) => !/^\[[^\]]+\]:\s*https?:\/\//.test(line))
  .join('\n')
  .replace(/\n{3,}/g, '\n\n')
  .trim();

if (outPath) {
  writeFileSync(outPath, body + '\n');
  console.log(`已写入 ${outPath}（${body.split('\n').length} 行）`);
} else {
  console.log(body);
}
