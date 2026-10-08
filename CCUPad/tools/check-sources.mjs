//
//  check-sources.mjs
//  CCUPad
//
//  Windows 上没法编译 Swift，这个小脚本做几件廉价但有效的静态检查：
//    1) 去掉注释与字符串后，检查 () [] {} 是否配平
//    2) 检查是否有跨文件重名的类型（同名会编译成 "invalid redeclaration"）
//    3) 检查源文件是否都进了 Xcode 工程（漏了只会报一堆 "cannot find type"，白烧一轮 CI）
//    4) SwiftUI ViewBuilder 的 10 个子视图上限
//
//  用法：node tools/check-sources.mjs
//

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.resolve(scriptDir, '..');
const sourcesAbs = path.join(rootDir, 'CCUPad');
const projectName = 'CCUPad';

function walk(dir, out = []) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        if (entry.name.startsWith('.')) continue;
        const abs = path.join(dir, entry.name);
        if (entry.isDirectory()) {
            if (abs.endsWith('.xcassets')) continue;
            walk(abs, out);
        } else if (/\.(swift|metal)$/i.test(entry.name)) {
            out.push(abs);
        }
    }
    return out;
}

const files = walk(sourcesAbs);
let problems = 0;

function stripNoise(text) {
    let out = '';
    let i = 0;
    let inLineComment = false;
    let inBlockComment = false;
    let inString = false;
    let inMultilineString = false;

    while (i < text.length) {
        const c = text[i];
        const next = text[i + 1];

        if (inLineComment) {
            if (c === '\n') { inLineComment = false; out += c; }
            i += 1;
            continue;
        }
        if (inBlockComment) {
            if (c === '*' && next === '/') { inBlockComment = false; i += 2; continue; }
            i += 1;
            continue;
        }
        if (inMultilineString) {
            if (c === '"' && text.slice(i, i + 3) === '"""') { inMultilineString = false; i += 3; continue; }
            i += 1;
            continue;
        }
        if (inString) {
            if (c === '\\') { i += 2; continue; }
            if (c === '"') { inString = false; i += 1; continue; }
            i += 1;
            continue;
        }
        if (c === '/' && next === '/') { inLineComment = true; i += 2; continue; }
        if (c === '/' && next === '*') { inBlockComment = true; i += 2; continue; }
        if (c === '"' && text.slice(i, i + 3) === '"""') { inMultilineString = true; i += 3; continue; }
        if (c === '"') { inString = true; i += 1; continue; }

        out += c;
        i += 1;
    }
    return out;
}

const declarations = new Map(); // name -> [files]

for (const file of files) {
    const rel = path.relative(rootDir, file);
    const raw = fs.readFileSync(file, 'utf8');
    const code = stripNoise(raw);

    const stack = [];
    const pairs = { ')': '(', ']': '[', '}': '{' };
    const lineOf = (index) => code.slice(0, index).split('\n').length;

    for (let i = 0; i < code.length; i += 1) {
        const c = code[i];
        if (c === '(' || c === '[' || c === '{') {
            stack.push({ c, i });
        } else if (c === ')' || c === ']' || c === '}') {
            const top = stack.pop();
            if (!top || top.c !== pairs[c]) {
                console.log(`[配平] ${rel}:${lineOf(i)} 多余的 '${c}'（或与 '${top ? top.c : '空'}' 不匹配）`);
                problems += 1;
                break;
            }
        }
    }
    if (stack.length > 0) {
        const top = stack[stack.length - 1];
        console.log(`[配平] ${rel}:${lineOf(top.i)} 未闭合的 '${top.c}'（还剩 ${stack.length} 层）`);
        problems += 1;
    }

    // 顶层声明名收集（extension 不算新类型）
    const pattern = /^(?:@[\w()]+\s+)*(?:public\s+|private\s+|internal\s+|final\s+|open\s+|static\s+)*\b(?:struct|class|enum|protocol|actor)\s+([A-Za-z_]\w*)/gm;
    let match;
    while ((match = pattern.exec(code)) !== null) {
        const name = match[1];
        if (!declarations.has(name)) declarations.set(name, []);
        declarations.get(name).push(rel);
    }
}

