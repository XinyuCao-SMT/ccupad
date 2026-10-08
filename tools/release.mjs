//
//  release.mjs
//  CCUPad
//
//  发版：一个版本一个文件夹 + 独立清单 + 独立 tag（与 VideoScopePad 那套对齐，见 ROLLBACK.md）。
//
//  用法：
//      node tools/release.mjs --tag=v0.2.0-gain-tally --note="说明文字"
//      node tools/release.mjs --tag=v0.2.0-gain-tally --upload      # 顺便推 tag + 建 Release 挂 IPA
//      node tools/release.mjs --tag=... --commit=<被编译的提交> --no-tag
//      node tools/release.mjs --tag=... --from=dist/ipa/CCUPad-unsigned.ipa
//
//  为什么每版一个文件夹而不是覆盖 dist\ipa\CCUPad-unsigned.ipa：
//    回滚要能「拿起旧的那一个就装」，而不是重新编译一遍（重新编译出来的不一定等于当时那一份）。
//    文件夹里连清单一起留着，几个月后还能核对「手里这个 IPA 是不是当初那一版」。
//
//  与 Windows 版 release.ps1 的差别 —— iOS 产物没法跑功能性自检，所以改做**结构校验**：
//    解包 IPA，核对 arm64 / CFBundleShortVersionString 是否等于 tag / 本地网络权限键是否还在。
//    任何一条不过就**不发版**。
//
//  为什么用 Node 而不是 .ps1：中文内容写成 .ps1 时，Windows PowerShell 5.1 会按 ANSI 读没有 BOM
//  的文件，中文注释整段乱码甚至语法错误（release.ps1 顶部专门记了这条）。Node 永远按 UTF-8 读。
//

import { execFileSync, spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));   // CCUPad/tools
const REPO_DIR = path.join(HERE, '..');                      // CCUPad（git 仓库根）
const PROJECT_DIR = path.join(REPO_DIR, 'CCUPad');           // CCUPad/CCUPad（Xcode 工程目录）
const TOOLS_DIR = path.join(PROJECT_DIR, 'tools');           // 自检脚本所在（check-*.mjs）

const args = process.argv.slice(2);
const opt = {};
for (const a of args) {
  const m = /^--([a-z-]+)(?:=(.*))?$/.exec(a);
  if (m) opt[m[1]] = m[2] === undefined ? true : m[2];
}

const TAG = opt.tag;
const NOTE = typeof opt.note === 'string' ? opt.note : '';
const FROM = typeof opt.from === 'string' ? opt.from : path.join(REPO_DIR, 'dist', 'ipa', 'CCUPad-unsigned.ipa');
const BACKUP_DIR = typeof opt.backup === 'string' ? opt.backup : path.join(REPO_DIR, '..', '_backup');
const SLUG = typeof opt.repo === 'string' ? opt.repo : 'XinyuCao-SMT/ccupad';
const TOKEN = process.env.GH_TOKEN;

if (!TAG || TAG === true) {
  console.error('必须给 --tag=<版本标签>，例如 --tag=v0.2.0-gain-tally');
  process.exit(2);
}

const versionMatch = /(\d+\.\d+\.\d+)/.exec(TAG);
if (!versionMatch) {
  console.error(`标签里没有 x.y.z 版本号：${TAG}`);
  process.exit(2);
}
const VERSION = versionMatch[1];

const releaseDir = path.join(REPO_DIR, 'dist', TAG);
const ipaName = `CCUPad-${TAG}-unsigned.ipa`;
const ipaPath = path.join(releaseDir, ipaName);
const manifestPath = path.join(releaseDir, 'MANIFEST.txt');

const git = (...a) => execFileSync('git', a, { cwd: REPO_DIR, encoding: 'utf8' }).trim();

console.log(`发版：${TAG}`);

