# DSH Pocket — 移动优先的 DeepSeek Harness 客户端

> 状态：**方案设计阶段（Draft v0.1）** · 尚未开始编码 · 2026-10-12

把电脑上的 DSH 会话带到手机上。**复用 [dsh-tether](https://github.com/zexadev/dsh-tether) 已经跑通的 P2P 传输层（iroh 打洞 / 配对 / 中转 / 逐请求 cookie 注入），把"把 DSH 桌面网页塞进 WebView 再注入 CSS 硬掰成竖屏"这一层换掉，改成一个从零为手机设计的界面。**

- 为什么要换：[docs/WHY-NOT-INJECTION.md](docs/WHY-NOT-INJECTION.md)（含真机截图证据）
- 协议怎么写：[docs/PROTOCOL-NOTES.md](docs/PROTOCOL-NOTES.md)（47 个端点、3 条事件通道、27 条坑）
- 完整方案：[docs/DESIGN.md](docs/DESIGN.md)

## 一句话结论

DSH 的 Web UI 是桌面优先设计的，tether 用 **16 KB 注入 CSS/JS**（实测：CSS 4.7 KB + JS 11.8 KB）、靠 `[class*="_frame"]` 这类**哈希子类名子串**和"用拖拽把手是否存在推断抽屉状态"把它掰成竖屏 —— 这条路在 iOS WebView 上已经实测碎掉（叠字、重绘残留、点击命中与画面不一致），且每次 DSH 改版或换一个改侧栏的插件都可能再碎一次。

**正确的做法是保留传输、重写界面**：手机端直接说 DSH 自己的客户端协议（unary RPC + `/api/remote.mux` WS 多路复用 + `session/follow` / `$events` 流水），UI 只做手机需要的那部分。

## 目录

| 路径 | 内容 |
|---|---|
| [`docs/DESIGN.md`](docs/DESIGN.md) | 架构、复用/替换边界、协议层清单、移动 UI 设计、里程碑、风险 |
| [`docs/WHY-NOT-INJECTION.md`](docs/WHY-NOT-INJECTION.md) | 注入路线的失败分析与真机证据 |
| [`docs/PROTOCOL-NOTES.md`](docs/PROTOCOL-NOTES.md) | 已核对的 DSH 客户端协议事实 + 本机复现方法 |
| [`tools/mint-cookie.cjs`](tools/mint-cookie.cjs) | 在本机为 `127.0.0.1:<port>` 签一个合法会话 cookie（协议 spike 用） |

## 与既有项目的关系

| 项目 | 关系 |
|---|---|
| [zexadev/dsh-tether](https://github.com/zexadev/dsh-tether)（MIT） | **传输层直接复用/分叉**：iroh P2P、6 位配对码、DLP v1 中转协议、电脑侧 cookie 兑换与逐请求注入、手机侧 TCP 代理、多主机管理、本地模式 |
| [jayantTang/DSH_Mobile](https://github.com/jayantTang/DSH_Mobile)（MIT） | **协议文档来源**：`docs/dsh-protocol.md` 是已对活服务器核对过的权威参考；它是原生 SwiftUI 路线，本方案是"同一协议、Web 前端实现" |
| [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) | 上游。本方案**不修改上游**，只作为客户端消费其协议 |

本仓库是独立社区项目，与 DeepSeek 官方无关联。
