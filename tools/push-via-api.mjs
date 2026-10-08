//
//  push-via-api.mjs
//  CCUPad
//
//  用 GitHub REST API 推送本地提交（不依赖 git 传输）。
//
//  为什么需要它：有些网络下 github.com:443 连不通（连接被重置），
//  但 api.github.com:443 正常，于是 `git push` 直接失败。
//  这个脚本把提交逐个重放到远端，行为与 git push 等价（快进，不强制覆盖）。
//
//  用法（仓库根目录下执行）：
//      set GH_TOKEN=<有 repo 权限的 personal access token>
//      node tools/push-via-api.mjs                       # 推到默认仓库
//      node tools/push-via-api.mjs owner/repo            # 指定仓库
//      node tools/push-via-api.mjs owner/repo --create    # 仓库不存在就先建
//
//  仓库必须已存在（或用 --create 让脚本建）。
//  远端有本脚本不知道的提交时会停下来，不会覆盖。
//

import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_DIR = join(HERE, '..');

const args = process.argv.slice(2);
const hasFlag = (name) => args.includes(name);
const positional = args.filter((a) => !a.startsWith('--'));

const SLUG = positional[0] ?? 'XinyuCao-SMT/ccupad';
const [OWNER, REPO] = SLUG.split('/');
const TOKEN = process.env.GH_TOKEN;

if (!TOKEN) {
  console.error('GH_TOKEN 没有设置。先做一个有 repo 权限的 token，然后在当前窗口 set GH_TOKEN=...');
  process.exit(2);
}
if (!OWNER || !REPO) {
  console.error(`仓库名写得不对：${SLUG}（应为 owner/repo）`);
  process.exit(2);
}

