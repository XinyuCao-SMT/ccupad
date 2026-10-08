// 校验资源目录（Assets.xcassets）里引用的图片是否真的存在、尺寸是否对。
//
// 为什么值得单独查：Contents.json 里漏写 filename **不会让编译失败** ——
// App 照样装得上，只是图标一片空白（这个坑真的踩过一次：AppIcon.appiconset
// 里只有一条 size=1024x1024 但没有 filename，于是桌面图标一直是默认的空白）。
// 这种事只有在真机上看桌面才会发现，所以挡在发版前。

import fs from 'node:fs';
import path from 'node:path';

const HERE = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
const ROOT = path.join(HERE, '..');
const ASSETS = path.join(ROOT, 'CCUPad', 'Resources', 'Assets.xcassets');

/** 从 PNG 头部读宽高（不依赖任何图像库）。 */
function pngSize(file) {
  const buf = fs.readFileSync(file);
  const isPng = buf.length > 24 && buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4E && buf[3] === 0x47;
  if (!isPng) return null;
  return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
}

function walk(dir, out = []) {
  if (!fs.existsSync(dir)) return out;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(p, out);
    else if (entry.name === 'Contents.json') out.push(p);
  }
  return out;
}

const problems = [];
let sets = 0;
let images = 0;

for (const file of walk(ASSETS)) {
  const dir = path.dirname(file);
  const rel = path.relative(ROOT, dir);
  if (!dir.endsWith('.appiconset') && !dir.endsWith('.imageset') && !dir.endsWith('.symbolset')) continue;
  sets += 1;

  let json;
  try {
    json = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (e) {
    problems.push(`${rel}: Contents.json 不是合法 JSON（${e.message}）`);
    continue;
  }

  const list = Array.isArray(json.images) ? json.images : [];
  if (list.length === 0) problems.push(`${rel}: images 是空的`);

  for (const entry of list) {
    const name = entry.filename;
    if (!name) {
      // AppIcon 允许「占位但没图」的写法，那正是空白图标的来源
      if (dir.endsWith('.appiconset')) {
        problems.push(`${rel}: 有一条 ${entry.size ?? '?'} 的图标没写 filename —— 装出来是空白图标`);
      }
      continue;
    }
    images += 1;
    const imgPath = path.join(dir, name);
    if (!fs.existsSync(imgPath)) {
      problems.push(`${rel}: 引用了不存在的文件 ${name}`);
      continue;
    }
    const size = pngSize(imgPath);
    if (!size) {
      problems.push(`${rel}: ${name} 不是 PNG`);
      continue;
    }
    // AppIcon 的 1024x1024 必须是正方形且够大；imageset 只要求同组同宽高比
    if (dir.endsWith('.appiconset') && entry.size) {
      const [w, h] = entry.size.split('x').map(Number);
      if (size.width !== w || size.height !== h) {
        problems.push(`${rel}: ${name} 声明 ${entry.size}，实际 ${size.width}x${size.height}`);
      }
    }
  }

  // AppIcon 必须真的有 1024 那一档
  if (dir.endsWith('.appiconset')) {
    const big = list.find((e) => e.size === '1024x1024');
    if (!big) problems.push(`${rel}: 没有 1024x1024 这一档`);
    else if (!big.filename) problems.push(`${rel}: 1024x1024 没有 filename`);
  }
}

console.log(`  资源集 ${sets} 个，图片 ${images} 个`);
if (problems.length > 0) {
  console.log(`  问题 ${problems.length} 处：`);
  for (const p of problems) console.log(`    ${p}`);
  process.exit(1);
}
console.log('  资源检查通过。');