// ---------------------------------------------------------------- 1) 版本号一致性
const generatorPath = path.join(TOOLS_DIR, 'generate-xcodeproj.mjs');
const generatorText = fs.readFileSync(generatorPath, 'utf8');
const appVersionMatch = /const appVersion = '([^']+)'/.exec(generatorText);
const appVersion = appVersionMatch ? appVersionMatch[1] : null;

if (!appVersion) {
  console.error('读不到 generate-xcodeproj.mjs 里的 appVersion。');
  process.exit(1);
}
if (appVersion !== VERSION) {
  console.error(`版本号不一致，拒绝发版：`);
  console.error(`  tag 里的版本      : ${VERSION}`);
  console.error(`  工程里的 appVersion: ${appVersion}`);
  console.error(`  先把 tools/generate-xcodeproj.mjs 的 appVersion 改成 ${VERSION}，`);
  console.error(`  再跑 node tools/generate-xcodeproj.mjs 重新生成工程并重新编译。`);
  process.exit(1);
}
console.log(`  版本号一致：${VERSION}`);

// ---------------------------------------------------------------- 2) 自检（不过不发版）
if (!opt['skip-checks']) {
  for (const tool of ['check-sources.mjs', 'check-calls.mjs', 'check-strings.mjs']) {
    const file = path.join(TOOLS_DIR, tool);
    if (!fs.existsSync(file)) continue;
    const r = spawnSync(process.execPath, [file], { cwd: PROJECT_DIR, stdio: 'inherit' });
    if (r.status !== 0) {
      console.error(`\n自检未通过（${tool}）—— 不发出这一版。`);
      process.exit(1);
    }
  }
}

// ---------------------------------------------------------------- 3) 取 IPA 并归档
if (!fs.existsSync(FROM)) {
  console.error(`找不到 IPA：${FROM}`);
  console.error('先跑 node tools/publish.mjs 把云端编译的产物取回来。');
  process.exit(1);
}

fs.rmSync(releaseDir, { recursive: true, force: true });
fs.mkdirSync(releaseDir, { recursive: true });
fs.copyFileSync(FROM, ipaPath);

const size = fs.statSync(ipaPath).size;
const sha256 = crypto.createHash('sha256').update(fs.readFileSync(ipaPath)).digest('hex').toUpperCase();
console.log(`  IPA：${ipaName}（${(size / 1024).toFixed(0)} KB）`);
console.log(`  SHA256：${sha256}`);

// ---------------------------------------------------------------- 4) 结构校验 IPA
// 把 .ipa 拷成 .zip 再解（Expand-Archive 只认 .zip 后缀）
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ccupad-release-'));
const tmpZip = path.join(tmpDir, 'payload.zip');
const checkLines = [];
let checkFailed = null;

function check(label, ok, detail = '') {
  checkLines.push(`  ${ok ? '✓' : '✗'} ${label}${detail ? '  ' + detail : ''}`);
  if (!ok && !checkFailed) checkFailed = label;
}

