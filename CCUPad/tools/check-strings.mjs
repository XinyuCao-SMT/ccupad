// 校验 en.lproj/Localizable.strings：语法、重复键、格式符一致性。
//
// 为什么值得单独查：.strings 里写错（少个引号、键重复、键值格式符对不上）
// **不会让编译失败** —— 只会让界面在英文下悄悄退回中文，或显示成半截。
// 所以发版前在这里挡一道。
//
// 认多行 /* */ 注释（文件头就是多行的），否则会把注释内容当成坏行。

import fs from 'node:fs';
import path from 'node:path';

const HERE = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
const ROOT = path.join(HERE, '..');
const RES = path.join(ROOT, 'CCUPad', 'Resources');

function findStrings(dir, out = []) {
  if (!fs.existsSync(dir)) return out;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) findStrings(p, out);
    else if (entry.name.endsWith('.strings')) out.push(p);
  }
  return out;
}

const files = findStrings(RES);
if (files.length === 0) {
  console.log('没有找到任何 .strings 文件（英文界面还没做？）');
  process.exit(0);
}

let totalProblems = 0;
for (const file of files) {
  const rel = path.relative(ROOT, file);
  const raw = fs.readFileSync(file, 'utf8');
  // 先把注释整段抹成空白，行号保持不变
  const withoutComments = raw.replace(/\/\*[\s\S]*?\*\//g, (block) => block.replace(/[^\n]/g, ' '));
  const lines = withoutComments.split('\n');
  const rawLines = raw.split('\n');

  const bad = [];
  const keys = new Map();
  let count = 0;

  lines.forEach((line, i) => {
    const t = line.trim();
    if (!t) return;

    const m = /^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";$/.exec(t);
    if (!m) {
      bad.push(`第 ${i + 1} 行格式不对: ${rawLines[i].trim().slice(0, 100)}`);
      return;
    }
    count += 1;

    const key = m[1];
    const value = m[2];

    if (keys.has(key)) bad.push(`第 ${i + 1} 行重复键（上次在第 ${keys.get(key)} 行）: ${key}`);
    else keys.set(key, i + 1);

    const kn = (key.match(/%(@|lld|d|s|\.1f)/g) || []).length;
    const vn = (value.match(/%(@|lld|d|s|\.1f)/g) || []).length;
    if (kn !== vn) bad.push(`第 ${i + 1} 行格式符数量不一致（键 ${kn} / 值 ${vn}）: ${key}`);
  });

  console.log(`  ${rel}：${count} 条，问题 ${bad.length} 处`);
  for (const b of bad) console.log(`    ${b}`);
  totalProblems += bad.length;
}

if (totalProblems > 0) {
  console.log(`\n翻译文件有 ${totalProblems} 处问题 —— 英文界面会悄悄退回中文或显示不全。`);
  process.exit(1);
}
console.log('翻译文件检查通过。');
