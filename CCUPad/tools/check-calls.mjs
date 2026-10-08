//
//  check-calls.mjs
//  CCUPad
//
//  在没有 Swift 编译器的机器上，做一件编译器才会做的事：
//  核对「我们自己类型上的方法调用」是否真的存在，且**参数标签与声明一致**。
//
//  为什么要它：Swift 报错里最难一眼看出来的两类就是
//    - "value of type 'X' has no member 'y'"      （方法名写错 / 忘了声明）
//    - "missing argument label 'z:' in call"      （标签顺序或名字不对）
//  这两类错误在 Windows 上本来只能等 CI 编译才发现，这个脚本能提前全部抓出来。
//
//  只检查我们自己的类型，且只检查带括号的方法调用；
//  Foundation / SwiftUI 的类型一律跳过（那不是我们该管的）。
//
//  用法：node tools/check-calls.mjs
//

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(scriptDir, '..');
const sourcesAbs = path.join(rootDir, 'CCUPad');

function walk(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith('.')) continue;
    const abs = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (abs.endsWith('.xcassets')) continue;
      walk(abs, out);
    } else if (entry.name.endsWith('.swift')) {
      out.push(abs);
    }
  }
  return out;
}

/** 去掉注释与字符串内容，但保留换行 —— 行号才不会漂。 */
function stripNoise(text) {
  let out = '';
  let i = 0;
  let inLine = false;
  let inBlock = false;
  let inString = false;
  let inMultiline = false;
  let depth = 0;

  while (i < text.length) {
    const c = text[i];
    const next = text[i + 1];

    if (inLine) {
      if (c === '\n') { inLine = false; out += c; } else out += ' ';
      i += 1;
      continue;
    }
    if (inBlock) {
      if (c === '*' && next === '/') { inBlock = false; out += '  '; i += 2; continue; }
      out += c === '\n' ? '\n' : ' ';
      i += 1;
      continue;
    }
    if (inMultiline) {
      if (c === '"' && text.slice(i, i + 3) === '"""') { inMultiline = false; out += '   '; i += 3; continue; }
      out += c === '\n' ? '\n' : ' ';
      i += 1;
      continue;
    }
    if (inString) {
      if (c === '\\') { out += '  '; i += 2; continue; }
      if (c === '"') { inString = false; out += ' '; i += 1; continue; }
      // 插值里的东西也不参与解析
      out += c === '\n' ? '\n' : ' ';
      i += 1;
      continue;
    }
    if (c === '/' && next === '/') { inLine = true; out += '  '; i += 2; continue; }
    if (c === '/' && next === '*') { inBlock = true; out += '  '; i += 2; continue; }
    if (c === '"' && text.slice(i, i + 3) === '"""') { inMultiline = true; out += '0  '; i += 3; continue; }
    // 字符串字面量换成一个占位 token：内容不参与解析，但**实参的个数要保住**，
    // 否则 f("x") 会看起来像 f()，白白报一堆「少传参数」。
    if (c === '"') { inString = true; out += '0'; i += 1; continue; }

    if (c === '{') depth += 1;
    if (c === '}') depth -= 1;
    out += c;
    i += 1;
  }
  return { code: out, finalDepth: depth };
}

/** 从 `(` 开始，返回配平的括号内容与结束位置。 */
function balanced(code, openIndex, open = '(', close = ')') {
  let depth = 0;
  for (let i = openIndex; i < code.length; i += 1) {
    if (code[i] === open) depth += 1;
    else if (code[i] === close) {
      depth -= 1;
      if (depth === 0) return { inner: code.slice(openIndex + 1, i), end: i };
    }
  }
  return null;
}

/** 从 { 开始，返回配平的花括号内容与结束位置。 */
function balancedBraces(code, openIndex) {
  return balanced(code, openIndex, '{', '}');
}

/** 把参数列表切成顶层片段（忽略括号内的逗号）。
    注意：不跟踪 < > —— Swift 里 `a <= b` 这种比较运算符会让它们永远配不平。 */
function splitTopLevel(text) {
  const parts = [];
  let depth = 0;
  let current = '';
  for (const c of text) {
    if ('([{'.includes(c)) depth += 1;
    if (')]}'.includes(c)) depth -= 1;
    if (c === ',' && depth === 0) {
      parts.push(current);
      current = '';
      continue;
    }
    current += c;
  }
  if (current.trim() !== '') parts.push(current);
  return parts.map((p) => p.trim()).filter((p) => p !== '');
}

