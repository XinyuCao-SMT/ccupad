//
//  publish.mjs
//  CCUPad
//
//  一条命令走完：推代码 → 触发云端编译 → 等结果 → 下载并解压出未签名 IPA。
//
//  用法（仓库根目录）：
//      set GH_TOKEN=<有 repo 权限的 token>
//      node tools/publish.mjs                               # 用默认仓库
//      node tools/publish.mjs 用户名/ccupad --create         # 仓库不存在就建
//      node tools/publish.mjs 用户名/ccupad --push-only      # 只推不编译
//
//  产物：dist/CCUPad-unsigned.ipa
//
//  为什么又写一个 Node 脚本而不是 .ps1：
//    中文内容写成 .ps1 时，Windows PowerShell 5.1 会按 ANSI 读没有 BOM 的文件，
//    中文注释会变成乱码甚至语法错误（ccu-studio 那边踩过）。
//    Node 永远按 UTF-8 读源码，没有这个坑。
//

import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_DIR = path.join(HERE, '..');

const args = process.argv.slice(2);
const hasFlag = (name) => args.includes(name);
const positional = args.filter((a) => !a.startsWith('--'));
const SLUG = positional[0] ?? 'XinyuCao-SMT/ccupad';
const [OWNER, REPO] = SLUG.split('/');
const TOKEN = process.env.GH_TOKEN;
const WORKFLOW_FILE = 'build-ipa.yml';
const BRANCH = 'main';
const ARTIFACT_NAME = 'CCUPad-unsigned-ipa';

if (!TOKEN) {
  console.error('GH_TOKEN 没有设置。');
  console.error('  GitHub → Settings → Developer settings → Personal access tokens');
  console.error('  → Tokens (classic) → Generate new token → 勾 repo → 复制');
  console.error('  然后：set GH_TOKEN=ghp_xxx');
  process.exit(2);
}
if (!OWNER || !REPO) {
  console.error(`仓库名写得不对：${SLUG}（应为 owner/repo）`);
  process.exit(2);
}

const api = async (method, apiPath, body, raw = false) => {
  const res = await fetch(`https://api.github.com${apiPath}`, {
    method,
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      Accept: raw ? 'application/vnd.github+json' : 'application/vnd.github+json',
      'User-Agent': 'ccupad-publish',
      'Content-Type': 'application/json',
    },
    redirect: 'manual',
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (res.status === 302 || res.status === 301) {
    return { redirect: res.headers.get('location') };
  }
  const text = await res.text();
  if (!res.ok) {
    const error = new Error(`${method} ${apiPath} -> ${res.status} ${text.slice(0, 300)}`);
    error.status = res.status;
    throw error;
  }
  return text ? JSON.parse(text) : null;
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------- 1. 推代码
console.log('══ 1/4 推代码 ══');
if (hasFlag('--no-push')) {
  // 已经用 git push 推过了（github.com 间歇可达时这条路更稳），直接进编译阶段
  console.log('  --no-push：跳过推送');
} else {
  const pushArgs = [path.join(HERE, 'push-via-api.mjs'), SLUG];
  if (hasFlag('--create')) pushArgs.push('--create');
  const push = spawnSync(process.execPath, pushArgs, { cwd: REPO_DIR, stdio: 'inherit' });
  if (push.status !== 0) {
    console.error('推送失败，后面的步骤不再继续。');
    console.error('提示：若远端是刚建好的空仓库，Git Data API 会返回 409 —— 这时先用 git push 推一次，');
    console.error('      再跑 node tools/publish.mjs <owner/repo> --no-push。');
    process.exit(push.status ?? 1);
  }
}

if (hasFlag('--push-only')) {
  console.log('\n--push-only：跳过编译。');
  process.exit(0);
}

// ---------------------------------------------------------------- 2. 等这次提交的构建
console.log('\n══ 2/4 等云端编译 ══');

const headSha = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: REPO_DIR, encoding: 'utf8' }).trim();
console.log(`  本地提交 ${headSha.slice(0, 7)}`);

/** 找 head_sha 等于这次提交的运行（push 会自己触发，所以先等一下）。 */
async function findRun(sha) {
  try {
    const runs = await api('GET', `/repos/${OWNER}/${REPO}/actions/runs?branch=${BRANCH}&per_page=10`);
    return (runs?.workflow_runs ?? []).find((r) => r.head_sha === sha) ?? null;
  } catch (e) {
    if (e.status === 404) return null;
    throw e;
  }
}

let run = null;
const pushDeadline = Date.now() + 45000;
while (Date.now() < pushDeadline && !run) {
  await sleep(5000);
  run = await findRun(headSha);
}

