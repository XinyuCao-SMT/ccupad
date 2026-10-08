# 变更记录 · CCUPad

版本纪律见 [`ROLLBACK.md`](ROLLBACK.md)：每个发版都是一个**不可变的历史点** ——
独立 tag、独立 `dist/<tag>/` 文件夹（含 IPA 与 `MANIFEST.txt`）、独立源码归档、
以及 GitHub Release 上的永久附件。

---

## 0.2.0 · 增益快照与回滚（tag `v0.2.0-gain-tally`）

**一、设备侧回滚：下发前自动拍快照，可一键退回**

这个 App 会**真的把增益写进 CCU**，舞台上推错一下必须能退回来 ——
纪律照 `ccu-studio`（「执行前强制生成快照，可逐设备回滚」）。

* 新增 `GainSnapshot`（设备 / 时间 / 原因 / 参数名 → 设备原始值），持久化最近 **30** 张。
* **批量操作在下发前自动拍快照**：全部 ± dB、全部归零、整台归零、整台 ± dB。
  试运行模式下不拍（反正没写设备）；未连接的设备拍不到、也不会被改。
* 快照只存**设备原始值**（不预除除数），所以以后改除数、改单位都不会让旧快照失真。
* 回滚走**与推子同一条下发路径**（夹量程 + 枚举吸附），不会绕过安全逻辑。
* 界面：设置页「增益快照与回滚」（最近 8 张 + 逐张回滚 / 撤销上一次下发 / 清空）；
  主控台批量条新增「撤销上次下发」。
* 顺带修掉：批量操作原本只筛 `enabled`，**未连接的设备也会被改掉本地显示值**（现在要求已连接）。

**二、演示机位（不需要任何硬件）**

* 新增 `CCUConnection` 协议，`CCUSession` 与 `SimulatedCCU` 都实现它，管理器一视同仁。
* 一键添加：8 路音频增益 + PGM/PVW tally（每 3 秒翻一次）+ 约 600 个填充参数与诱饵项，
  并**自带映射** —— 装完 App 就能先跑通界面、推子、写入校验（待确认 → 已确认）与 tally。
* 诊断价值：真机连不上时，先用它证明「这套代码本身能跑」。

**三、枚举型参数支持（照 `sweep.mjs` 的实测用法发现）**

* 设备对枚举型参数报的 `min`/`max` 是**索引范围**，合法值在报文的 `enum` 档位表里。
* `CCUItem` 读入档位表；推子、± 按钮、批量归零统一走 `GainChannel.snapped()`
  **吸附到最近合法档位**，量程也改以档位表为准 —— 不会下发设备不接受的中间值。
* 参数发现页与绑定表单显示档位并给出提示。

**四、照真机 OSD 修正增益的定位口径**

现场截图确认增益在 CCU 网页 OSD 的 **`<AUDIO OUT>`** 页：每通道两栏
`CH1 LEVEL : 0 dBu` 与 **`ADJUST : 0`**（同页还有 DELAY / AES-EBU OUT / ANALOG OUT）。

* 增益词表补上 **`adjust`** / `offset`。此前 `…AudioOutCh1Adjust` 会被归成「音频相关」
  而不是增益候选 —— 后果不只是自动绑定挑不到，**它也不会进 `--watch` 的观察清单**，
  等于「在 OSD 上按一下、看哪个参数跳」这个万能办法也失效。
* 新增 `ItemClassifier.hint(for:)`：把参数名映射回 OSD 栏目名
  （`AUDIO OUT / LEVEL / ADJUST / DELAY / AES-EBU / ANALOG`），参数发现页每行直接显示。
* 配套的 `ccu-studio/tools/probe-gain-tally.mjs` 增加「OSD AUDIO OUT 页」专区、
  OSD 映射列，以及 **`--watch-all`**（不依赖词表，任何参数变化都报）。

**五、发版与回滚机制本身**

