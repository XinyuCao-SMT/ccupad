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
> | 当前版本 | **0.2.0**（tag `v0.2.0-gain-tally`，[Release 永久下载](https://github.com/XinyuCao-SMT/ccupad/releases/tag/v0.2.0-gain-tally)） |
> | 归档产物 | `dist/v0.2.0-gain-tally/CCUPad-v0.2.0-gain-tally-unsigned.ipa`（461 KB，同目录有 SHA256 清单） |
> | 随手产物 | `dist/ipa/CCUPad-unsigned.ipa`（每次云编译覆盖这一个，**别拿它当存档**） |
>
> 协议层是照 [`ccu-studio`](../ccu-studio) 在真机上验证过的实现逐条复刻的
> （同一套 HTTP Digest 挑战取法、同一个 `ws://<ip>/linear` 升级写法、同一份 MessagePack 编解码）。
>
> **但还没在真机上跑过、也没连过真机 CCU。** 装好后可以先加一台**演示机位**验证 App 自身，
> 不需要任何硬件；见第 5 节第 0 步。
> **另外有一件事必须由你在真机上确认**，见下面第 2 节 —— 索尼没有公开 CCU 的完整参数名表。

---

## 1. 它做什么

| 能力 | 说明 |
| --- | --- |
| 直连 CCU | iPad 直接连 CCU 的管理口（`10.205.1.x:80`），不需要中间那台 PC |
| 多台同时在线 | 一次连整个机位群；地址支持 `10.205.1.101-108`、`10.205.1.101-104, .111` 这类写法 |
| 音频增益控制 | 每台 CCU 每个通道一个**大触摸目标的垂直推子**；拖动时只在本地预览，**松手才写一次设备**（默认）；±步进、单通道归零、整台归零；**枚举型参数自动吸附到合法档位** |
| 批量操作 | 「全部 +0.5 dB」「全部 −0.5 dB」「全部 0 dB」一键下发全部机位 |
| 演示机位（无需硬件） | 一键加一台模拟 CCU：8 路音频增益、PGM/PVW tally 每 3 秒翻一次、约 600 个填充参数与诱饵项，而且**自带映射** —— 装完 App 就能先跑通界面、推子、写入校验与 tally |
| Tally 可视化 | 每台格子按 tally 上色：**PGM 红框 / PVW 绿框 / 未上播 灰框**；顶部总览条同步变色 |
| 增益总览 | 一屏一行的横向条形图，把全部机位的电平位置并排放在一起看 |
| 写入校验 | 每条写值都会等设备回推确认；没确认就自动重试一次，仍失败则标红并写日志（不会假装成功） |
| 参数发现 | 读出设备全部约 3300 个参数，按名字搜索 / 按归类筛选 / 看实时值，并在这里把参数**绑定**成增益通道或 tally 来源 |
| 参数清单导出 | 把某台设备的全部参数导成 TSV 落到「文件」App，方便存档或回传给开发核对 |
| 安全默认 | **默认开启「试运行」**：所有操作照常走一遍并写日志，但一个字节都不发给设备 |

界面四个页：**主控台**（调音）· **参数发现**（绑定）· **设备**（增删改 + 连接测试）· **设置**。

---

## 2. 🔴 必须先理解的一件事：增益和 tally 的参数名要你来绑

一台 HDCU 有约 **3300 个参数**。`ccu-studio` 的参数目录只收录了其中约 250 个
（IP Live / 格式 / 网络那一批），**音频增益和 tally 都不在其中**；
索尼也没有公开完整的参数名表。

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

* **没在真机上跑过。** 代码与静态检查都过，但第一次连你的 CCU 时可能需要调一轮
  —— 内置的「测试连接」和日志就是为这个准备的。
* **tally 能不能拿到，取决于 CCU 是否把 tally 放进参数里。** 这是本 App 唯一一个
  「设计上留了余地」的地方：参数发现页能把候选全列出来，但**如果设备根本没暴露 tally，
  App 也变不出来** —— 那种情况下 tally 的权威来源在切换台或 CNS/MCS 侧，需要另外接一路数据。
* **增益方向 / 单位**由绑定时填的除数与单位决定，App 不假设设备用的是 dB。
* 只处理**参数层**：不做固件升级、不恢复出厂、不改登录密码、不碰网络与 IP Live 配置。
* **演示机位为了跑得快只有约 600 个参数**（真机约 3300），参数名是按 Sony 命名习惯造的，
  不代表真机上的实际名字；它只用来验证 App 自身与练界面。
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
