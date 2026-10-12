# DSH Pocket — iPhone 上的 DeepSeek Harness 客户端

> 状态：**M0b 已通过 · M1/M2 已完成并对着活宿主验证 · M3/M4 剩真机验收** · 2026-10-12 · v0.3
>
> **传输互通已验证**：Swift 客户端（iroh-ffi 1.1.0）连上本机正在跑的 `dsh-plugin-tether@0.1.20`
> sidecar，完成配对 → 代理流 → 真实 `/api/session/list` → WebSocket mux → `session/follow` 快照。
> 原始输出见 [docs/artifacts/M0B-EVIDENCE.md](docs/artifacts/M0B-EVIDENCE.md)。

把电脑上的 DSH 会话带到 iPhone 上。**原生 Swift + SwiftUI，严格遵循 Apple HIG**；传输层复用已经跑通的 [dsh-tether](https://github.com/zexadev/dsh-tether)（iroh P2P 打洞 / 配对 / 中转 / cookie 注入），**电脑端一行不改**。

---

## 为什么不用"把 DSH 网页塞进手机"这条路

tether 的做法是在手机 WebView 里加载 DSH 自己的网页，再用 **16 KB 注入 CSS/JS** 把它掰成竖屏。这条路在真机上已经实测失败：

| 同一份 HTML（含注入）、同一视口 393px | 结果 |
|---|---|
| Chromium / Playwright-WebKit | ✅ 渲染正确，点击区与标签一致 |
| **iPhone 15 Pro 真机 WebView** | ❌ 导航叠字、标题行消失、**画面与命中区域不一致** |

**真机** vs **WebKit**：

![iPhone 真机](docs/artifacts/iphone-nav-broken.jpg) ![WebKit](docs/artifacts/webkit-nav-ok.jpg)

原因与完整证据见 [docs/WHY-NOT-INJECTION.md](docs/WHY-NOT-INJECTION.md)。

**所以本项目的取舍是**：传输层（iroh、配对、DLP、cookie 注入、代理）**原样保留**；界面层**从零用 SwiftUI 重写**，直接消费 DSH 自己的客户端协议 —— 不再注入任何 CSS，不依赖 DSH 的 DOM，也不再有 WebView 合成问题。

---

## 已经能跑的东西

| | |
|---|---|
| **会话列表** | 按工作区分组、下拉刷新、搜索、左滑归档、长按重命名/复制 ID；空/加载/离线三态 |
| **会话时间线** | `LazyVStack`、turn 分隔、用户气泡、助手卡片（Markdown + 代码块复制 + 推理折叠）、工具调用折叠成一行（符号+状态+耗时，点开看参数与输出）、流式追加、贴底与「跳到最新」、滚到顶自动补历史 |
| **压缩与取代** | `surfaceOp.replace` 按区间重算：被取代的内容收进"已被压缩取代"折叠区，**不会重复显示** |
| **输入区** | 1–6 行自适应、发送/停止同位置形态切换、照片/文件附件、乐观插入（按 `rpcId` 收敛，不出现两条） |
| **审批** | 时间线内卡片 + 本地通知；决策走 DSH 原生 `$events/result`；「稍后」收起 |
| **提问** | 单选 / 多选 / 开放文本，按 `user-questions/request` 的批语义作答 |
| **文件与产物** | 工作区浏览 + 系统 QuickLook；产物卡 + ShareLink |
| **设置与诊断** | 主机管理、通知开关、外观、**协议自检**（直接打 unary + 流）、direct/relay 路径、日志导出 |
| **配对** | 扫码（VisionKit）/ 粘贴整串 / 手输 6 位码；失败按原因码本地化 |

### 自动化验证现状

| 范围 | 命令 | 结果 |
|---|---|---|
| 协议层 `DSHKit` | `cd ios/DSHKit && swift test` | **47 条通过**（含用真实抓包折叠时间线的回归） |
| 传输层 `TetherKit` | `cd ios/TetherKit && swift test` | **27 条通过**（端口公式逐位对齐、线协议文本、配对串解析） |
| App 层 | `bash ios/build.sh --test` | **15 条通过** |
| 对活宿主 | `DSH_LIVE=1 swift test --filter LiveIntegration` | **6 条通过**（unary / `$events` / follow / page） |
| 传输互通 M0b | `cd ios/spikes/M0BInterop && swift run m0b-interop …` | **通过**（见证据文档） |

---

## 方案要点

| | |
|---|---|
| **客户端** | Swift + SwiftUI，iOS 17.5+，无 WebView 参与渲染，除 iroh 官方绑定外无第三方依赖 |
| **传输** | 官方 [iroh-ffi](https://github.com/n0-computer/iroh-ffi)（预编译 xcframework，无需 Rust）+ 约 400 行 Swift 实现的 DLP 线协议 + 本地 TCP 代理 |
| **电脑端** | 直接复用已安装的 `dsh-plugin-tether@0.1.20`：配对、白名单、cookie 兑换与逐请求注入、代理流 —— **零改动** |
| **协议** | 直说 DSH 的客户端协议：unary RPC + `/api/remote.mux` WS 多路复用 + `session/follow`（持久事件 + 实时帧）+ `$events`（世代与 waterfall 审批） |
| **界面验收** | [docs/IOS-DESIGN.md](docs/IOS-DESIGN.md) §11 的 HIG 自检清单（含动态字体 AX1–AX5、VoiceOver、深色模式、44pt 目标） |
| **Android** | 一期不做；方案保留可行性（[DESIGN.md](docs/DESIGN.md) §3.5） |

---

## 文档地图

| 文档 | 什么时候看 |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | **主方案**：架构、复用/替换边界、协议层设计、里程碑、风险 |
| [docs/IOS-DESIGN.md](docs/IOS-DESIGN.md) | 写界面之前必读：导航架构、逐屏规格、设计令牌、无障碍、**M3 自检清单** |
| [docs/TRANSPORT.md](docs/TRANSPORT.md) | 写传输之前必读：iroh Swift API、DLP 线协议、本地代理、Info.plist、故障对照表 |
| [docs/PROTOCOL-NOTES.md](docs/PROTOCOL-NOTES.md) | DSH 客户端协议事实：认证、端点目录（47）、三条事件通道、27 条坑 |
| [docs/PROTOCOL-0.2.0-rc.2.md](docs/PROTOCOL-0.2.0-rc.2.md) | 已在本机实测通过的协议结论 + 待验清单 |
| [docs/WHY-NOT-INJECTION.md](docs/WHY-NOT-INJECTION.md) | 想理解"为什么不沿用 tether 的界面层"时 |
| [docs/ROADMAP.md](docs/ROADMAP.md) | 干活时看这个：M0a/M0b/M1–M4 的可勾选任务与验收标准 |
| [docs/DECISIONS.md](docs/DECISIONS.md) | 改设计之前先看：12 条 ADR 及其后果 |
| [docs/GLOSSARY.md](docs/GLOSSARY.md) | 术语（DSH / sidecar / DLP / waterfall / surfaceOp …） |
| [docs/artifacts/M0B-EVIDENCE.md](docs/artifacts/M0B-EVIDENCE.md) | **传输互通的原始输出与复现命令** |

---

## 快速开始

### 前置条件

| 用途 | 需要 |
|---|---|
| iOS 开发 | macOS + **Xcode 16 或更新**（本机为 Xcode 27）、iOS 17.5+ 真机或模拟器 |
| 跑协议探针 / 工具 | **Node ≥ 22**（本机 24） |
| 真机签名 | 一个 Apple ID（免费个人团队可用，证书 7 天过期） |
| 电脑端 | 已安装 DSH，且已装 `dsh-plugin-tether`（本机已装 `0.1.20`） |
| 构建 App | [xcodegen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`） |

### 第一步：确认电脑端在跑

```bash
# 1) DSH 在 127.0.0.1:19387 监听着
lsof -nP -iTCP:19387 -sTCP:LISTEN

# 2) tether 的 sidecar 在跑（说明插件已加载）
ps -eo pid,command | grep -i tether-host | grep -v grep
```

没有 sidecar 也能开发：`node tools/tether-host-dev.mjs --pair` 会扮演插件把 sidecar 起起来
（含 cookie 交接），用于传输层回归与 M0b 验证。

### 第二步：跑一次协议探针（不需要手机、不需要 iroh）

```bash
node spikes/m0-probe.mjs unary session/list '{"_request":{}}'   # 列出会话，看真实数据
node spikes/m0-probe.mjs events 10                              # 打开 $events（首帧应是 ready）
node spikes/m0-probe.mjs follow <sessionId> 10                  # 会话流（首帧应是 snapshot）

node tools/capture-session.mjs list                             # 抓一份真实帧序列当测试样本
```

零依赖。默认打 `127.0.0.1:19387`，可用 `DSH_AUTHORITY` 覆盖。它靠 [tools/mint-cookie.cjs](tools/mint-cookie.cjs) 现签会话 cookie（读 `~/.dsh/.credentials.yaml`，**不会打印密钥**）。

### 第三步：把 App 跑起来

```bash
bash ios/scripts/fetch-iroh.sh     # 一次：取 iroh 的预编译部件（133 MB，不入库）
bash ios/build.sh --run            # 构建 + 装进模拟器 + 启动
bash ios/build.sh --test           # 15 条 App 层单测
bash scripts/install-device.sh     # 装到真机（含证书续期提示）
```

**DEV-DIRECT（不需要手机、不需要 iroh）**：起 `node tools/dev-proxy.mjs`，然后在 App 的
设置里打开「开发直连」（或 `xcrun simctl spawn booted defaults write cc.zexa.dshpocket
settings.devDirect -bool YES`）。协议层看到的与真机模式**完全同构**。

---

## 目录结构

```
dsh-pocket/
  README.md
  docs/            # 见上方"文档地图"；artifacts/ 放证据与截图
  ios/
    project.yml           # xcodegen 工程定义（App + 三个工程内静态框架）
    build.sh              # 一条命令构建 / 单测 / 跑起来（含受限沙箱的环境开关）
    DSHPocket/            # App：App / DesignSystem / Features / Resources
    DSHPocketTests/       # App 层单测（15 条）
    DSHKit/               # SwiftPM：DSH 客户端协议层（47 条单测）
    TetherKit/            # SwiftPM：iroh 封装 + DLP + 本地代理（27 条单测）
    spikes/M0BInterop/    # M0b 互通验证可执行程序
    scripts/              # fetch-iroh.sh · gen-strings.py · sync-xcodeproj-packages.mjs
    vendor/               # iroh 部件（不入库，由脚本取）
  tools/
    mint-cookie.cjs       # 本机签发会话 cookie
    dev-proxy.mjs         # DEV-DIRECT 用的注入 cookie 的本地代理（HTTP + WS）
    tether-host-dev.mjs   # 不开桌面端也能起 sidecar（扮演插件的 cookie 交接）
    capture-session.mjs   # 抓真实 follow 帧序列，落成解码器回归样本
  spikes/
    m0-probe.mjs          # 零依赖协议探针
  scripts/
    install-device.sh     # 真机构建 + 装机 + 描述文件续期提示
```

---

## 与其它项目的关系（全部 MIT，保留版权声明）

| 项目 | 我们取什么 |
|---|---|
| [zexadev/dsh-tether](https://github.com/zexadev/dsh-tether) | **电脑端原样复用**；DLP 线协议与端口派生公式作为契约对照；真机实测的 Info.plist 结论 |
| [jayantTang/DSH_Mobile](https://github.com/jayantTang/DSH_Mobile) | 权威协议文档与端点目录（**代码不复制**，见 ADR-0005） |
| [n0-computer/iroh-ffi](https://github.com/n0-computer/iroh-ffi) | 官方 Swift 绑定（v1.1.0，预编译 xcframework） |
| [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) | 上游；只作为客户端消费其协议，不改源码 |

本仓库是独立社区项目，与 DeepSeek 官方、与上述项目的作者均无隶属关系。

---

## 安全边界（如实告知）

1. 端到端加密走 iroh；打洞成功时不经第三方，回退中转时中转只见密文；
2. 配对码 6 位、10 分钟、3 次尝试；配对后访问权由手机公钥决定；
3. **电脑端已知边界**：已经能在你电脑上执行代码的人可以自签配对码、把自己配成"手机"；
4. **手机端已知边界**：App 内的本地代理只监听 `127.0.0.1`，但手机上其它 App 可以连它，且端口可由主机 ID 推算。

细节见 [docs/TRANSPORT.md](docs/TRANSPORT.md) §8。**不要把本 App 用在你同时跑不可信代码的电脑上。**

---

## 给开发者的两条环境提示

1. **受限沙箱**（容器、CI、agent 会话）里构建 App 需要
   `DSH_POCKET_SWIFT_FLAGS="-disable-sandbox"`：Swift 编译器的宏插件宿主进程不能再套一层
   `sandbox-exec`，否则报 `swift-plugin-server produced malformed response`，
   表现成一排莫名其妙的 `cannot find '$xxx' in scope`。`ios/build.sh` 已经把它做成环境变量。
2. **`xcodegen` 只在生成时 glob 源文件** —— 新增 `.swift` 之后必须重跑
   `bash ios/build.sh`（或 `xcodegen generate`），否则新文件不进 target。