try {
  fs.copyFileSync(ipaPath, tmpZip);
  const expand = spawnSync('powershell.exe', [
    '-NoProfile', '-NonInteractive', '-Command',
    `Expand-Archive -LiteralPath "${tmpZip}" -DestinationPath "${tmpDir}\\x" -Force`,
  ], { stdio: 'ignore' });
  if (expand.status !== 0) throw new Error('解包失败');

  const appDir = path.join(tmpDir, 'x', 'Payload', 'CCUPad.app');
  const binPath = path.join(appDir, 'CCUPad');
  const plistPath = path.join(appDir, 'Info.plist');

  check('Payload/CCUPad.app 存在', fs.existsSync(appDir));
  check('可执行文件存在', fs.existsSync(binPath));
  check('Info.plist 存在', fs.existsSync(plistPath));
  check('Assets.car 存在', fs.existsSync(path.join(appDir, 'Assets.car')));

  if (fs.existsSync(binPath)) {
    const head = fs.readFileSync(binPath).subarray(0, 8);
    const magic = head.subarray(0, 4).toString('hex').toUpperCase();
    const cpu = head.readUInt32LE(4);
    check('64 位 Mach-O', magic === 'CFFAEDFE', `magic=${magic}`);
    check('CPU = arm64', cpu === 0x0100000C, `cputype=0x${cpu.toString(16).toUpperCase().padStart(8, '0')}`);
    checkLines.push(`  · 主程序大小：${(fs.statSync(binPath).size / 1048576).toFixed(2)} MB`);
  }

  if (fs.existsSync(plistPath)) {
    const pb = fs.readFileSync(plistPath);
    const ascii = pb.toString('latin1');
    check('Info.plist 含 CFBundleShortVersionString', ascii.includes('CFBundleShortVersionString'));
    check(`Info.plist 版本号 = ${VERSION}`, ascii.includes(VERSION));
    check('含 NSLocalNetworkUsageDescription（连 CCU 的前提）', ascii.includes('NSLocalNetworkUsageDescription'));
  }
} catch (e) {
  check('解包 IPA', false, e.message);
} finally {
  fs.rmSync(tmpDir, { recursive: true, force: true });
}

console.log('  结构校验：');
for (const line of checkLines) console.log(line);
if (checkFailed) {
  fs.writeFileSync(path.join(releaseDir, 'VERIFY-FAILED.txt'),
    `IPA 结构校验未通过：${checkFailed}\n\n${checkLines.join('\n')}\n`, 'utf8');
  console.error(`\nIPA 结构校验未通过（${checkFailed}）—— 不发出这一版；结果留档：VERIFY-FAILED.txt`);
  process.exit(1);
}

// ---------------------------------------------------------------- 5) 清单
//
// tag 与源码归档都指向**被编译的那个提交**（--commit 指定），默认才是 HEAD。
// 这一点必须说清楚：如果发版之后又提交了文档，tag 指 HEAD 的话，
// 「checkout tag 拿到的源码」与「IPA 里的代码」就不是同一份了，回滚会失真。
const headCommit = git('rev-parse', 'HEAD');
const targetCommit = opt.commit ? git('rev-parse', String(opt.commit)) : headCommit;
const commit = targetCommit;
const commitShort = git('rev-parse', '--short', commit);
const dirty = git('status', '--porcelain').length > 0;

let ciUrl = '';
if (TOKEN) {
  try {
    const res = await fetch(`https://api.github.com/repos/${SLUG}/actions/runs?per_page=20`, {
      headers: { Authorization: `Bearer ${TOKEN}`, 'User-Agent': 'ccupad-release' },
    });
    if (res.ok) {
      const runs = await res.json();
      const match = (runs.workflow_runs ?? []).find((r) => r.conclusion === 'success');
      if (match) ciUrl = match.html_url;
    }
  } catch { /* 记不到就算了，不影响发版 */ }
}

