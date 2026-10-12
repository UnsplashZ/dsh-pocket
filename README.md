# DSH Pocket — iPhone 上的 DeepSeek Harness 客户端

> 状态：**方案设计完成，进入 M0（协议 spike / 传输互通）** · 2026-10-12 · v0.2

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

## 方案要点

| | |
|---|---|
| **客户端** | Swift + SwiftUI，iOS 17+，无 WebView 参与渲染，除 `IrohLib` 外无第三方依赖 |
| **传输** | 官方 [iroh-ffi](https://github.com/n0-computer/iroh-ffi) Swift 包（预编译 xcframework，无需 Rust）+ 约 400 行 Swift 实现的 DLP 线协议 |
| **电脑端** | 直接复用已安装的 `dsh-plugin-tether@0.1.20`：配对、白名单、cookie 兑换与逐请求注入、代理流 —— **零改动** |
| **协议** | 直说 DSH 的客户端协议：unary RPC + `/api/remote.mux` WS 多路复用 + `session/follow`（持久事件 + 实时帧）+ `$events`（世代与 waterfall 审批） |
| **界面验收** | [docs/IOS-DESIGN.md](docs/IOS-DESIGN.md) §11 的 HIG 自检清单 100% 通过（含动态字体 AX1–AX5、VoiceOver、深色模式、44pt 目标） |
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
| [docs/DECISIONS.md](docs/DECISIONS.md) | 改设计之前先看：9 条 ADR 及其后果 |
| [docs/GLOSSARY.md](docs/GLOSSARY.md) | 术语（DSH / sidecar / DLP / waterfall / surfaceOp …） |

---

## 快速开始

### 前置条件

| 用途 | 需要 |
|---|---|
| iOS 开发 | macOS + **Xcode 16 或更新**（本机为 Xcode 27）、iOS 17+ 真机或模拟器 |
| 跑协议探针 / 工具 | **Node ≥ 22**（本机 24） |
| 真机签名 | 一个 Apple ID（免费个人团队可用，证书 7 天过期） |
| 电脑端 | 已安装 DSH，且已装 `dsh-plugin-tether`（本机已装 `0.1.20`） |

### 第一步：确认电脑端在跑

```bash
# 1) DSH 在 127.0.0.1:19387 监听着
lsof -nP -iTCP:19387 -sTCP:LISTEN

# 2) tether 的 sidecar 在跑（说明插件已加载）
ps -eo pid,command | grep -i tether-host | grep -v grep
```

### 第二步：跑一次协议探针（不需要手机、不需要 iroh）

```bash
node spikes/m0-probe.mjs unary session/list '{"_request":{}}'   # 列出会话，看真实数据
node spikes/m0-probe.mjs events 10                              # 打开 $events（首帧应是 ready）
node spikes/m0-probe.mjs follow <sessionId> 10                  # 会话流（首帧应是 snapshot）
```

零依赖。默认打 `127.0.0.1:19387`，可用 `DSH_AUTHORITY` 覆盖。它靠 [tools/mint-cookie.cjs](tools/mint-cookie.cjs) 现签会话 cookie（读 `~/.dsh/.credentials.yaml`，**不会打印密钥**）。

### 第三步：M0b —— 先证明 Swift 能连上现有 sidecar

这是**最高技术风险**（iroh-ffi 1.1.0 ↔ 宿主 iroh 1.0.3 互通性）。在做任何界面之前，先让一个最小 Swift 程序完成：绑定端点 → 连上电脑端 → 写 `{"type":"hello"}` → 开一条代理流取到 `/api/session/list` 的 200。

步骤与代码骨架见 [docs/TRANSPORT.md](docs/TRANSPORT.md) §1、§4；任务清单见 [docs/ROADMAP.md](docs/ROADMAP.md) 的 M0b。

---

## 目录结构（目标形态）

```
dsh-pocket/
  README.md
  docs/            # 见上方"文档地图"
  ios/
    DSHPocket.xcodeproj
    DSHPocket/     # App：Features / DesignSystem / Resources
    DSHKit/        # SwiftPM：DSH 客户端协议层（RPC / mux / 事件 / 时间线投影）
    TetherKit/     # SwiftPM：iroh-ffi 封装 + DLP + 本地 TCP 代理
  tools/
    mint-cookie.cjs    # 本机签发会话 cookie
    dev-proxy.mjs      # DEV-DIRECT 模式用的注入 cookie 的代理（M0a 待做）
  spikes/
    m0-probe.mjs       # 零依赖协议探针（已可用）
  scripts/
    install-device.sh  # 真机构建 + 装机 + 描述文件续期（M4 待做）
```

> 当前仓库只有 `docs/`、`tools/`、`spikes/`；`ios/` 与 `scripts/` 随 M0b/M4 建立。

---

## 与其它项目的关系（全部 MIT，保留版权声明）

| 项目 | 我们取什么 |
|---|---|
| [zexadev/dsh-tether](https://github.com/zexadev/dsh-tether) | **电脑端原样复用**；DLP 线协议与端口派生公式作为契约对照；真机实测的 Info.plist 结论 |
| [jayantTang/DSH_Mobile](https://github.com/jayantTang/DSH_Mobile) | 权威协议文档与端点目录（**代码不复制**，见 ADR-0005） |
| [n0-computer/iroh-ffi](https://github.com/n0-computer/iroh-ffi) | 官方 Swift 绑定 `IrohLib` |
| [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) | 上游；只作为客户端消费其协议，不改源码 |

本仓库是独立社区项目，与 DeepSeek 官方、与上述项目的作者均无隶属关系。

---

## 安全边界（如实告知）

1. 端到端加密走 iroh；打洞成功时不经第三方，回退中转时中转只见密文；
2. 配对码 6 位、10 分钟、3 次尝试；配对后访问权由手机公钥决定；
3. **电脑端已知边界**：已经能在你电脑上执行代码的人可以自签配对码、把自己配成"手机"；
4. **手机端已知边界**：App 内的本地代理只监听 `127.0.0.1`，但手机上其它 App 可以连它，且端口可由主机 ID 推算。

细节见 [docs/TRANSPORT.md](docs/TRANSPORT.md) §8。**不要把本 App 用在你同时跑不可信代码的电脑上。**
