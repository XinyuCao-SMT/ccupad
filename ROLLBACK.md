# 回滚指南 · 版本保留说明

每个发版都是一个**不可变的历史点**，随时可以退回去。一版一套：

| | |
| --- | --- |
| 源码标记 | 独立 tag（如 `v0.2.0-gain-tally`） |
| 二进制 | 独立文件夹 `dist/<tag>/` 里一个独立命名的 IPA |
| 清单 | 同文件夹的 `MANIFEST.txt`（版本 / 大小 / SHA256 / 提交 / 校验逐项 / 回滚指引） |
| 源码归档 | `E:\harness\_backup\src-ccupad-<tag>-<提交>.zip`（离线可恢复） |
| 永久下载 | GitHub Release 附件（不受工件 30 天限制） |

发版流程本身在 `tools/release.mjs`：版本号一致性 → 自检 → **IPA 结构校验** → 归档 → 打 tag →
（`--upload`）推 tag 并建 Release 挂附件。**任何一条校验不过就不发版。**

---

## 版本

| 版本 | 提交 | Tag | 内容 | IPA |
| --- | --- | --- | --- | --- |
| **v0.2.0 增益快照与回滚版**<br>（当前，推荐装） | 本地 `dd8d05f`<br>远端 `0296f25` | `v0.2.0-gain-tally` | **下发前自动拍增益快照 + 一键回滚**；演示机位（不需要硬件）；枚举型参数吸附到合法档位；照真机 OSD 补 `adjust` 词与「参数名 → OSD 栏目」映射；发版 / 回滚机制本身 | `dist/v0.2.0-gain-tally/CCUPad-v0.2.0-gain-tally-unsigned.ipa`（461 KB） |
| 0.1.0<br>（**未归档**） | — | 无 tag | 协议层（HTTP Digest / WebSocket / MessagePack）+ 主控台 + 参数发现 + 设备 + 设置 | 只有云端工件：run #3 / #4，见文末 |

> ⚠️ **0.1.0 没有走发版流程** —— 本地没留 IPA 归档、也没有 tag。
> 它的两次云端编译工件还在 GitHub 上（工件保留 30 天）：run #3 是**第一次编译成功**，
> run #4 多了按 OSD 修正的增益词与参数名映射。
> 从 0.2.0 起每一版都会归档、打 tag、挂 Release 附件，不再依赖工件有效期。

---

## ⚠️ 关于提交 SHA 不一致（重要，先看这段）

本仓库的推送走 **GitHub REST API**（`push-via-api.mjs`，用来绕开 `github.com:443` 间歇不可达）。
API 重放会**新建提交对象**，所以远端提交的 SHA 与本地**不同** —— 但**内容完全一致**：

```
本地 tag v0.2.0-gain-tally -> dd8d05f   tree fe66b5943965152349b63ed759e144901ee61874
远端 tag v0.2.0-gain-tally -> 0296f25   tree fe66b5943965152349b63ed759e144901ee61874   ← 同一个 tree
```

* `git clone` 之后 `git checkout v0.2.0-gain-tally` 拿到的是**远端那一份**（`0296f25`），
  与本地 `dd8d05f` 内容相同。
* 想核对「这两份是不是同一个东西」，**比较 tree，不要比较提交 SHA**：
  ```bash
  git rev-parse v0.2.0-gain-tally^{tree}                     # 本地
  # 远端：GET /repos/XinyuCao-SMT/ccupad/git/commits/<sha> 里的 tree.sha
  ```
* `MANIFEST.txt` 里记的是**本地**提交（发版机上 `git rev-parse` 的结果），
  两边对照时请以 tree 为准。

---

## 三种回滚方式

### 方式 A：只把 iPad 上的 App 换回旧版（最快，不动代码）

1. 用 **Sideloadly** 装想要的版本，例如
   `dist/v0.2.0-gain-tally/CCUPad-v0.2.0-gain-tally-unsigned.ipa`
2. 或从 GitHub Release 下载（**永久有效**，不受工件 30 天限制）：
   * v0.2.0 <https://github.com/XinyuCao-SMT/ccupad/releases/tag/v0.2.0-gain-tally>
3. 同一个 Bundle ID 重装属于升级/降级安装，**设备清单与参数映射通常保留**。
   保险起见先在「参数发现」页导出参数清单，把映射留一份。

### 方式 B：把源码回滚到旧版

```bash
cd "E:\harness\CCUPad"
git checkout v0.2.0-gain-tally      # 回到那一版的源码（tag 指向被编译的提交）
# 要重新编译就在这个状态跑：node tools/publish.mjs XinyuCao-SMT/ccupad --no-push
git checkout main                   # 回到最新版
git log --oneline -1                # 确认当前位置
```