const manifest = [];
manifest.push('CCUPad 发版清单');
manifest.push('======================================');
manifest.push('');
manifest.push(`版本号    : ${VERSION}`);
manifest.push(`发版标签  : ${TAG}`);
manifest.push(`文件名    : ${ipaName}`);
manifest.push(`大小      : ${size} 字节（${(size / 1024).toFixed(0)} KB）`);
manifest.push(`SHA256    : ${sha256}`);
manifest.push(`源码提交  : ${commit}${dirty ? '（工作区有未提交改动）' : ''}`);
if (headCommit !== commit) {
  manifest.push(`注意      : 发版时的 HEAD 是 ${headCommit.slice(0, 7)}（比被编译的提交多出文档/工具改动），`);
  manifest.push(`            tag 与源码归档都指向被编译的那一个（${commitShort}）。`);
}
manifest.push(`构建时间  : ${new Date().toLocaleString('zh-CN')}`);
manifest.push(`构建机    : ${os.hostname()}`);
if (ciUrl) manifest.push(`云编译运行: ${ciUrl}`);
manifest.push('');
manifest.push(`说明      : ${NOTE || '（未填写）'}`);
manifest.push('');
manifest.push('怎么用    : 用 Sideloadly 把 IPA 拖进去，Apple ID 填自己的，Start。');
manifest.push('            iPadOS 16+ 需先在「设置 → 隐私与安全性」打开开发者模式并重启；');
manifest.push('            免费 Apple ID 签名 7 天过期，过期后重新侧载同一个 IPA 即可（不必重新编译）。');
manifest.push('            首次连 CCU 时系统会问「本地网络」，必须允许 —— 拒绝过就只能去设置里手动打开。');
manifest.push('');
manifest.push('IPA 结构校验（iOS 产物没法跑功能性自检，改为核对包本身）：');
manifest.push(...checkLines);
manifest.push('');
manifest.push('回滚      : 见 ROLLBACK.md —— 装旧版 IPA / git checkout <tag> / 解压 _backup 里的源码归档');
manifest.push('');
fs.writeFileSync(manifestPath, manifest.join('\n'), 'utf8');
console.log(`  清单：${path.relative(REPO_DIR, manifestPath)}`);

// ---------------------------------------------------------------- 6) 源码归档（离线恢复用）
try {
  fs.mkdirSync(BACKUP_DIR, { recursive: true });
  const zipName = `src-ccupad-${TAG}-${commitShort}.zip`;
  const zipPath = path.join(BACKUP_DIR, zipName);
  execFileSync('git', ['archive', '--format=zip', '-o', zipPath, commit], { cwd: REPO_DIR, stdio: 'ignore' });
  const recordsPath = path.join(BACKUP_DIR, 'build-records.txt');
  const record = [
    `${new Date().toISOString()}  ${TAG}`,
    `  版本      ${VERSION}`,
    `  提交      ${commit}`,
    `  IPA       ${ipaPath}`,
    `  SHA256    ${sha256}`,
    `  大小      ${size}`,
    ciUrl ? `  云编译    ${ciUrl}` : null,
    `  源码归档  ${zipPath}`,
    '',
  ].filter(Boolean).join('\n');

  // 同一个 tag + 同一个 SHA 重复跑 release 时不重复记（--upload 常常是第二次跑）
  const existing = fs.existsSync(recordsPath) ? fs.readFileSync(recordsPath, 'utf8') : '';
  if (existing.includes(`${TAG}`) && existing.includes(sha256)) {
    console.log('  构建记录里已有这一版（同 tag 同 SHA），跳过追加');
  } else {
    fs.appendFileSync(recordsPath, record + '\n', 'utf8');
  }
  console.log(`  源码归档：${zipPath}`);
  console.log(`  构建记录：${recordsPath}`);
} catch (e) {
  console.warn(`  ⚠ 源码归档失败（不影响发版）：${e.message}`);
}

// ---------------------------------------------------------------- 7) 打 tag
if (!opt['no-tag']) {
  const existing = spawnSync('git', ['rev-parse', '--verify', '--quiet', `refs/tags/${TAG}`], { cwd: REPO_DIR });
  if (existing.status === 0) {
    console.log(`  ⚠ tag ${TAG} 已存在，跳过创建（要重打先 git tag -d ${TAG}）`);
  } else {
    const message = NOTE ? `${TAG}\n\n${NOTE}` : TAG;
    execFileSync('git', ['-c', 'user.name=ccupad-release', '-c', 'user.email=release@local',
      'tag', '-a', TAG, '-m', message, commit], { cwd: REPO_DIR });
    console.log(`  已打 tag：${TAG} → ${commitShort}`);
  }
}

