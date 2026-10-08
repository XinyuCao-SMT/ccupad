//
//  fetch-run-errors.mjs
//  CCUPad
//
//  把某次 GitHub Actions 运行的**编译错误**抓下来并去重打印。
//
//  为什么需要它：第一次云编译几乎不可能一次过（Windows 上没法编译 Swift）。
//  有了这个脚本，失败时不用人工去网页翻日志 —— 直接把它抓出来，
//  按文件归组，一眼能看出要改哪几处。
//
//  用法：
//      set GH_TOKEN=...
//      node tools/fetch-run-errors.mjs                      # 取本仓库最近一次运行
//      node tools/fetch-run-errors.mjs 1234567890            # 指定 run id
//      node tools/fetch-run-errors.mjs 1234567890 owner/repo
//

const TOKEN = process.env.GH_TOKEN;
const SLUG = process.argv[3] ?? 'XinyuCao-SMT/ccupad';
const [OWNER, REPO] = SLUG.split('/');

if (!TOKEN) {
  console.error('GH_TOKEN 没有设置。');
  process.exit(2);
}

const api = async (method, apiPath) => {
  const res = await fetch(`https://api.github.com${apiPath}`, {
    method,
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'ccupad-errors',
    },
    redirect: 'manual',
  });
  if (res.status === 301 || res.status === 302) {
    return { redirect: res.headers.get('location') };
  }
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${apiPath} -> ${res.status} ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : null;
};

/** 作业日志是纯文本，且会 302 到签名地址（第二跳不能带 Authorization）。 */
async function fetchJobLog(jobId) {
  const first = await api('GET', `/repos/${OWNER}/${REPO}/actions/jobs/${jobId}/logs`);
  const url = first?.redirect;
  if (!url) return '';
  const res = await fetch(url, { redirect: 'follow' });
  if (!res.ok) return '';
  return await res.text();
}

let runId = process.argv[2];
if (!runId || !/^\d+$/.test(runId)) {
  const runs = await api('GET', `/repos/${OWNER}/${REPO}/actions/runs?per_page=1`);
  const latest = runs?.workflow_runs?.[0];
  if (!latest) {
    console.error('仓库里还没有任何运行。');
    process.exit(1);
  }
  runId = String(latest.id);
  console.log(`最近一次运行：#${latest.run_number}  ${latest.status}/${latest.conclusion ?? '-'}  ${latest.html_url}`);
}

const jobs = await api('GET', `/repos/${OWNER}/${REPO}/actions/runs/${runId}/jobs`);
if (!jobs?.jobs?.length) {
  console.error('这次运行里没有作业。');
  process.exit(1);
}

const patterns = [
  /error:\s*.+/,
  /fatal error:\s*.+/,
  /does not conform to protocol.+/,
  /cannot find '.+' in scope/,
  /value of type '.+' has no member/,
  /missing argument label/,
  /ambiguous use of/,
  /cannot convert value of type/,
  /no such module/,
];

const found = new Map();      // 去掉行号后的内容 -> 原始行
let scanned = 0;

for (const job of jobs.jobs) {
  console.log(`\n══ 作业 ${job.name}  ${job.status}/${job.conclusion ?? '-'} ══`);
  const log = await fetchJobLog(job.id);
  if (!log) {
    console.log('  （取不到日志）');
    continue;
  }
  scanned += 1;

  for (const line of log.split('\n')) {
    const text = line.replace(/\u001b\[[0-9;]*m/g, '').trim();
    if (!patterns.some((re) => re.test(text))) continue;
    // 同一处错误会出现在多行里，按「去掉行号」的内容去重
    const key = text.replace(/:\d+:\d+:/, ':').slice(0, 400);
    if (!found.has(key)) found.set(key, text.slice(0, 500));
  }
}

console.log(`\n══ 去重后的编译错误（扫了 ${scanned} 个作业的日志）══`);
if (found.size === 0) {
  console.log('  没有匹配到编译错误 —— 若这次确实失败了，可能是打包/上传阶段的问题，看运行页面。');
  process.exit(0);
}

for (const line of found.values()) console.log('  ' + line);
console.log(`\n共 ${found.size} 条。`);