/** `)` 之后是否跟着尾随闭包。if / guard / while 后面那个 `{` 是语句体，不算闭包。 */
function detectTrailingClosure(code, closeParenIndex, receiverIndex) {
  let after = closeParenIndex + 1;
  while (after < code.length && /\s/.test(code[after])) after += 1;
  if (code[after] !== '{') return false;

  let start = receiverIndex;
  while (start > 0 && !'\n{};'.includes(code[start - 1])) start -= 1;
  const head = code.slice(start, receiverIndex);
  if (/^\s*(if|guard|while|switch|for|else)\b/.test(head)) return false;
  if (/^\s*\}?\s*(if|guard|while|switch|for)\b/.test(head)) return false;
  return true;
}

/** 声明里的外部参数标签：`_ id: UUID` -> _，`force: Bool = true` -> force */
function declarationLabels(params) {
  const segments = splitTopLevel(params);
  const labels = [];
  for (const segment of segments) {
    // 去掉属性包装 / 注解
    const cleaned = segment.replace(/@\w+(\([^)]*\))?\s*/g, '').trim();
    const colonMatch = /^([A-Za-z_]\w*|_)\s*([A-Za-z_]\w*)?\s*:/.exec(cleaned);
    if (!colonMatch) continue;
    const external = colonMatch[1];
    const hasDefault = /=\s*[^=]/.test(cleaned.slice(colonMatch[0].length)) || /=$/.test(cleaned);
    labels.push({ label: external === '_' ? null : external, hasDefault, raw: cleaned });
  }
  return labels;
}

/** 把「带默认值」判定放宽一点：整段里出现 = 就算有默认值。 */
function segmentHasDefault(segment) {
  return /\s=\s/.test(segment) || /=\s*\S/.test(segment.replace(/^[^=]*:/, ':'));
}

// ------------------------------------------------------------------ 收集声明
const files = walk(sourcesAbs);
const parsed = files.map((abs) => ({
  abs,
  rel: path.relative(rootDir, abs),
  raw: fs.readFileSync(abs, 'utf8'),
}));
parsed.forEach((f) => { f.code = stripNoise(f.raw).code; });

/** type -> Map(member -> { kind, labels }) */
const types = new Map();
/** type -> Set(它声明遵循的协议名，只记我们自己定义的协议) */
const conformances = new Map();
/** protocol -> Map(member -> { kind, labels }) */
const protocolRequirements = new Map();

function addMember(typeName, member, info) {
  if (!types.has(typeName)) types.set(typeName, new Map());
  const members = types.get(typeName);
  const existing = members.get(member);
  if (!existing) {
    members.set(member, info);
    return;
  }
  // 同名重载：合并标签集合，避免误报
  if (info.kind === 'func' && existing.kind === 'func') {
    existing.overloads = existing.overloads ?? [existing.labels];
    existing.overloads.push(info.labels);
  }
}