// ---------------------------------------------------------------- 8) 推送 + Release
if (opt.upload) {
  if (!TOKEN) {
    console.error('  --upload 需要 GH_TOKEN（推送 tag 与上传 Release 附件都要它）。');
    process.exit(1);
  }

  // 上传这一段任何一步失败都要说清楚「哪一步失败、还剩什么没做、怎么补」，
  // 否则会出现「本地归档与 tag 都好了、Release 却没建」这种半个发版还不知道的状态。
  try {
    if (!opt['no-push']) {
    console.log('  推送提交与 tag（走 api.github.com）…');
    const push = spawnSync(process.execPath, [path.join(REPO_DIR, 'tools', 'push-via-api.mjs'), SLUG],
      { cwd: REPO_DIR, stdio: 'inherit' });
    if (push.status !== 0) {
      console.error('  推送失败，Release 上传跳过。');
      process.exit(1);
    }
  }

  const api = async (method, apiPath, body) => {
    const res = await fetch(`https://api.github.com${apiPath}`, {
      method,
      headers: {
        Authorization: `Bearer ${TOKEN}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'ccupad-release',
        'Content-Type': 'application/json',
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    if (!res.ok) throw new Error(`${method} ${apiPath} -> ${res.status} ${text.slice(0, 200)}`);
    return text ? JSON.parse(text) : null;
  };

  console.log('  创建 / 复用 GitHub Release（附件永久可下载，不受工件 30 天限制）…');
  let release = null;
  try {
    release = await api('GET', `/repos/${SLUG}/releases/tags/${TAG}`);
  } catch {
    release = await api('POST', `/repos/${SLUG}/releases`, {
      tag_name: TAG,
      name: `${TAG}（${VERSION}）`,
      body: [
        NOTE || `CCUPad ${VERSION}`,
        '',
        '安装：用 Sideloadly 拖入下面的 IPA，Apple ID 填自己的。',
        '首次连 CCU 记得允许「本地网络」权限。',
        '',
        `SHA256：${sha256}`,
      ].join('\n'),
      draft: false,
      prerelease: false,
    });
  }

  console.log(`  Release：${release.html_url}`);

  // 幂等：附件已经在就不重复传（重传同名附件 GitHub 会回 422 already_exists）
  const alreadyThere = (release.assets ?? []).find((a) => a.name === ipaName);
  if (alreadyThere) {
    console.log(`  附件已存在：${alreadyThere.name}（${Math.round(alreadyThere.size / 1024)} KB），跳过上传`);
  } else {
    const uploadUrl = `https://uploads.github.com/repos/${SLUG}/releases/${release.id}/assets?name=${encodeURIComponent(ipaName)}`;
    const bytes = fs.readFileSync(ipaPath);
    const up = await fetch(uploadUrl, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${TOKEN}`,
        'Content-Type': 'application/octet-stream',
        'User-Agent': 'ccupad-release',
      },
      body: bytes,
    });
    if (up.ok) {
      console.log(`  已挂上 IPA 附件：${ipaName}`);
    } else if (up.status === 422) {
      console.log('  附件已存在（HTTP 422 already_exists），跳过');
    } else {
      console.error(`  ⚠ 附件上传失败：HTTP ${up.status} ${(await up.text()).slice(0, 200)}`);
      console.error(`    可以到 ${release.html_url} 手动拖上去。`);
    }
  }
  } catch (e) {
    console.error('');
    console.error(`⚠ 上传阶段失败：${e.message}`);
    console.error('  本地归档、清单、tag 都已经做好（上面的输出里能看到），只有 GitHub 这一侧没完成。');
    console.error('  这条命令是幂等的，直接重跑同一句即可（缺哪步补哪步）：');
    console.error(`    node tools/release.mjs --tag=${TAG} --commit=${commit} --upload --no-tag`);
    process.exit(1);
  }
}

console.log('');
console.log(`完成：${releaseDir}`);
console.log('  • 旧版本文件夹都留在 dist/ 下，一个都没动 —— 回滚就是把它里面的 IPA 拿出来装');
console.log(`  • 清单：${manifestPath}`);
