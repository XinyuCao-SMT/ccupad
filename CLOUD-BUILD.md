# 云端编译 + Windows 侧载（保姆级）

Windows 上**编译不了** iOS/iPadOS 应用（需要 Apple SDK，只能在 macOS 上跑）。
但你不需要买 Mac：用 GitHub 免费的 macOS 虚拟机编出**未签名 IPA**，
再在本机用你自己的 Apple ID 签名装进 iPad。

整个过程约 15 分钟，之后每次改代码只要重跑 Actions 再侧载即可。

---

## 0 · 需要准备

| 需要 | 说明 |
| --- | --- |
| 一个 GitHub 账号 | 公开仓库跑 macOS 构建**完全免费不限量** |
| 一个 Apple ID | 免费账号即可；只是签名 **7 天过期** |
| iTunes | 必须用 [Apple 官网下载版](https://www.apple.com/itunes/)，**不要用 Microsoft Store 版** —— 侧载工具要靠它提供的 Apple 设备驱动 |
| Sideloadly | <https://sideloadly.io/>（或 AltStore） |
| 本机装 Node.js | 只用来跑推送脚本；`node -v` 能出版本号即可 |

---

## 1 · 建仓库

两种方式，任选：

**A. 网页建（最直观）**

GitHub 右上角 **+ → New repository** → 名字例如 `ccupad` → 选 **Public** → Create。

**B. 让脚本建**

推送脚本可以顺手把仓库建好（见第 2 步的 `--create`）。

---

## 2 · 把代码推上去（并让云端编译）

### 一条命令（推荐）

```powershell
cd E:\harness\CCUPad

# 1) 做 token：GitHub → Settings → Developer settings → Personal access tokens
#    → Tokens (classic) → Generate new token → 勾 "repo" → 复制
set GH_TOKEN=ghp_你的token

# 2) 一条命令：建仓库 → 推代码 → 等云编译 → 下载并解压出 IPA
node tools/publish.mjs 你的用户名/ccupad --create
```

跑完在 `dist\ipa\CCUPad-unsigned.ipa` 拿到**未签名 IPA**，接着看第 4 节侧载即可。

`publish.mjs` 会自己判断这次提交有没有触发构建（工作流本来就在 push 时触发），
所以不会白跑两次；万一只改了文档没命中触发条件，它会手动触发一次。

### 手动方式

```powershell
set GH_TOKEN=ghp_你的token

# 只推送（--create 表示仓库不存在就建）
node tools/push-via-api.mjs 你的用户名/ccupad --create
```

然后到仓库页面：**Actions** → 左侧 **Build unsigned IPA** → **Run workflow**
（分支 `main`，配置 `Release`）→ 4–6 分钟后在运行页底部 **Artifacts** 下载
`CCUPad-unsigned-ipa`，解压得到 `CCUPad-unsigned.ipa`。

> 为什么有推送脚本：有些网络下 `github.com:443` 连不通（连接被重置），
> 但 `api.github.com:443` 正常，于是 `git push` 直接失败。
> 这个脚本用 REST API 逐个重放提交，行为等价于 `git push`（快进，不强制覆盖）。
> **本机实测两个域名都可达**，所以普通 `git remote add` + `git push` 同样可以用。
>
> Token 只在本机用，不会进仓库。

---

## 3 · 云端编译

1. 打开仓库页面 → **Actions** 标签。
2. 左侧选 **Build unsigned IPA** → 右侧 **Run workflow**
   → 分支选 `main` → 配置选 `Release` → **Run workflow**。
3. 等 4–6 分钟（第一次稍久）。绿勾表示成功。
4. 点进这次运行，页面底部 **Artifacts** 里下载 **CCUPad-unsigned-ipa**，解压得到
   `CCUPad-unsigned.ipa`（**未签名**，必须自己签才能装）。

**失败了怎么办**：页面顶部 **Summary** 会直接列出 `error:` 摘要，把那段发回给我即可定位。
另有一个 **build-log** 工件，里面是完整编译日志。

工作流也会顺手在云上跑一遍静态自检（`tools/check-sources.mjs`），
用来提前暴露「新增了源文件但忘了重新生成工程」这类问题。

---

## 4 · 侧载到 iPad

1. iPad 用**数据线**连电脑，iPad 上点「信任此电脑」并输入锁屏密码。
2. 打开 **Sideloadly**，把 `CCUPad-unsigned.ipa` 拖进窗口。
3. **Apple ID 填自己的**（免费账号即可），Start。
   中途会要求输入一次 Apple ID 密码 —— 这是本机 Sideloadly 在向 Apple 申请签名，
   密码不经过 GitHub。
4. **iPadOS 16 及以上**：侧载完成后「设置 → 隐私与安全性」里会出现**开发者模式**，
   打开它并**重启 iPad**（这一步不做，App 打不开）。
5. 「设置 → 通用 → VPN 与设备管理 → 开发者 App」里点信任。
6. 回到桌面，`CCUPad` 可以打开了。

**免费 Apple ID 的限制**：每 **7 天**要重新签一次，同时最多 3 个自签 App。
过期后**重新侧载一次即可，IPA 不用重新编译**。
想省事可以上 AltStore + AltServer（装在 Windows 上，同一 Wi-Fi 下自动续签）。

---

## 5 · 装完第一件事：允许「本地网络」

打开 App 后，第一次连 CCU 时系统会弹**「CCUPad 想要查找并连接到本地网络上的设备」**，
必须点**允许**。

不点允许（或之前误点过拒绝），发给 CCU 的包会被系统**静默丢弃** ——
表现是「一直连不上，而且看不到任何错误信息」。
如果误拒过，App 不会再弹第二次，要去
**设置 → 隐私与安全性 → 本地网络 → 打开 CCUPad**。

---

## 6 · 常见问题

| 现象 | 原因 / 处理 |
| --- | --- |
| Actions 报「找不到 CCUPad.xcodeproj」 | 代码没推全。仓库顶层应当能看到 `CCUPad/` 目录，里面有 `CCUPad.xcodeproj` 与源码子目录 |
| 编译报 `cannot find type 'X' in scope` | 新增了源文件但没重新生成工程：本机 `cd CCUPad && node tools/generate-xcodeproj.mjs`，提交后再推 |
| 编译报 `invalid redeclaration` | 两个文件里定义了同名类型，跑 `node tools/check-sources.mjs` 会直接点出来 |
| Sideloadly 报 `SSLEOFError developerservices2.apple.com` | 系统代理（Clash / Verge 等）打断了 Apple 的 TLS 握手。**侧载前关掉系统代理**，或给 `*.apple.com` 配 DIRECT |
| 装上了但打不开 / 闪退 | 没开开发者模式；或签名过期（7 天）——重新侧载 |
| App 里连不上 CCU，没有任何报错 | 本地网络权限没给（见第 5 节）；或 iPad 与 CCU 不在同一网段 |
| App 里有报错但看不懂 | 到「设置 → 日志」看完整记录；那一段就是排查的起点 |

---

## 7 · 隐私

* 你的 **Apple ID 只交给本机的 Sideloadly**，不经过 GitHub。
* CCU 密码存在 **iOS Keychain** 里，不进设置文件、不进日志、不进仓库。
* 仓库里不会出现任何现场 IP、账号或配置单。
