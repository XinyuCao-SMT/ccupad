# CCUPad · iPad 上的索尼 CCU 音频增益 + Tally 面板

把 iPad 变成一台**随身的 CCU 调音台**：直连局域网里的索尼 HDCU-3500 / 3100 系列 CCU，
一屏看完全部机位的 **tally（谁在播出）**，并直接推子控制每台 CCU 的**音频增益**。

SwiftUI，最低 **iPadOS 17.0**，**零外部依赖** —— HTTP Digest / WebSocket / MessagePack 全部自己实现，
所以云端编译不需要解析任何 Swift Package。

> **状态：已在 GitHub Actions 上编译通过（1.4 分钟，产物 arm64 / iOS 17.0），未签名 IPA 已产出。**
>
> | | |
> | --- | --- |
> | 仓库 | <https://github.com/XinyuCao-SMT/ccupad> |
> | 当前版本 | **0.6.0**（tag `v0.6.0-english`，[Release 永久下载](https://github.com/XinyuCao-SMT/ccupad/releases/tag/v0.6.0-english)） |
> | 归档产物 | `dist/v0.6.0-english/CCUPad-v0.6.0-english-unsigned.ipa`（503 KB，同目录有 SHA256 清单） |
> | 随手产物 | `dist/ipa/CCUPad-unsigned.ipa`（每次云编译覆盖这一个，**别拿它当存档**） |
>
> 协议层是照 [`ccu-studio`](../ccu-studio) 在真机上验证过的实现逐条复刻的
> （同一套 HTTP Digest 挑战取法、同一个 `ws://<ip>/linear` 升级写法、同一份 MessagePack 编解码）。
>
> **验证边界（重要，别混为一谈）：**
>
> * ✅ **参数层已在真机上验证过**：用同一套协议的只读工具读了 `S6_HDCU3500` 机群全部 10 台
>   （每台 3331 项），增益与 tally 的参数名、量程、偏移、方向都是 **实测确认**的（见第 2 节）。
> * ✅ **协议只读路径对真机成立**：HTTP Digest 挑战 → `ws://<ip>/linear` 升级 → MessagePack 帧 →
>   `Ch.SetValue 8603=7` 读全量，这条链路在真设备上每次都能读到 3331 项。
> * ⚠️ **App 本身还没装到 iPad 上跑过**，也**从未向 CCU 写入**过任何值 ——
>   协议层的 Swift 实现是照已验证的 Node 实现逐条复刻的，但「复刻正确」不等于「跑过」。
>   装好后可以先加一台**演示机位**验证 App 自身（不需要任何硬件，参数名与量程照真机），
>   见第 5 节第 0 步。**第一次真实下发建议只在一台设备上、且先看「试运行」日志。**

---

## 1. 它做什么

| 能力 | 说明 |
| --- | --- |
| 直连 CCU | iPad 直接连 CCU 的管理口（`10.205.1.x:80`），不需要中间那台 PC |
| 多台同时在线 | 一次连整个机位群；地址支持 `10.205.1.101-108`、`10.205.1.101-104, .111` 这类写法 |
| 音频增益控制 | 每台 CCU 每个通道一个**大触摸目标的垂直推子**；拖动时只在本地预览，**松手才写一次设备**（默认）；± 步进、连续型可归零；**枚举型参数吸附到设备给的档位**（± 按钮按档位跳，且不显示「0」） |
| 批量操作 | 「全部 +0.5 dB」「全部 −0.5 dB」「全部 0 dB」一键下发全部机位 |
| 演示机位（无需硬件） | 一键加一台模拟 CCU：8 路音频增益、PGM/PVW tally 每 3 秒翻一次、约 600 个填充参数与诱饵项，而且**自带映射** —— 装完 App 就能先跑通界面、推子、写入校验与 tally |
| Tally 可视化 | 每台格子按 tally 上色：**PGM 红框 / PVW 绿框 / 未上播 灰框**；顶部总览条同步变色 |
| 增益总览 | 一屏一行的横向条形图，把全部机位的电平位置并排放在一起看 |
| 写入校验 | 每条写值都会等设备回推确认；没确认就自动重试一次，仍失败则标红并写日志（不会假装成功） |
| 参数发现 | 读出设备全部约 3300 个参数，按名字搜索 / 按归类筛选 / 看实时值，并在这里把参数**绑定**成增益通道或 tally 来源 |
| 参数清单导出 | 把某台设备的全部参数导成 TSV 落到「文件」App，方便存档或回传给开发核对 |
| 装上即绑好（HDCU） | 连上并读完参数后，若这台设备**还没绑过任何东西**，自动套用**实测确认**的映射（话筒增益 2 路 + tally PGM·PVW），不用去发现页；已绑过的设备可以在参数发现页点「套用实测默认」一键换新 |
| **锁定其他项目** | 打开后主控台只剩**推子 + tally**，**参数发现 / 设备 / 设置**三页要输管理密码才出现。密码存 Keychain，解锁状态**不持久化**（重启回到锁定）；未设密码时不允许打开锁定 |
| 安全默认 | **默认开启「试运行」**：所有操作照常走一遍并写日志，但一个字节都不发给设备 |

界面四个页：**主控台**（调音）· **参数发现**（绑定）· **设备**（增删改 + 连接测试）· **设置**。

**界面语言有中文和英文两套，可按 App 单独切**：iPad「设置 → CCUPad → 首选语言 → English / 中文」
（iOS 13 起支持，不用改系统语言；重启 App 后生效）。翻译在
`CCUPad/Resources/{en,zh-Hans}.lproj/Localizable.strings`，键就是中文原文，
两边键必须完全一致 —— 由 `node tools/check-strings.mjs` 在发版时校验。

**推子推完到设备回读确认之间会显示黄色 + 「正在调整，请稍等」** —— 这不是卡住，是在等设备回推；
确认后自动恢复。若一直黄着，去日志页看这次写入有没有被确认。

---

## 2. 增益与 tally 的参数名：**已实测确认**（HDCU3500 / 3100）

一台 HDCU 有约 **3300 个参数**。`ccu-studio` 的参数目录只收录了其中约 250 个
（IP Live / 格式 / 网络那一批），**音频增益和 tally 都不在其中**；
索尼也没有公开完整的参数名表。所以这一层是**在真机上读出来并验证过**的：

2026-10，在 `S6_HDCU3500` 机群（10 台，HDCU3500 / V3.40 / 每台 3331 项）实测。
**默认只绑第一行那一路**（主控台就是「推子 + tally」），其余参数名与换算记在这里备查，
需要时解锁后在「参数发现」页绑回来：

| 用途 | 参数名 | 性质 |
| --- | --- | --- |
| **话筒增益（MIC GAIN）** | `ItemMicGainCh1` / `ItemMicGainCh2` | **5 档枚举**：20 / 30 / 40 / 50 / 60 dB（摄像机**没接上**时只剩 `Null` 一档） |
| **音频输出增益** | `ItemAudioOutCh1Adjust` / `ItemAudioOutCh2Adjust` | 数值型，**min 0 … max 255（256 档）**，静止值 **128** |
| 输出参考电平标准 | `ItemAudioOutCh1Level` / `ItemAudioOutCh2Level` | **3 档枚举**：−20 dBu / 0 dBu / +4 dBu（是标准选择器，不是可推的增益） |
| **tally 播出（红 / PGM）** | `ItemTallyRStatus` | 0 / 1 |
| **tally 预览（绿 / PVW）** | `ItemTallyGStatus` | 0 / 1 |

**⚠️ 一个容易踩的协议行为：设备下发的 `enum` 是「此刻可选」的候选，不是完整枚举域。**
同一台设备的 `ItemMicGainCh1`：摄像机接上时档位表是 5 档 [20/30/40/50/60 dB]、当前值 `3001002`（=30 dB）；
**摄像机没接上时档位表只有 `Null` 一档**、当前值 `3001000`。
所以 App 在「档位表只有一档、又没有 `min`/`max`」时会把该通道判为**不可写**（界面置灰）——
否则推子会退化成自由控件，一推就下发设备不接受的中间值。这一条是 0.4.0 修掉的真隐患。

**关键换算：OSD 显示值 = 原始值 − 128。** 证据：OSD 上 `ADJUST : 0` 而原始值是 `128`；
同一页 `LEVEL : 0 dBu` 的原始值是 `3103001`，而固件枚举表里 `3103001 = 0dBu` ——
说明 OSD 确实会解释原始值，所以 ADJUST 的 128→0 只可能是偏移映射。
因此绑定里除「除数」外还有一个 **`offset`**（HDS 这两路填 128），界面正中对 0，与 OSD 一致。

**tally 是双向实测，不是对称猜测：** 先在「1 号机红亮」时读 10 台 → 只有 101 的
`ItemTallyRStatus = 1`；然后在 1 号机上切绿、把红挪到 7 号机后再读 →
`ItemTallyGStatus` 只有 101 为 1、`ItemTallyRStatus` 只有 **107** 为 1。
另有 35 个名字像 tally 的参数（`ItemTallyFrom*`、`ItemMonitorTallyMode/Marker` …）
在各台之间**完全相同** —— 它们是设置项，不是状态位。

**非 HDCU 机型仍然可以手动绑**（下面这套机制保留）：

所以这台 App **不猜参数名**。它的做法是：

1. 连上设备，把全部参数读回来（就是官方网页每次打开页面做的事：`Ch.SetValue id=8603 value=7`）；
2. 在「参数发现」页按名字挑候选（`audio` / `gain` / `tally` / `pgm` …），**看实时值**确认；
3. 你把它绑成「增益通道」或「Tally PGM / PVW」，映射按设备记住；
4. 之后主控台就照这份映射显示和下发。

这样做的好处是：换固件、换机型、甚至换到别的型号，只要重新绑一次，**代码一行都不用改**。

**绑定增益时有一个「除数」要注意**：设备上报的增益常常不是「dB」，而是某个内部步进。
例如以 0.1 dB 为单位时，原始值 `60` 表示 `6.0 dB` —— 这时除数填 `10`。
拿不准就先留 `1`，绑定后在主控台看数字是否合理，再回来改（**改除数不会写设备**）。

**如果那一项是枚举型**（参数发现页会标出「枚举 N 档」）：设备对这类参数报的 `min`/`max` 是
**索引范围**，合法值只在档位表（报文的 `enum` 字段）里。这种情况 App 会把推子**吸附到最近的合法档位**，
量程也改成以档位表为准 —— 所以不会出现「推子停在设备不接受的中间值」这种问题。

**已确认增益落在 OSD 的 `<AUDIO OUT>` 页**（现场截图）：

```
<AUDIO OUT>                              A02 TOP
  DELAY          : 0 ms
  AES/EBU OUT    : AES/EBU
  ANALOG OUT     : MIC 1/2
  CH1 LEVEL      : 0 dBu      ADJUST : →  0
  CH2 LEVEL      : 0 dBu      ADJUST :     0
```

每通道两栏 —— `LEVEL`（电平）与 **`ADJUST`（增益调整）**，现场要调的多半是 `ADJUST`。
所以参数发现页里凡是名字像 `…AudioOut…Level` / `…AudioOut…Adjust` 的项，
App 会直接在下面标出「像是 OSD『AUDIO OUT』页的 LEVEL / ADJUST」，照着提示绑即可。
（这条也是照截图把 `adjust` 补进增益词表的：少了它，`…Adjust` 会被归成「音频相关」，
既不会被自动绑定，也不会进 `--watch` 的观察清单。）

**tally 建议这样确认**：把候选参数按实时值盯着，然后在切换台上真的切一次机位 ——
哪个参数跟着动，它就是 tally。若这台设备用一个位图参数表示 tally，就把 PGM 与 PVW 绑同一个参数，
再到「设置」里调阈值。

---

## 3. 硬性前提

1. **iPadOS 17.0 或更高**（工程按 17.0 编译）。
2. **iPad 与 CCU 在同一局域网**，能访问 CCU 管理口的 **80 端口**。
3. **首次连接必须允许「本地网络」权限。** iOS 14 起，App 访问局域网设备要用户授权；
   Info.plist 里没有那条用途说明时，系统连权限框都弹不出来，**发给 CCU 的包会被静默丢弃**，
   表现就是「一直连不上、还看不到任何错误」。
   注意：**拒绝过一次之后，只能去「设置 → 隐私与安全性 → 本地网络」里重新打开**，App 不会再弹第二次。
4. CCU 的管理账号密码（HDCU 默认 `admin`，现场多为 `admin` + 自定义密码）。

---

## 4. 编译与安装

### 路线 A：有 Mac

```bash
open CCUPad/CCUPad.xcodeproj
```

选 target **CCUPad** → *Signing & Capabilities* → 勾 **Automatically manage signing** 并选自己的 Team，
然后 `⌘R` 跑到 iPad 上。免费 Apple ID 也能装，但签名 **7 天过期**。

> 工程文件是用脚本生成的（`CCUPad/tools/generate-xcodeproj.mjs`）。
> **新增 / 删除 / 重命名源文件后，必须重新跑一次**，否则新文件不会进工程：
> ```bash
> cd CCUPad && node tools/generate-xcodeproj.mjs
> ```
>
> 在没有 Swift 编译器的机器上（例如 Windows），提交前建议跑一遍两个静态自检 ——
> 它们专门抓「明明没编译过、却能提前发现」的那类错误：
> ```bash
> cd CCUPad
> node tools/check-sources.mjs   # 括号配平 / 跨文件重名 / 源文件是否都进了工程 / ViewBuilder 上限
> node tools/check-calls.mjs     # 我们自己的方法是否存在、参数标签与声明是否一致
> ```
> `check-calls.mjs` 是这套工程里最值钱的一个自检：Swift 最常见的两个编译错误
> （`has no member 'x'` 和 `missing argument label 'y:'`）它都能在本地提前抓出来。
> CI 里也会跑这两个脚本（不拦构建，只把结果打进日志）。

### 路线 B：只有 Windows（GitHub Actions 云 Mac 编译 + 侧载）

Windows 上无法编译 iOS 应用，用云端 macOS 编出**未签名 IPA**，再用自己的 Apple ID 签名安装。
完整步骤见 **[`CLOUD-BUILD.md`](CLOUD-BUILD.md)**。最短路径：

**一条命令拿到 IPA**（推荐）：

```powershell
cd CCUPad
set GH_TOKEN=ghp_你的token
node tools/publish.mjs 你的用户名/ccupad --create
```

它会建仓库 → 推代码 → 等这次提交的云编译跑完 → 下载工件并解压出 `dist\ipa\CCUPad-unsigned.ipa`。

**或者手动走网页：**

1. 建仓库并推代码（`tools/push-via-api.mjs` 只靠 `api.github.com` 就能推，还能自动建仓库）。
2. 仓库 → **Actions** → **Build unsigned IPA** → **Run workflow**。
3. 4–6 分钟后在 **Artifacts** 下载 `CCUPad-unsigned-ipa`，解压得到 `CCUPad-unsigned.ipa`。
4. 用 [Sideloadly](https://sideloadly.io/) 拖进去，Apple ID 填自己的，Start。
5. iPad 上「设置 → 通用 → VPN 与设备管理」信任该开发者；
   iPadOS 16+ 还要先去「设置 → 隐私与安全性」打开**开发者模式**并重启。

---

## 5. 上手顺序（建议照这个走一遍）

0. **先加一台演示机位**（设备页 → 右上角 + → **添加演示机位**）：它不需要任何硬件，自带映射，
   立刻就能看到推子、写入校验（琥珀 → 白）和每 3 秒跳一次的 tally。
   这一步同时是**诊断手段**：真机连不上时，先用它排除「App 本身」的问题。
1. **设备页 → 右上角 +**：填 `10.205.1.101-108` 这样的范围、用户名、密码，点「测试连接」
   （只做一次 Digest 认证验证，**不下发任何设置**），确认通过后「添加」。
2. **主控台 → 连接全部**：等每台状态变成「已连接」（会显示读到了多少个参数，约 3300）。
3. **参数发现页**：选一台设备 → 搜 `audio` 或 `gain` → 盯着**实时值**确认哪个是你要调的增益
   → 右侧 `⋯` → 「设为增益通道」。需要的话填除数与单位。
   再搜 `tally`，用切换台切一次机位确认，绑成 **Tally PGM**。
4. **回主控台**：推子应该出现了。此时**「试运行」默认是开的** —— 推一次推子，
   日志里会写「试运行：未下发」，设备不受影响。确认映射和方向都对，再到设置里关掉试运行。
5. 关掉试运行后先在**一台**设备上验证真实下发，再放开批量操作。
6. **每次批量下发前 App 会自动拍一张增益快照**；推错了就到「设置 → 增益快照与回滚」逐张回滚，
   或直接按主控台的「撤销上次下发」。快照保留最近 30 张，存的是设备原始值。
7. **想锁成操作员界面**：设置 → 安全 → 先设一个管理密码（至少 4 位）→ 再打开
   「锁定其他项目」。之后主控台只剩推子 + tally；要进参数发现 / 设备 / 设置就点主控台的
   **「解锁其他项目」**输密码。重启 App 会自动回到锁定。

---

## 6. 目录结构

```
CCUPad/                                <- 仓库根目录
├─ .github/workflows/build-ipa.yml     <- 云端编未签名 IPA
├─ README.md                           <- 本文档
├─ CHANGELOG.md                        <- 变更记录（一版一节）
├─ ROLLBACK.md                         <- 回滚指南：版本点 / 三种回滚方式 / 现场增益回滚
├─ CLOUD-BUILD.md                      <- 云端编译 + Windows 侧载保姆级步骤
├─ NEXT-STEPS.md                       <- 待办与已知边界
├─ tools/push-via-api.mjs              <- 只靠 api.github.com 推送（还能建仓库）
├─ tools/publish.mjs                   <- 一条命令：推送 → 云编译 → 下载解压出 IPA
├─ tools/release.mjs                   <- 发版：校验 → 归档 + 清单 + tag + Release 附件
├─ tools/fetch-run-errors.mjs          <- 失败时抓取并去重打印编译错误
└─ CCUPad/                             <- Xcode 工程目录
   ├─ CCUPad.xcodeproj/                <- 已生成，可直接打开
   ├─ tools/generate-xcodeproj.mjs     <- 增删源文件后重新生成工程
   ├─ tools/check-sources.mjs          <- 静态自检：配平 / 重名 / 源文件是否进工程
   ├─ tools/check-calls.mjs            <- 静态自检：方法是否存在 / 参数标签是否匹配
   └─ CCUPad/
      ├─ App/        CCUPadApp.swift
      ├─ Protocol/   MessagePack · DigestAuth · HTTPClient · WebSocketClient
      ├─ CCU/        CCUSession（会话）· CCUManager（多台总控）
      ├─ Model/      CCUItem · CCUDevice · ParameterMap · CCUState · AppSettings · GainSnapshot
      ├─ Store/      AppStore（UserDefaults）· Keychain（密码）
      ├─ Views/      Dashboard · CCUTile · VerticalFader · GainOverview · Discovery · Devices · Settings · Theme
      └─ Resources/  Assets.xcassets
```

> **版本与回滚**：每个发版都是不可变的历史点 —— 独立 tag + `dist/<tag>/` 归档（含 `MANIFEST.txt`：
> SHA256 / 提交 / IPA 结构校验逐项）+ `E:\harness\_backup` 里的源码归档 + GitHub Release 永久附件。
> 回滚步骤见 [`ROLLBACK.md`](ROLLBACK.md)，变更历史见 [`CHANGELOG.md`](CHANGELOG.md)。
>
> 另有一半是**设备侧**的：App 内会在批量下发前**自动拍增益快照**，可一键退回
> （见下面第 5 节第 4 步）—— 那是「写错了怎么退」，与软件版本回滚是两件事。

---

## 7. 协议实现要点（都是从 ccu-studio 的真机结论复刻的）

设备侧接口是 **HTTP Digest 认证 + `ws://<ip>/linear` 上的 MessagePack 帧**，帧形状 `[2, "方法名", {参数}]`：

| 方向 | 报文 |
| --- | --- |
| 订阅 | `[2,"Subscribe",{channel:"Ch.Notify.Update"}]`（另有 VirtualScreen / Service / KeepAlive） |
| 读全量 | `[2,"Ch.SetValue",{id:8603,op_type:0,value:7}]` → 设备推送全部参数 |
| 写值 | `[2,"Ch.SetValue",{id:<参数ID>,op_type:0,value:<值>}]` |

**两个必须照做的坑**（不这么做就连不上，而且报错具有误导性）：

1. `/linear` 这个 WebSocket 地址在**未认证时返回 403 而不是 401** —— 也就是说它不给 Digest 挑战。
   所以必须先 `GET /` 拿一次挑战，再把算好的 `Authorization` **直接放进升级请求**。
2. 升级请求**必须带 `Origin` 头**，否则 nginx 直接 403。

所以本工程**没有用 `URLSessionWebSocketTask`**，而是用 `Network.framework` 手写了握手与分帧
（客户端掩码、16/64 位长度、ping/pong、close、分片拼接），这样才能完全控制升级请求的头。
HTTP 客户端同理是手写的（只用来取挑战）。

写值的取舍也照搬了现场经验：**每条写值间隔 60 ms 下发**（设备端偶发丢包，挤在一起容易一起丢），
写完后等设备回推确认，**3 秒没等到就重发一次**，仍失败就标红并记日志 —— 不会假装写成功。

---

## 8. 已知边界

* **App 还没在 iPad 上跑过，也从未向 CCU 写入过。** 参数层与协议只读路径已在 10 台真机上验证
  （见开头「验证边界」），但**第一次真实下发仍建议只在一台设备上试**，并先看「试运行」日志与
  「增益快照」有没有自动拍下来。内置的「测试连接」和日志页就是为这一轮准备的。
* **tally 在 HDCU3500/3100 上已确认能拿到**（`ItemTallyRStatus` = PGM、`ItemTallyGStatus` = PVW，实测）。
  但**别的机型未必暴露** —— 那种情况下参数发现页仍能把候选列出来，若确实没有，
  tally 的权威来源在切换台或 CNS/MCS 侧，需要另外接一路数据。
* **增益方向 / 单位**由绑定里的「除数 + 偏移 + 单位」决定，App 不假设设备用的是 dB。
  已知 HDCU 的 ADJUST 是 0…255、中心 128（已内置 offset 128）；每档多少 dB 参数里没有，
  需要按现场手册或 OSD 实际显示来定。
* **设备下发的档位表随状态变化**（同 0.4.0 那条）：摄像机没接上时话筒增益只剩 `Null` 一档，
  App 会把这类通道判为不可写而不是硬推。若你看到某路灰着，先看设备那边这个参数当前是否可选。
* 只处理**参数层**：不做固件升级、不恢复出厂、不改登录密码、不碰网络与 IP Live 配置。
* **演示机位为了跑得快只生成约 620 个参数**（真机 3331），但**关键那几项用的是真机同名参数与量程**
  （`ItemAudioOutCh1/2Adjust` 0…255 偏移 128、`ItemTallyR/GStatus`），所以演示跑的就是正式那条路径。
* iPad 进入后台后 WebSocket 会被系统挂起，回到前台靠自动重连恢复。

---

## 9. 与 `ccu-studio` 的关系

`ccu-studio`（同工作区的 Node 版）负责**批量配置** IP Live / ST2110 / 格式参数；
`CCUPad` 负责**现场实时**看 tally 与调音频增益。
两者的设备端协议是同一套，`CCUPad` 的协议层就是照 `ccu-studio/lib/protocol.mjs` 与 `lib/ccu.mjs`
逐条复刻的 —— 那边踩过的坑（403 不给挑战、必须带 Origin、写值要等回推）这边一个都没重复踩。

---

## 10. 许可

自用工程，随你改。CCU、HDCU、iPad 的商标与版权各归其主。