const api = async (method, path, body) => {
  const res = await fetch(`https://api.github.com${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'ccupad-push',
      'Content-Type': 'application/json',
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) {
    const error = new Error(`${method} ${path} -> ${res.status} ${text.slice(0, 300)}`);
    error.status = res.status;
    throw error;
  }
  return text ? JSON.parse(text) : null;
};

const git = (...gitArgs) =>
  execFileSync('git', gitArgs, { cwd: REPO_DIR, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });

// ---------------------------------------------------------------- 仓库是否存在
try {
  await api('GET', `/repos/${OWNER}/${REPO}`);
  console.log(`仓库 ${SLUG} 已存在`);
} catch (e) {
  if (e.status !== 404) throw e;
  if (!hasFlag('--create')) {
    console.error(`仓库 ${SLUG} 不存在。要自动创建请加 --create：`);
    console.error(`  node tools/push-via-api.mjs ${SLUG} --create`);
    process.exit(1);
  }

  const payload = {
    name: REPO,
    description: 'CCUPad — iPad 上的索尼 CCU 音频增益 + Tally 面板（HTTP Digest + WebSocket + MessagePack，零依赖）',
    private: false,
    has_issues: true,
    has_wiki: false,
  };

  let created = null;
  // 先试组织，再退回个人账号
  try {
    created = await api('POST', `/orgs/${OWNER}/repos`, payload);
  } catch (e) {
    if (e.status !== 404 && e.status !== 403) throw e;
    created = await api('POST', '/user/repos', { ...payload, name: REPO });
  }
  console.log(`已创建仓库 ${created.full_name}`);
}

// ---------------------------------------------------------------- 本地状态
const branch = git('rev-parse', '--abbrev-ref', 'HEAD').trim();
const local = git('log', '--reverse', '--format=%H')
  .trim()
  .split('\n')
  .filter(Boolean)
  .map((sha) => ({
    sha,
    subject: git('log', '-1', '--format=%s', sha).trim(),
    message: git('log', '-1', '--format=%B', sha).replace(/\n+$/, '\n'),
    changed: git('diff-tree', '--no-commit-id', '--name-status', '-r', '--root', sha)
      .trim()
      .split('\n')
      .filter(Boolean)
      .map((line) => {
        const [status, ...rest] = line.split('\t');
        return { status, path: rest.join('\t') };
      }),
  }));

// ---------------------------------------------------------------- 远端状态
let remoteHead = null;
let remoteSubjects = [];
try {
  const commits = await api('GET', `/repos/${OWNER}/${REPO}/commits?sha=${branch}&per_page=100`);
  remoteSubjects = commits.map((c) => c.commit.message.split('\n')[0]).reverse();
  remoteHead = commits[0]?.sha ?? null;
} catch (e) {
  // 新建的空仓库：commits 接口返回 409 "Git Repository is empty"（不是 404）；
  // 有些情况下（分支不存在）才是 404。两种都当作「远端还是空的」。
  if (e.status !== 404 && e.status !== 409) throw e;
  console.log('远端分支还是空的');
}

// API 重放后 SHA 会变，所以按提交标题从历史的开头逐条对齐
let skip = 0;
while (skip < remoteSubjects.length && skip < local.length && local[skip].subject === remoteSubjects[skip]) {
  skip += 1;
}

let parentSha = remoteHead;
let parentTree = remoteHead
  ? (await api('GET', `/repos/${OWNER}/${REPO}/git/commits/${remoteHead}`)).tree.sha
  : null;

if (skip < remoteSubjects.length) {
  if (!hasFlag('--rewrite')) {
    console.error(`本地与远端在第 ${skip + 1} 条提交处开始不同：`);
    console.error(`  本地: ${local[skip]?.subject ?? '(无)'}`);
    console.error(`  远端: ${remoteSubjects[skip]}`);
    console.error('\n这通常是被 amend / 改写过标题。要覆盖远端请加 --rewrite。');
    process.exit(1);
  }
  const remoteCommits = await api('GET', `/repos/${OWNER}/${REPO}/commits?sha=${branch}&per_page=100`);
  const ordered = remoteCommits.map((c) => c.sha).reverse();
  const keep = Math.min(skip, ordered.length);
  parentSha = keep > 0 ? ordered[keep - 1] : null;
  parentTree = parentSha
    ? (await api('GET', `/repos/${OWNER}/${REPO}/git/commits/${parentSha}`)).tree.sha
    : null;
  console.log(`--rewrite：保留远端前 ${keep} 条，从第 ${keep + 1} 条起重放 ${local.length - keep} 条`);
}

console.log(`分支 ${branch}：本地 ${local.length} 条提交，远端已有 ${skip} 条 -> 重放 ${local.length - skip} 条`);
if (skip === local.length) {
  console.log('已经是最新的');
  process.exit(0);
}

// ---------------------------------------------------------------- 重放
for (const commit of local.slice(skip)) {
  const entries = [];

  for (const file of commit.changed) {
    if (file.status === 'D') {
      entries.push({ path: file.path, mode: '100644', type: 'blob', sha: null });
      continue;
    }
    let content;
    try {
      content = execFileSync('git', ['show', `${commit.sha}:${file.path}`], {
        cwd: REPO_DIR,
        maxBuffer: 64 * 1024 * 1024,
      });
    } catch {
      console.warn(`  跳过读不出的文件 ${file.path}`);
      continue;
    }
    const blob = await api('POST', `/repos/${OWNER}/${REPO}/git/blobs`, {
      content: content.toString('base64'),
      encoding: 'base64',
    });
    const mode = git('ls-tree', commit.sha, file.path).startsWith('100755') ? '100755' : '100644';
    entries.push({ path: file.path, mode, type: 'blob', sha: blob.sha });
  }

  const tree = await api('POST', `/repos/${OWNER}/${REPO}/git/trees`, {
    ...(parentTree ? { base_tree: parentTree } : {}),
    tree: entries,
  });

  const newCommit = await api('POST', `/repos/${OWNER}/${REPO}/git/commits`, {
    message: commit.message,
    tree: tree.sha,
    ...(parentSha ? { parents: [parentSha] } : {}),
  });

  console.log(`  ${newCommit.sha.slice(0, 7)}  ${commit.subject}`);
  parentSha = newCommit.sha;
  parentTree = tree.sha;
}

// ---------------------------------------------------------------- refs
if (remoteHead) {
  await api('PATCH', `/repos/${OWNER}/${REPO}/git/refs/heads/${branch}`, { sha: parentSha, force: true });
} else {
  await api('POST', `/repos/${OWNER}/${REPO}/git/refs`, { ref: `refs/heads/${branch}`, sha: parentSha });
}
console.log(`  ${branch} -> ${parentSha.slice(0, 7)}`);

// ---------------------------------------------------------------- tags
try {
  const localTags = git('tag', '-l').trim().split('\n').filter(Boolean);
  const remoteTags = new Set(
    ((await api('GET', `/repos/${OWNER}/${REPO}/git/refs/tags`)) ?? []).map((r) => r.ref.replace('refs/tags/', ''))
  );
  for (const tag of localTags) {
    if (remoteTags.has(tag)) continue;
    const target = local.find((c) => git('rev-list', '-n', '1', tag).trim() === c.sha);
    if (!target) continue;
    const index = local.indexOf(target);
    const replayed = (await api('GET', `/repos/${OWNER}/${REPO}/commits?sha=${branch}&per_page=100`))
      .map((c) => c.sha)
      .reverse()[index];
    if (!replayed) continue;
    const tagObject = await api('POST', `/repos/${OWNER}/${REPO}/git/tags`, {
      tag,
      message: git('tag', '-l', '-n99', tag).replace(/^[^\n]*\n\n?/, '').trim() || tag,
      object: replayed,
      type: 'commit',
    });
    await api('POST', `/repos/${OWNER}/${REPO}/git/refs`, { ref: `refs/tags/${tag}`, sha: tagObject.sha });
    console.log(`  tag ${tag} -> ${replayed.slice(0, 7)}`);
  }
} catch (e) {
  console.warn(`  标签同步跳过：${e.message}`);
}

console.log('\n完成');
