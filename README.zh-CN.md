# DSH Pocket

**把电脑上的 `dsh` 会话带到 iPhone 上 —— 原生界面，点对点直连，中间没有服务器。**

DSH Pocket 是 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的原生 SwiftUI 客户端。
它通过 [iroh](https://www.iroh.computer/) 直接连到**你自己电脑上**正在跑的 `dsh`：
打洞成功时数据不经过任何第三方；打洞失败时回退到中转，而中转只看得见密文。
不需要端口转发、不需要 VPN、不需要注册账号，也没有我们要维护的服务器。

[English README](README.md)

[![ci](https://github.com/UnsplashZ/dsh-pocket/actions/workflows/ci.yml/badge.svg)](https://github.com/UnsplashZ/dsh-pocket/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/UnsplashZ/dsh-pocket?sort=semver)](https://github.com/UnsplashZ/dsh-pocket/releases)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![platform](https://img.shields.io/badge/iOS-17.5%2B-black)

---

## 现状

| | |
|---|---|
| **版本** | v0.3.0 —— 首个公开版本 |
| **分发方式** | **只提供未签名的 IPA**，安装时用你自己的 Apple ID 重签。见[安装](#安装未签名-ipa需自签) |
| **电脑端** | **一行不改**。直接用上游的 `dsh-plugin-tether` |
| **已完成并验证** | 会话列表、时间线、输入区、审批、提问、文件与产物、设置、配对 —— 都对着活着的 DSH 宿主跑过 |
| **还没做** | 真机逐项过 HIG 自检清单（VoiceOver、动态字体 AX1/AX3/AX5、Increase Contrast）；审批通知上的三个操作按钮 |

## 截图

| 时间线 | 设置 | 首次启动 |
|---|---|---|
| ![时间线](docs/artifacts/screenshots/02-timeline.png) | ![设置](docs/artifacts/screenshots/03-settings.png) | ![欢迎页](docs/artifacts/screenshots/04-welcome.png) |

![英文界面](docs/artifacts/screenshots/05-timeline-english.png)

_截图取自 iOS 模拟器。界面中英双语，外观跟随系统。_

---

## 安装（未签名 IPA，需自签）

从 [Releases](https://github.com/UnsplashZ/dsh-pocket/releases) 下载
`DSHPocket-<版本>-unsigned.ipa`，用你自己的 Apple ID 重签即可 —— **免费 Apple ID 就够了**
（签名 7 天有效；付费开发者账号是 1 年）。最省事的是 [Sideloadly](https://sideloadly.io/)，
AltStore / SideStore、Xcode、TrollStore 也都行。

**完整步骤（含 7 天续签循环与排障）：[docs/INSTALL-UNSIGNED-IPA.md](docs/INSTALL-UNSIGNED-IPA.md)**

### 为什么发未签名的包

签名过的 IPA 只能装在**那个签名账号**授权的设备上。发签好名的包，要么对你没用，
要么就得把别人的开发者证书塞进公开分发包里 —— 对方有权（也应当）吊销它，
于是所有装了的人一起失效。所以 Release 里只有 App 本体，签名在你的机器上用你的身份完成。
下载后可以核对校验和：

```bash
shasum -a 256 -c DSHPocket-0.3.0-unsigned.ipa.sha256
```

### 装之前请确认

1. iPhone 上是 **iOS 17.5 或更新**。
2. **电脑上已安装并运行 DSH**，且装了上游的 tether 插件：
   ```bash
   dsh plugin install dsh-plugin-tether   # 0.1.20 或更新
   ```
3. 两台设备在什么网络都行 —— 同一个 Wi-Fi 最快，跨网络、走蜂窝也都能用。

---

## 为什么不用"把 DSH 网页塞进手机"这条路

把桌面 UI 搬上手机最省事的做法，是在 WebView 里加载那个 UI 并注入 CSS 让它适配竖屏。
上游项目就是这么做的 —— 而它在**真机上已经实测失败**，而且是可复现的：

| 同一份 HTML（含注入）、同一视口 393px | 结果 |
|---|---|
| Chromium / Playwright-WebKit | ✅ 渲染正确，点击区与标签一致 |
| **iPhone 15 Pro 真机 WebView** | ❌ 导航叠字、标题行消失、**画面与命中区域不一致** |

| iPhone 真机 | 桌面的 WebKit |
|---|---|
| ![真机](docs/artifacts/iphone-nav-broken.jpg) | ![WebKit](docs/artifacts/webkit-nav-ok.jpg) |

完整证据见 [docs/WHY-NOT-INJECTION.md](docs/WHY-NOT-INJECTION.md)。

所以本项目的取舍是：**难的那部分（传输）原样保留，不工作的那部分（界面层）换掉**。

- **传输层：原样复用。** iroh 打洞、配对、中转回退、cookie 注入与本地代理都沿用上游设计；
  电脑端的插件完全不动。
- **界面层：用 SwiftUI 从零重写。** 直接消费 DSH 自己的客户端协议，不注入任何 CSS，
  不依赖 DSH 的 DOM，也不再有 WebView 的合成问题。

---

## 它是怎么工作的

```
┌─ iPhone ────────────────────────────────┐        ┌─ 你的电脑 ──────────────────────┐
│  SwiftUI  (DSHPocket)                   │        │                                 │
│      │  DSH 客户端协议                  │        │   dsh  （一行不改）             │
│      ▼                                  │        │     ▲                           │
│  DSHKit      unary RPC · /api/remote.mux│        │     │ 回环 + cookie              │
│      │       session/follow · $events   │        │     │                           │
│      ▼                                  │        │  dsh-plugin-tether（一行不改）  │
│  TetherKit   本地 TCP 代理 127.0.0.1    │        │     ▲                           │
│      │                                  │        │     │ DLP over iroh QUIC        │
│  IrohLib     iroh endpoint              │◄──────►│  tether sidecar（iroh endpoint）│
└─────────────────────────────────────────┘  iroh  └─────────────────────────────────┘
                                          直连 / 中转
```

| 层 | 是什么 |
|---|---|
| `ios/DSHPocket` | App 本体：SwiftUI，iOS 17.5+，除 iroh 官方绑定外无第三方依赖 |
| `ios/DSHKit` | DSH 客户端协议层：RPC 客户端、WS mux 客户端、`session/follow` 投影、时间线构建。只用 Foundation + URLSession，不知道 iroh 也不知道 SwiftUI —— 所以它能在 macOS 上直接 `swift test` |
| `ios/TetherKit` | iroh endpoint + 约 400 行 Swift 实现的 DLP 线协议 + 回环 TCP 代理，于是上层只管对 `127.0.0.1` 说普通 HTTP |
| `ios/vendor`（取来不入库） | 官方 [iroh-ffi](https://github.com/n0-computer/iroh-ffi) v1.1.0 的预编译 xcframework 与 Swift 绑定，版本与 sha256 钉在 `ios/scripts/fetch-iroh.sh` |
| 电脑端 | 上游的 `dsh-plugin-tether`，原样使用 |

产品上只有**一条**连接方式：iroh。公网可用、打洞成功时不经第三方、回退中转只见密文 ——
已经覆盖全部真实场景，所以设置里不再暴露"连接方式"这个开关。
开发界面时（模拟器、不需要手机、不需要配对）另有**开发直连网关**，
只在 DEBUG 构建里通过 `defaults` 打开（见 `tools/direct-gateway.mjs`）。

---

## 现在能做什么

**会话列表** —— 按工作区分组、下拉刷新、本地与主机历史搜索、左滑归档、长按重命名/复制 ID；
空 / 加载 / 离线三态；连接状态与重连。

**时间线** —— 轮次折叠（带完成动画与自动贴底）、用户气泡、助手卡片（Markdown、表格、
可复制代码块、推理折叠）、工具调用折叠成一行（符号 + 状态 + 耗时，可展开看参数与输出）、
子代理卡片、流式追加、「跳到最新」、滚到顶自动补历史。

**压缩与取代** —— `surfaceOp.replace` 按区间重算：被取代的内容收进"已被压缩取代"折叠区，
**不会重复显示**。

**输入区** —— 1–6 行自适应、发送/排队/插队/停止聚合成一个按钮、照片与文件附件、
乐观插入（按 `rpcId` 收敛，不出现两条）、`/` 命令菜单（宿主 6 条 + 本地动作 4 个）、
`@` 引用（文件与会话）、排队消息面板（可展开、可编辑/删除/插队）、上下文占用条、会话统计、
工作状态与实时计时器。

**审批与提问** —— 时间线内卡片 + 本地通知，决策走 DSH 原生 `$events/result`；
单选 / 多选 / 开放文本提问。

**文件与产物** —— 工作区浏览 + 系统 QuickLook；产物卡 + ShareLink。

**设置** —— 主机管理、电脑端默认模型与思考等级、提供商与模型
（**密钥只写不读：能存进去，但界面永远不会回显**）、插件包开关、定时提醒、缓存管理、归档、
通知、外观（主题 / 字号 / 原始事件 / 默认展开思考）、诊断、许可、隐私。

**配对** —— 扫码（VisionKit）/ 粘贴整串 / 手输 6 位码；失败按原因码本地化。

**无障碍与本地化** —— 动态字体 AX1–AX5、VoiceOver 标签、深色模式、44pt 触达目标；
440 条文案，zh-Hans 与 en 全覆盖。

---

## 自动化验证现状

| 范围 | 命令 | 结果 |
|---|---|---|
| 协议层 `DSHKit` | `cd ios/DSHKit && swift test` | **96 条通过**（另有 20 条活宿主测试在无宿主时跳过） |
| 传输层 `TetherKit` | `cd ios/TetherKit && swift test` | **33 条通过**（端口公式与 Rust 实现逐位对齐、线协议文本、配对串解析） |
| App 层 | `bash ios/build.sh --test` | **40 条** |
| 对着**活宿主** | `DSH_LIVE=1 swift test --filter LiveIntegration` | **20 条通过**（unary、`$events`、follow、page、prompt/cancel/selectModel 实跑） |
| 传输互通 M0b | `cd ios/spikes/M0BInterop && swift run m0b-interop …` | **通过** —— 原始输出见 [docs/artifacts/M0B-EVIDENCE.md](docs/artifacts/M0B-EVIDENCE.md) |

以上全部由 CI 在每次 push 与 PR 上跑（[`.github/workflows/ci.yml`](.github/workflows/ci.yml)），
并且 CI **顺带把未签名 IPA 打一遍** —— 发布路径每次改动都被走过，而不是等打 tag 那天才发现坏了。

### 不需要手机就能验证协议

```bash
node spikes/m0-probe.mjs unary session/list '{"_request":{}}'   # 列出会话，看真实数据
node spikes/m0-probe.mjs events 10                              # 打开 $events（首帧应是 ready）
node spikes/m0-probe.mjs follow <sessionId> 10                  # 会话流（首帧应是 snapshot）
```

零依赖。默认打 `127.0.0.1:19387`，可用 `DSH_AUTHORITY` 覆盖。它靠
[tools/mint-cookie.cjs](tools/mint-cookie.cjs) 现签会话 cookie（读 `~/.dsh/.credentials.yaml`，
**不会打印密钥**）。

---

## 从源码构建

### 前置条件

| 用途 | 需要 |
|---|---|
| iOS 开发 | macOS + **Xcode 16 或更新**、iOS 17.5+ 真机或模拟器 |
| 生成工程 | [xcodegen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`） |
| 协议探针 / 工具 | **Node ≥ 22** |
| 电脑端 | 已安装 DSH，且装了 `dsh-plugin-tether` **0.1.20+** |

### 模拟器

```bash
bash ios/scripts/fetch-iroh.sh   # 一次：取 iroh 的预编译部件（约 42 MB，不入库）
bash ios/build.sh                # 构建
bash ios/build.sh --run          # 构建 + 装进已启动的模拟器 + 启动
bash ios/build.sh --test         # App 层单测
```

`ios/build.sh` 会自动挑一台可用的 iPhone 模拟器 —— 机型名跟着 Xcode 版本变，
写死会让脚本在别人机器上直接失败。

### 真机

```bash
bash ios/build.sh --device       # 真机构建（需要配好你的 team）
bash scripts/install-device.sh   # 装到已连接的设备并启动
```

### 自己打一个未签名 IPA

```bash
bash ios/scripts/make-ipa.sh                       # 版本号取 ios/VERSION
bash ios/scripts/make-ipa.sh --version 0.3.1 --build 42
# → dist/DSHPocket-0.3.1-unsigned.ipa（附 .sha256 与构建日志）
```

脚本会关掉签名（是**四个**开关，不是一个），然后**断言**产物：`Info.plist` 里的版本号与
构建号、`Payload/` 结构、可执行文件存在、以及这个包**确实没有任何签名身份**。
被真实证书签过的产物是硬失败 —— 那等于把构建者的证书泄漏进公开下载。

---

## 发版与版本号管理

**`ios/VERSION` 是唯一真源**，`ios/project.yml` 由它同步，别的地方都不要手改。

```bash
bash ios/scripts/version.sh get              # 0.3.0
bash ios/scripts/version.sh tag              # v0.3.0
bash ios/scripts/version.sh set 0.4.0 12     # 改版本号 + 构建号，同步 project.yml
bash ios/scripts/version.sh bump minor       # 0.3.0 → 0.4.0
bash ios/scripts/version.sh check v0.4.0     # 断言一致（CI 用）
```

构建号（`CURRENT_PROJECT_VERSION`）**故意不属于版本内容**：同一个版本会被反复构建。
本地沿用 `project.yml` 里的值，CI 用 `github.run_number` 覆盖。

### 两条流水线

| 流水线 | 触发 | 做什么 |
|---|---|---|
| [`ci.yml`](.github/workflows/ci.yml) | push 到 `main`、PR、手动 | 文案完整性与版本号一致性检查 · 库单测 · App 单测 · 未签名 IPA（作为 CI 产物） |
| [`release.yml`](.github/workflows/release.yml) | tag `v*`，或手动 | **唯一的发版入口**。校验 tag 与 `ios/VERSION` 一致 → 打未签名 IPA → 建 GitHub Release（挂上 IPA、`.sha256` 与取自 `CHANGELOG.md` 的发布说明）。手动触发时还可以顺手递增版本号（`bump` / `version` 输入）并替你提交 |

> 版本号递增**故意**和发版放在同一条流水线里：用仓库自带的 `GITHUB_TOKEN` 推出去的 tag
> **不会再触发别的 workflow**（GitHub 防止递归的规则）。拆成两条的话，bump 推完 tag 就静默没有下文 ——
> 看起来一切成功，Release 页面却什么都没有。合在一条里，tag 只是个标签，后面几步在本次运行内继续走，
> 不用 PAT，也不用 `gh workflow run` 那套绕法。

### 发一个版本

1. 把 [CHANGELOG.md](CHANGELOG.md) 里 `Unreleased` 的内容整理进新的 `## [X.Y.Z]` 一节，合并。
   （没有这一节，流水线会拒绝发版。）
2. Actions → **release** → Run workflow → 选 `patch` / `minor` / `major`
   （或直接填一个 `version`）。它会递增 `ios/VERSION`、同步 `project.yml`、提交、打 tag、打包并发布。
3. 也可以手动来：`bash ios/scripts/version.sh bump minor` → 提交 → `git tag v0.4.0`
   → `git push origin v0.4.0`，tag 推送会跑同一条流水线。

---

## 目录结构

```
dsh-pocket/
  README.md · README.zh-CN.md · CHANGELOG.md · LICENSE · NOTICE.md
  .github/workflows/       ci · release
  docs/                    设计文档与证据；artifacts/ 放证据与截图
  ios/
    VERSION                ← 版本号的唯一真源
    project.yml            xcodegen 工程定义（App + 三个工程内静态框架）
    build.sh               一条命令构建 / 单测 / 跑起来
    DSHPocket/             App：App / DesignSystem / Features / Resources
    DSHPocketTests/        App 层单测（40 条）
    DSHKit/                SwiftPM：DSH 客户端协议层（116 条单测）
    TetherKit/             SwiftPM：iroh 封装 + DLP + 本地代理（33 条单测）
    scripts/               fetch-iroh.sh · make-ipa.sh · version.sh · select-xcode.sh · pick-simulator.sh
    spikes/M0BInterop/     M0b 互通验证可执行程序
    vendor/                iroh 部件（不入库，由脚本取）
  tools/                   电脑端辅助工具（签 cookie、直连网关、抓包、查看配对状态）
  spikes/m0-probe.mjs      零依赖协议探针
  scripts/                 changelog-section.mjs · install-device.sh
```

### 文档地图

| 文档 | 什么时候看 |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | **主方案**：架构、复用/替换边界、协议层设计、里程碑、风险 |
| [docs/IOS-DESIGN.md](docs/IOS-DESIGN.md) | 写界面之前必读：导航架构、逐屏规格、设计令牌、无障碍、自检清单 |
| [docs/TRANSPORT.md](docs/TRANSPORT.md) | 写传输之前必读：iroh Swift API、DLP 线协议、本地代理、Info.plist、故障对照表 |
| [docs/PROTOCOL-NOTES.md](docs/PROTOCOL-NOTES.md) | DSH 客户端协议事实：认证、端点目录、三条事件通道、27 条坑 |
| [docs/WHY-NOT-INJECTION.md](docs/WHY-NOT-INJECTION.md) | 想理解"为什么不沿用上游的界面层"时 |
| [docs/DECISIONS.md](docs/DECISIONS.md) | 改设计之前先看：12 条 ADR 及其后果 |
| [docs/ROADMAP.md](docs/ROADMAP.md) | 干活时看这个：里程碑的可勾选任务与验收标准 |
| [docs/INSTALL-UNSIGNED-IPA.md](docs/INSTALL-UNSIGNED-IPA.md) | 安装与自签 |
| [docs/artifacts/M0B-EVIDENCE.md](docs/artifacts/M0B-EVIDENCE.md) | 传输互通的原始输出与复现命令 |

---

## 连接方式（进阶）

### 两台设备已经在同一个 tailnet 里，iroh 会走 Tailscale 吗？

**会，而且算「直连」。** 依据不是推测，是 iroh 二进制里的事实：它会**枚举所有网卡**并订阅地址变化

```
netwatch::interfaces::Interface / ::State
netdev::os::macos::sc::SCInterface          ← macOS 用 SystemConfiguration 枚举
iroh::socket::transports::Transports::local_addrs_watch
n0_watcher                                   ← 网卡变化监听
```

所以 Tailscale 的 `utun` 与它上面的 `100.x.y.z` **也是候选地址之一**。两端都在 tailnet 里时，
发往 `100.x` 的探测能通 → iroh 就选这条路，`paths()` 报 `isRelay: false`。

三点要说清楚：

1. **不是"iroh 认识 Tailscale"，而是"Tailscale 的地址恰好可达"。**
   iroh 并不知道那是 Tailscale，它只是把候选地址都试一遍。所以 tailnet 只是**多了一条可用的直连路径**，
   不会改变它的行为。
2. **怎么确认走的是哪条**：App 的「设置 → 诊断」里有 `加密路径`（直连 / 中转）与 `远端` 地址。
   看到 `100.x.y.z` 就是走的 Tailscale。
3. **电脑上常驻 TUN 类代理（sing-box / Clash）时要想清楚路由**：Tailscale 自己会为
   `100.64.0.0/10` 装一条明细路由，按最长前缀匹配它会赢过 TUN 的 `0/1 + 128/1`，
   也就是说 **Tailscale 流量通常不会进 sing-box**。但如果你的分流规则显式把 tailnet 段
   也代理进去了（UDP 再套一层 UDP），打洞就会变脆 —— 那种情况下关掉代理，或者
   在分流里把 `100.64.0.0/10` 设为直连。

### 开发者模式（不在设置页里）

模拟器里开发界面/协议时不需要真机、也不需要配对，所以保留了"直连网关"这条路，
但**只在 DEBUG 构建里通过 defaults 打开**：

```bash
# 模拟器 DEV-DIRECT：打本机回环上的 dev 网关
node tools/direct-gateway.mjs &
xcrun simctl spawn booted defaults write cc.unsplashz.dshpocket settings.transportMode -string devDirect

# Tailscale / 局域网直连（需要令牌，绑非回环地址时强制要求）
node tools/direct-gateway.mjs --host 100.x.y.z --token <随机串>
xcrun simctl spawn booted defaults write cc.unsplashz.dshpocket settings.transportMode -string directGateway
xcrun simctl spawn booted defaults write cc.unsplashz.dshpocket settings.gatewayURL -string http://100.x.y.z:8788
xcrun simctl spawn booted defaults write cc.unsplashz.dshpocket settings.gatewayToken -string <随机串>
```

打开后设置页最上面会出现一条「调试」提示，一键改回 iroh。

> ⚠️ 直连网关会代替你向 DSH 认证 —— **谁能连上它，谁就等于拿到了你的 DSH**。
> 所以绑非回环地址时它强制要求 `--token`；公网使用请再套一层 TLS 反向代理。

---

## 安全边界（如实告知）

1. 端到端加密走 iroh；打洞成功时不经第三方，回退中转时中转只见密文；
2. 配对码 6 位、10 分钟、3 次尝试；配对后访问权由手机公钥决定；
3. **电脑端已知边界**：已经能在你电脑上执行代码的人可以自签配对码、把自己配成"手机"；
4. **手机端已知边界**：App 内的本地代理只监听 `127.0.0.1`，但手机上其它 App 可以连它，
   且端口可由主机 ID 推算。

细节见 [docs/TRANSPORT.md](docs/TRANSPORT.md) §8。**不要把本 App 用在你同时跑不可信代码的电脑上。**

---

## 出处与许可

MIT，见 [LICENSE](LICENSE)。第三方组件与必须随附的上游版权声明在
[NOTICE.md](NOTICE.md)。

| 项目 | 我们取什么 |
|---|---|
| [zexadev/dsh-tether](https://github.com/zexadev/dsh-tether) | **本项目的上游**。电脑端原样复用；DLP 线协议与端口派生公式作为契约对照；真机实测的 Info.plist 结论。界面层**不复用** |
| [n0-computer/iroh-ffi](https://github.com/n0-computer/iroh-ffi) | 官方 Swift 绑定（v1.1.0，预编译 xcframework） |
| [jayantTang/DSH_Mobile](https://github.com/jayantTang/DSH_Mobile) | 权威协议文档与端点目录（**代码不复制**，见 ADR-0005） |
| [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) | 上游；只作为客户端消费其协议，不改源码 |

本仓库是独立社区项目，与 DeepSeek 官方、与上述项目的作者均无隶属关系。

---

## 给开发者的两条环境提示

1. **受限沙箱**（容器、CI、agent 会话）里构建 App 需要
   `DSH_POCKET_SWIFT_FLAGS="-disable-sandbox"`：Swift 编译器的宏插件宿主进程不能再套一层
   `sandbox-exec`，否则报 `swift-plugin-server produced malformed response`，
   表现成一排莫名其妙的 `cannot find '$xxx' in scope`。`ios/build.sh` 已经把它做成环境变量；
   在同样的环境里跑 `swift test` 则加 `--disable-sandbox`。
2. **`xcodegen` 只在生成时 glob 源文件** —— 新增 `.swift` 之后必须重跑
   `bash ios/build.sh`（或 `xcodegen generate`），否则新文件不进 target。