换台机器 `git clone` + `git checkout v0.2.0-gain-tally` 同样有效（远端 tag 已推送）。

### 方式 C：完全离线恢复（连 git / GitHub 都没有）

解压这些归档即可得到完整工程（含 Xcode 工程、scheme、CI 工作流）：

```
E:\harness\_backup\src-ccupad-v0.2.0-gain-tally-dd8d05f.zip   ← 0.2.0 完整工程
E:\harness\_backup\build-records.txt                          ← 各版本：提交 / IPA 路径 / SHA256 / 编译地址
```

---

## 现场增益回滚（这不是软件版本回滚，是**设备侧**的）

这个 App 会**真的把增益写进 CCU**，舞台上推错一下必须能退回来 ——
纪律照 `ccu-studio`（「执行前强制生成快照，可逐设备回滚」）。所以另有两条保险：

1. **批量操作前自动拍快照**：全部 ± dB、全部归零、整台归零、整台 ± dB 都会先拍一张。
   试运行模式下不拍（反正没写设备）；未连接的设备拍不到、也不会被改。
2. **一键回滚**：设置页「增益快照与回滚」可以逐张回滚（最近 8 张列出来），
   主控台批量条上有「撤销上次下发」。总共保留最近 **30** 张。

快照存的是**设备原始值**（不预除除数），所以以后改除数、改单位都不会让旧快照失真；
回滚走的是与推子**同一条下发路径**（夹量程 + 枚举档位吸附），不会绕过安全逻辑。

---

## 校验哈希（确认手里的是哪一版）

| 文件 | 大小 | SHA256（前 16 位，完整值见 `MANIFEST.txt`） |
| --- | --- | --- |
| `CCUPad-v0.2.0-gain-tally-unsigned.ipa` | 461 KB | `3C7B699C8518E8EE…` |

```powershell
Get-FileHash .\dist\v0.2.0-gain-tally\CCUPad-v0.2.0-gain-tally-unsigned.ipa -Algorithm SHA256
```

`MANIFEST.txt` 里还有逐项的 IPA 结构校验结果（arm64 / `CFBundleShortVersionString` = 0.2.0 /
`NSLocalNetworkUsageDescription` 在）。

---

## 构建工件地址（GitHub Actions，30 天后过期）

| 版本 | CI 运行 |
| --- | --- |
| 0.1.0（第一次编译成功） | <https://github.com/XinyuCao-SMT/ccupad/actions/runs/37734502920> |
| 0.1.0 + 按 OSD 修正 | <https://github.com/XinyuCao-SMT/ccupad/actions/runs/37735906844> |
| **v0.2.0-gain-tally** | <https://github.com/XinyuCao-SMT/ccupad/actions/runs/37736352828> |

各版本的 IPA 都已挂到对应 Release 的附件里，**永久可下载**：

* v0.2.0：<https://github.com/XinyuCao-SMT/ccupad/releases/tag/v0.2.0-gain-tally>

---

## 怎么发下一个版本

```powershell
cd E:\harness\CCUPad

# 1) 改版本号（唯一来源）并重新生成工程
#    编辑 CCUPad\tools\generate-xcodeproj.mjs 里的 appVersion
node CCUPad\tools\generate-xcodeproj.mjs

# 2) 提交
git add -A ; git commit -m "feat: ..."

# 3) 推送 + 云编译 + 取回 IPA（会按远端提交匹配本次运行）
set GH_TOKEN=<有 repo 权限的 token>
node tools\publish.mjs XinyuCao-SMT/ccupad

# 4) 发版：自检 + IPA 结构校验 + 归档 + 打 tag + 推 tag + 建 Release 挂附件
node tools\release.mjs --tag=v0.2.1-xxx --commit=<上一步被编译的那个提交> --note="说明" --upload
```

几点约定：

* `appVersion` 是版本号的**唯一来源**，`release.mjs` 会强制它与 tag 里的版本一致，不一致拒绝发版。
* `--commit` 指向**被编译的那个提交**：发版之后若又提交了文档，tag 仍然指向被编译的提交，
  这样「checkout tag 拿到的源码」与「IPA 里的代码」始终是同一份。
* `main` 分支始终是最新版；旧版只存在于 tag 上，不会被后续提交覆盖。
* 已知限制：iPadOS 应用**无法在本机做功能性自检**（没有 iOS 模拟器/SDK），
  所以这里用**结构校验**替代 —— 核对包结构、架构、版本号与权限键。
  真正的功能验证只能在真机上做（见 `NEXT-STEPS.md`）。