const typeDecl = /\b(struct|class|enum|actor|protocol|extension)\s+([A-Z][A-Za-z0-9_]*)([^{]*)\{/g;

for (const file of parsed) {
  const code = file.code;
  typeDecl.lastIndex = 0;
  let m;
  while ((m = typeDecl.exec(code)) !== null) {
    const keyword = m[1];
    const typeName = m[2];
    const headerRest = m[3] ?? '';
    const braceIndex = code.indexOf('{', m.index + m[0].length - 1);
    const body = balancedBraces(code, braceIndex);
    if (!body) continue;

    // 记录类型存在（即使没有成员）
    if (!types.has(typeName)) types.set(typeName, new Map());

    // 遵循的协议（只关心我们自己定义的那些）
    const colon = headerRest.indexOf(':');
    if (colon >= 0) {
      const listed = headerRest
        .slice(colon + 1)
        .split(',')
        .map((s) => s.trim().replace(/<.*$/, '').trim())
        .filter((s) => /^[A-Z][A-Za-z0-9_]*$/.test(s));
      if (listed.length > 0) {
        if (!conformances.has(typeName)) conformances.set(typeName, new Set());
        for (const name of listed) conformances.get(typeName).add(name);
      }
    }

    const bodyText = body.inner;
    const isProtocol = keyword === 'protocol';

    // func 成员
    const funcRe = /\bfunc\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\s*\(/g;
    let fm;
    while ((fm = funcRe.exec(bodyText)) !== null) {
      const parenIndex = bodyText.indexOf('(', fm.index + fm[0].length - 1);
      const params = balanced(bodyText, parenIndex);
      if (!params) continue;
      const segments = splitTopLevel(params.inner);
      const labels = segments.map((segment) => {
        const cleaned = segment.replace(/@\w+(\([^)]*\))?\s*/g, '').trim();
        const colonMatch = /^([A-Za-z_]\w*)\s*:/.exec(cleaned);
        const twoNames = /^([A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*:/.exec(cleaned);
        let label = null;
        if (twoNames) label = twoNames[1];
        else if (colonMatch) label = colonMatch[1];
        if (label === '_') label = null;
        const rest = cleaned.slice(cleaned.indexOf(':') + 1);
        return { label, hasDefault: /(^|[^=<>!])=([^=]|$)/.test(rest) };
      });
      addMember(typeName, fm[1], { kind: 'func', labels, file: file.rel });
      if (isProtocol) {
        if (!protocolRequirements.has(typeName)) protocolRequirements.set(typeName, new Map());
        protocolRequirements.get(typeName).set(fm[1], { kind: 'func', labels });
      }
    }

    // 属性成员
    const propRe = /\b(?:var|let)\s+([A-Za-z_]\w*)/g;
    let pm;
    while ((pm = propRe.exec(bodyText)) !== null) {
      addMember(typeName, pm[1], { kind: 'prop', labels: [], file: file.rel });
      if (isProtocol) {
        if (!protocolRequirements.has(typeName)) protocolRequirements.set(typeName, new Map());
        if (!protocolRequirements.get(typeName).has(pm[1])) {
          protocolRequirements.get(typeName).set(pm[1], { kind: 'prop', labels: [] });
        }
      }
    }

    // 枚举 case
    const caseRe = /\bcase\s+([A-Za-z_]\w*)/g;
    let cm;
    while ((cm = caseRe.exec(bodyText)) !== null) {
      addMember(typeName, cm[1], { kind: 'case', labels: [], file: file.rel });
    }
  }
}

// ------------------------------------------------------------------ 值接收者 -> 类型
const RECEIVER_TYPES = {
  manager: 'CCUManager',
  session: 'CCUSession',
  ws: 'WebSocketClient',
  channel: 'GainChannel',
  binding: 'GainBinding',
  item: 'CCUItem',
  map: 'ParameterMap',
  state: 'CCUDeviceState',
  device: 'CCUDevice',
  response: 'HTTPResponse',
  challenge: 'DigestChallenge',
  ticket: 'CCUManager',
};

const SKIP_RECEIVERS = new Set([
  'self', 'super', 'String', 'Data', 'Date', 'UUID', 'Int', 'Double', 'Float', 'Bool',
  'Array', 'Dictionary', 'Set', 'JSONEncoder', 'JSONDecoder', 'UserDefaults', 'FileManager',
  'DispatchQueue', 'Timer', 'Color', 'Text', 'Image', 'URL', 'Bundle', 'CharacterSet',
  'NotificationCenter', 'SecItemAdd', 'SecItemCopyMatching', 'SecItemDelete',
]);

const problems = [];

function lineOf(code, index) {
  return code.slice(0, index).split('\n').length;
}

for (const file of parsed) {
  const code = file.code;

  // 我们自己的类型 + 值接收者
  const receivers = new Set(Object.keys(RECEIVER_TYPES));
  for (const name of types.keys()) receivers.add(name);

  for (const receiver of receivers) {
    if (SKIP_RECEIVERS.has(receiver)) continue;
    const typeName = RECEIVER_TYPES[receiver] ?? receiver;
    const members = types.get(typeName);
    if (!members) continue;

    const callRe = new RegExp(`\\b${receiver}\\s*\\.\\s*([A-Za-z_]\\w*)\\s*\\(`, 'g');
    let m;
    while ((m = callRe.exec(code)) !== null) {
      const member = m[1];
      const parenIndex = code.indexOf('(', m.index + m[0].length - 1);
      const params = balanced(code, parenIndex);
      if (!params) continue;

      const declared = members.get(member);
      if (!declared) {
        problems.push({
          rel: file.rel,
          line: lineOf(code, m.index),
          text: code.split('\n')[lineOf(code, m.index) - 1].trim(),
          issue: `类型 ${typeName} 上没有成员 '${member}'`,
        });
        continue;
      }
      if (declared.kind !== 'func') {
        // 枚举 case 带关联值时也是「用括号构造」，那是合法的
        if (declared.kind === 'case') continue;
        problems.push({
          rel: file.rel,
          line: lineOf(code, m.index),
          text: code.split('\n')[lineOf(code, m.index) - 1].trim(),
          issue: `'${receiver}.${member}' 声明成了 ${declared.kind}，不是方法`,
        });
        continue;
      }

      // 调用点标签
      const argSegments = splitTopLevel(params.inner);
      const callLabels = argSegments.map((segment) => {
        const twoNames = /^([A-Za-z_]\w*)\s*:/.exec(segment);
        return twoNames ? twoNames[1] : null; // null = 位置参数（闭包等）
      });

      // 是否有尾随闭包
      const hasTrailingClosure = detectTrailingClosure(code, params.end, m.index);

      const candidates = declared.overloads ?? [declared.labels];
      const matches = candidates.some((declLabels) => labelsCompatible(callLabels, declLabels, hasTrailingClosure, argSegments));

      if (!matches) {
        problems.push({
          rel: file.rel,
          line: lineOf(code, m.index),
          text: code.split('\n')[lineOf(code, m.index) - 1].trim(),
          issue: `标签不匹配：调用 [${callLabels.map((l) => l ?? '_').join(', ')}]${hasTrailingClosure ? ' + 尾随闭包' : ''}` +
                 ` / 声明 [${(declared.overloads ?? [declared.labels]).map((ls) => ls.map((l) => l.label ?? '_').join(', ')).join(' | ')}]`,
        });
      }
    }
  }
}

/** 调用标签必须是声明标签的子序列（保序），且没有漏掉「无默认值」的参数。 */
function labelsCompatible(callLabels, declLabels, hasTrailingClosure, argSegments) {
  let cursor = 0;
  const usedIndexes = [];
  for (const callLabel of callLabels) {
    let found = -1;
    for (let i = cursor; i < declLabels.length; i += 1) {
      if (declLabels[i].label === callLabel) { found = i; break; }
    }
    // 位置参数的标签是 null：声明里对应的位置参数（label 为 null）也认
    if (found < 0 && callLabel === null) {
      for (let i = cursor; i < declLabels.length; i += 1) {
        if (declLabels[i].label === null) { found = i; break; }
      }
    }
    if (found < 0) return false;
    usedIndexes.push(found);
    cursor = found + 1;
  }

  // 未提供的、且没有默认值的参数：只允许是末尾的闭包参数（尾随闭包写法）
  for (let i = 0; i < declLabels.length; i += 1) {
    if (usedIndexes.includes(i)) continue;
    if (declLabels[i].hasDefault) continue;
    if (hasTrailingClosure && i >= declLabels.length - 1) continue;
    return false;
  }
  return true;
}

// ------------------------------------------------------------------ 协议一致性
//
// 「type does not conform to protocol」是另一类常见编译错误：
// 方法名写错一个字母、参数标签少一个，编译器就会报它。
// 这里把「我们自己定义的协议」的要求逐个对照实现（外来的协议一律跳过）。
for (const [typeName, protocolNames] of conformances) {
  const members = types.get(typeName);
  if (!members) continue;

  for (const protocolName of protocolNames) {
    const requirements = protocolRequirements.get(protocolName);
    if (!requirements) continue;

    for (const [reqName, req] of requirements) {
      const declared = members.get(reqName);

      if (!declared) {
        problems.push({
          rel: '(协议一致性)',
          line: 0,
          text: `${typeName} : ${protocolName}`,
          issue: `缺成员 '${reqName}' —— ${typeName} 没有实现 ${protocolName} 的要求`,
        });
        continue;
      }

      if (req.kind !== 'func') continue;

      if (declared.kind !== 'func') {
        problems.push({
          rel: '(协议一致性)',
          line: 0,
          text: `${typeName} : ${protocolName}`,
          issue: `'${reqName}' 在协议里是方法，在 ${typeName} 里却是 ${declared.kind}`,
        });
        continue;
      }

      const implLabelSets = (declared.overloads ?? [declared.labels]).map((ls) => ls.map((l) => l.label));
      const wanted = req.labels.map((l) => l.label);
      const matched = implLabelSets.some((labels) => wanted.every((w) => labels.includes(w)));
      if (!matched) {
        problems.push({
          rel: '(协议一致性)',
          line: 0,
          text: `${typeName} : ${protocolName}`,
          issue: `'${reqName}' 参数标签不匹配：协议 [${wanted.map((l) => l ?? '_').join(', ')}] / 实现 [${implLabelSets
            .map((ls) => ls.map((l) => l ?? '_').join(', '))
            .join(' | ')}]`,
        });
      }
    }
  }
}

// ------------------------------------------------------------------ 汇总
console.log(`解析 ${files.length} 个 Swift 文件，识别到 ${types.size} 个类型。`);
console.log(
  `其中自有协议 ${protocolRequirements.size} 个、被遵循的协议关系 ${[...conformances.values()].reduce((n, s) => n + s.size, 0)} 条。`
);
if (problems.length === 0) {
  console.log('调用点检查通过：方法都存在，参数标签与声明一致。');
  process.exit(0);
}

console.log(`\n发现 ${problems.length} 个可疑调用点：\n`);
for (const p of problems) {
  console.log(`  [${p.rel}:${p.line}] ${p.issue}`);
  console.log(`      ${p.text}`);
}
process.exit(1);
