// 从 en.lproj/Localizable.strings 生成 zh-Hans.lproj/Localizable.strings（键=值）。
//
// 为什么不能省：App 如果只有 en 一个本地化，iOS 在「设备语言不受支持」时会回退到
// **开发区域**（默认 en）—— 结果就是中文 iPad 显示英文。
// 显式提供 zh-Hans 之后：中文设备走 zh-Hans、英文设备走 en，语言解析才是确定的；
// 顺带 iOS「设置 → 这个 App → 首选语言」里也会出现中文/English 两项。
//
// 生成而不是手写：两边键必须完全一致，手写迟早漂移。

import fs from 'node:fs';
import path from 'node:path';

const HERE = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
const RES = path.join(HERE, '..', 'CCUPad', 'Resources');
const EN = path.join(RES, 'en.lproj', 'Localizable.strings');
const ZH = path.join(RES, 'zh-Hans.lproj', 'Localizable.strings');

const raw = fs.readFileSync(EN, 'utf8');
const withoutComments = raw.replace(/\/\*[\s\S]*?\*\//g, (b) => b.replace(/[^\n]/g, ' '));

const entries = [];
for (const line of withoutComments.split('\n')) {
  const t = line.trim();
  if (!t) continue;
  const m = /^"((?:[^"\\]|\\.)*)"\s*=\s*"(?:[^"\\]|\\.)*";$/.exec(t);
  if (m) entries.push(m[1]);
}

if (entries.length === 0) {
  console.error('没有从 en.lproj 解析到任何条目 —— 先检查那个文件。');
  process.exit(1);
}

const header = [
  '/* CCUPad 中文界面（简体）。',
  '   键就是中文原文，值也是它自己 —— 这份文件存在的意义是**声明支持中文**：',
  '   只有 en 一个本地化时，iOS 会在设备语言不受支持时回退到开发区域（默认 en），',
  '   中文 iPad 就会显示英文。',
  '',
  '   本文件由 tools/make-zh-strings.mjs 从 en.lproj/Localizable.strings 生成，',
  '   两边键必须完全一致；不要手改这一份，改英文那份后重新生成。 */',
  '',
].join('\n');

const body = entries.map((k) => `"${k}" = "${k}";`).join('\n');
fs.mkdirSync(path.dirname(ZH), { recursive: true });
fs.writeFileSync(ZH, `${header}${body}\n`, 'utf8');

console.log(`已生成 ${path.relative(path.join(HERE, '..'), ZH)}：${entries.length} 条（键=值）`);