if (!run) {
  // 这次提交没有命中工作流的 paths（例如只改了文档），手动触发一次
  console.log('  push 没有触发构建（可能只改了文档），手动触发…');
  try {
    await api('POST', `/repos/${OWNER}/${REPO}/actions/workflows/${WORKFLOW_FILE}/dispatches`, {
      ref: BRANCH,
    });
  } catch (e) {
    if (e.status === 404) {
      console.error(`  找不到工作流 ${WORKFLOW_FILE}。确认代码已推上去，且默认分支是 ${BRANCH}。`);
    } else if (e.status === 403) {
      console.error('  token 权限不足（触发工作流需要 repo 权限）。');
    }
    throw e;
  }

  const dispatchDeadline = Date.now() + 60000;
  while (Date.now() < dispatchDeadline && !run) {
    await sleep(5000);
    run = await findRun(headSha);
  }
}

if (!run) {
  console.error('  没能定位到构建运行。到仓库 Actions 页面看一眼。');
  process.exit(1);
}

// ---------------------------------------------------------------- 3. 等结果
console.log('\n══ 3/4 等编译（通常 4–6 分钟）══');
const deadline = Date.now() + 20 * 60 * 1000;

while (Date.now() < deadline) {
  let current;
  try {
    current = await api('GET', `/repos/${OWNER}/${REPO}/actions/runs/${run.id}`);
  } catch {
    await sleep(15000);
    continue;
  }
  run = current;
  process.stdout.write(
    `\r  ${run.name ?? 'run'} #${run.run_number}  状态 ${run.status}` +
      `${run.conclusion ? ' / ' + run.conclusion : ''}                    `
  );
  if (run.status === 'completed') break;
  await sleep(15000);
}
process.stdout.write('\n');

if (run.status !== 'completed') {
  console.error('  等超时了（20 分钟）。到仓库的 Actions 页面看这次运行：');
  console.error(`    ${run.html_url}`);
  process.exit(1);
}

if (run.conclusion !== 'success') {
  console.error(`\n  编译${run.conclusion === 'failure' ? '失败' : '未成功'}（${run.conclusion}）。`);
  console.error(`  打开这个页面看错误摘要：\n    ${run.html_url}`);
  console.error('  把 Summary 里的 error: 段落发回给我即可定位。');
  process.exit(1);
}

console.log(`  编译成功 ✓  ${run.html_url}`);

// ---------------------------------------------------------------- 4. 取 IPA
console.log('\n══ 4/4 下载并解压 IPA ══');
const artifacts = await api('GET', `/repos/${OWNER}/${REPO}/actions/runs/${run.id}/artifacts`);
const target = (artifacts?.artifacts ?? []).find((a) => a.name === ARTIFACT_NAME);
if (!target) {
  console.error(`  这次运行里没有名为 ${ARTIFACT_NAME} 的工件。`);
  console.error('  到运行页面手动下载即可。');
  process.exit(1);
}

const distDir = path.join(REPO_DIR, 'dist');
fs.mkdirSync(distDir, { recursive: true });
const zipPath = path.join(distDir, `${ARTIFACT_NAME}.zip`);

// 带认证请求会 302 到签名地址；手动跟一次跳转，第二跳不带 Authorization
// （签名 URL 不接受两个认证头，带着反而会被拒）。
const first = await api('GET', `/repos/${OWNER}/${REPO}/actions/artifacts/${target.id}/zip`, undefined, true);
const downloadUrl = first?.redirect;
if (!downloadUrl) {
  console.error('  没能拿到下载地址。到运行页面手动下载。');
  process.exit(1);
}
const zipRes = await fetch(downloadUrl, { redirect: 'follow' });
if (!zipRes.ok) {
  console.error(`  下载失败：HTTP ${zipRes.status}`);
  process.exit(1);
}
fs.writeFileSync(zipPath, Buffer.from(await zipRes.arrayBuffer()));
console.log(`  已下载 ${path.relative(REPO_DIR, zipPath)}（${(fs.statSync(zipPath).size / 1024).toFixed(0)} KB）`);

// 解压：用 PowerShell 的 Expand-Archive（Windows 自带），本脚本不引依赖
const extractDir = path.join(distDir, 'ipa');
fs.rmSync(extractDir, { recursive: true, force: true });
const expand = spawnSync(
  'powershell.exe',
  [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    `Expand-Archive -LiteralPath "${zipPath}" -DestinationPath "${extractDir}" -Force`,
  ],
  { stdio: 'inherit' }
);

let ipaPath = null;
if (expand.status === 0) {
  const found = fs.readdirSync(extractDir).filter((f) => f.toLowerCase().endsWith('.ipa'));
  if (found.length > 0) ipaPath = path.join(extractDir, found[0]);
}

console.log('\n══ 完成 ══');
if (ipaPath) {
  console.log(`  未签名 IPA：${ipaPath}`);
} else {
  console.log(`  压缩包已就绪：${zipPath}（解压后里面就是 .ipa）`);
}
console.log('\n下一步：用 Sideloadly 把这个 IPA 拖进去，Apple ID 填自己的，Start。');
console.log('iPadOS 16+ 还要去「设置 → 隐私与安全性」打开开发者模式并重启。');
console.log('装好后第一次连 CCU，记得允许「本地网络」权限。');