* 新增 `tools/release.mjs`：版本号一致性校验 → 自检不过不发版 → IPA **结构校验**
  （arm64 / `CFBundleShortVersionString` 等于 tag / 本地网络权限键在）→
  归档 `dist/<tag>/` + `MANIFEST.txt`（SHA256 / 提交 / 校验逐项）→ 源码归档到 `_backup/`
  → 打 tag →（`--upload`）推 tag 并建 Release 挂 IPA 永久附件。
* 新增 `ROLLBACK.md`、本 `CHANGELOG.md`。
* 新增 `tools/fetch-run-errors.mjs`：失败时把编译错误抓下来去重打印，不用人工翻网页。

**六、工程侧**

* 源文件 25 → **26**（新增 `CCUConnection.swift`、`GainSnapshot.swift` 等）。
* `check-calls.mjs` 扩展出**协议一致性检查**（缺成员 / 参数标签不匹配），
  并做过**反向验证**：故意让协议多一个没人实现的要求，确认它真会报错并退出 1。
* `publish.mjs` 修两个只有真跑一次才会暴露的 bug（见下）。

---

## 0.1.0 · 首个版本（**未归档，只有云端工件**）

> ⚠️ 这一版**没有**走 `release.mjs`，所以本地没有留 IPA 归档，也没有 tag。
> 它的两次云端编译工件仍在 GitHub 上（工件保留 30 天）：
>
> | 运行 | 内容 | 地址 |
> | --- | --- | --- |
> | run #3 | **第一次编译成功**：协议层 + 主控台 + 参数发现 + 设备 + 设置 | <https://github.com/XinyuCao-SMT/ccupad/actions/runs/37734502920> |
> | run #4 | 同上 + 照 OSD 补 `adjust` 词与 OSD 栏目映射 | <https://github.com/XinyuCao-SMT/ccupad/actions/runs/37735906844> |
>
> 需要这两版的话，从上面两个页面底部 **Artifacts** 下载即可（30 天内）。
> 从 0.2.0 起，每一版都会归档、打 tag、挂 Release 附件，不再依赖工件有效期。

**内容**

* **协议层零依赖自己实现**：HTTP Digest（MD5 / qop=auth）、WebSocket 握手与分帧
  （`Network.framework` 手写，客户端掩码 / 16·64 位长度 / ping-pong / close / 分片拼接）、
  MessagePack 编解码。逐条对齐 `ccu-studio` 在 HDCU-3500/3100 上验证过的行为，
  包括两个坑：`/linear` 未认证时返回 **403 而不是 401**（所以必须先 `GET /` 取挑战，
  再把算好的 `Authorization` 放进升级请求），以及升级请求**必须带 `Origin`**。
* **会话层**：订阅 4 个通知通道 → `Ch.SetValue 8603=7` 读全量约 3300 项 →
  按「参数表不再增长」判定读全；写值 60 ms 节流、等设备回推确认、3 秒未确认重试一次、
  仍失败则标红并记日志。断线自动重连（默认 5 秒）。
* **总控层**：多设备并行、按映射重建派生状态、tally 判定（阈值 / 取反 / 位图同参绑定）、
  批量增益、参数发现、TSV 导出。
* **界面**：主控台（tally 上色边框 + 每通道大触摸垂直推子）、增益总览条、
  参数发现（搜索 / 归类筛选 / 实时值 / 绑定 / 导出）、设备增删改与连接测试、
  设置（试运行 / 实时下发 / 步进 / 重连 / 日志）。
* **安全默认**：默认开「试运行」，所有下发只写日志；批量操作二次确认；密码只进 Keychain。
* **两个真 bug**（只有真跑一次才暴露）：
  ① 空仓库上 Git Data API 一律返回 **409**（连 blobs 都不给），只能走 `git push`；
  ② 经 REST API 重放提交后，远端 commit 的 SHA 与本地**不同** ——
  而 `publish.mjs` 原本拿本地 SHA 匹配云端运行，永远匹配不上，会误判「push 没触发构建」
  并多余地再触发一次（反被 `concurrency` 取消掉真正那次）。现在改为拿**远端分支 HEAD** 匹配。