// SwiftUI 的 ViewBuilder 最多接受 10 个子视图，超了会报 "extra argument in call"
const BUILDER_CONTAINERS = /\b(VStack|HStack|ZStack|Section|Group|Form|List|Menu|ScrollView|NavigationStack|LazyVGrid)\s*(\([^)]*\))?\s*\{\s*$/;

/// 多行字符串的内容行会被误判成子视图，先整段清空（保留行数，行号才准）
function blankMultilineStrings(raw) {
    const lines = raw.split('\n');
    let inside = false;

    for (let i = 0; i < lines.length; i += 1) {
        const occurrences = (lines[i].match(/"""/g) || []).length;

        if (!inside) {
            if (occurrences === 1) {
                inside = true;
            } else if (occurrences >= 2) {
                lines[i] = lines[i].replace(/"""[\s\S]*?"""/g, '""');
            }
        } else {
            lines[i] = '';
            if (occurrences >= 1) {
                inside = false;
            }
        }
    }

    return lines;
}

function checkViewBuilderLimits(rel, raw) {
    const lines = blankMultilineStrings(raw);

    for (let i = 0; i < lines.length; i += 1) {
        const head = lines[i];
        if (!BUILDER_CONTAINERS.test(head.trimEnd())) continue;

        let first = -1;
        for (let j = i + 1; j < lines.length; j += 1) {
            const text = lines[j].trim();
            if (text === '' || text.startsWith('//')) continue;
            first = j;
            break;
        }
        if (first < 0) continue;

        const childIndent = lines[first].match(/^\s*/)[0].length;
        let depth = 0;
        let count = 0;
        let bodyEnd = -1;

        for (let j = i; j < lines.length; j += 1) {
            const text = lines[j];
            const trimmed = text.trim();

            if (j > i) {
                const indent = text.match(/^\s*/)[0].length;
                const isContinuation = trimmed.startsWith('.')
                    || trimmed.startsWith('}')
                    || trimmed.startsWith(')')
                    || trimmed.startsWith(']')
                    || trimmed.startsWith('else');

                if (depth === 1 && indent === childIndent && !isContinuation && trimmed !== '') {
                    count += 1;
                }
            }

            depth += (text.match(/\{/g) || []).length;
            depth -= (text.match(/\}/g) || []).length;

            if (j > i && depth <= 0) {
                bodyEnd = j;
                break;
            }
        }

        if (count > 10 && bodyEnd > 0) {
            console.log(`[ViewBuilder] ${rel}:${i + 1} ${head.trim()} 里有 ${count} 个子视图，超过 SwiftUI 的 10 个上限，需要用 Group 分组`);
            problems += 1;
        }
    }
}

for (const file of files) {
    if (file.endsWith('.swift')) {
        checkViewBuilderLimits(path.relative(rootDir, file), fs.readFileSync(file, 'utf8'));
    }
}

for (const [name, where] of declarations) {
    const swiftFiles = where.filter(f => f.endsWith('.swift'));
    if (swiftFiles.length > 1 && !swiftFiles.every(f => f === swiftFiles[0])) {
        console.log(`[重名] 类型 ${name} 出现在多个文件: ${[...new Set(swiftFiles)].join(', ')}`);
        problems += 1;
    }
}

const pbxprojPath = path.join(rootDir, `${projectName}.xcodeproj`, 'project.pbxproj');
if (fs.existsSync(pbxprojPath)) {
    const pbxproj = fs.readFileSync(pbxprojPath, 'utf8');
    let missing = 0;
    for (const file of files) {
        const name = path.basename(file);
        if (!pbxproj.includes(`/* ${name} */`)) {
            console.log(`[工程] ${path.relative(rootDir, file)} 没有出现在 project.pbxproj 里 —— 需要重新跑 node tools/generate-xcodeproj.mjs`);
            missing += 1;
        }
    }
    if (missing > 0) problems += missing;
} else {
    console.log(`[工程] 找不到 ${projectName}.xcodeproj/project.pbxproj，跳过「源文件是否进工程」检查`);
}

console.log(problems === 0
    ? `检查完成：${files.length} 个文件，括号配平、没有跨文件重名、且都在 Xcode 工程里。`
    : `检查完成：发现 ${problems} 个可疑点。`);
process.exit(problems === 0 ? 0 : 1);
