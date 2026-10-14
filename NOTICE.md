# 第三方组件与出处声明 / Third-Party Notices

DSH Pocket 是**独立的社区项目**，与 DeepSeek 官方、与下列项目的作者均无隶属关系。
本文件汇总本项目依赖或借鉴的第三方成果及其许可证。

DSH Pocket is an independent community project. It is not affiliated with
DeepSeek or with the authors of the projects listed below.

---

## 1. dsh-tether — 传输层的契约来源

- 上游：<https://github.com/zexadev/dsh-tether>（作者 zexadev）
- 许可证：MIT — `Copyright (c) 2026 zexadev`

DSH Pocket 由 dsh-tether 衍生而来。具体关系：

| 方面 | 本项目的做法 |
|---|---|
| **电脑端插件** | **原样复用、零改动**。使用官方已发布的 `dsh-plugin-tether`（配对、白名单、cookie 兑换与逐请求注入、中转回退）。本仓库不包含它的代码，只在运行时依赖它。 |
| **DLP 线协议** | 以 `tether-core` 的 `Wire` 定义为契约，在 Swift 侧**独立重新实现**（`ios/TetherKit/Sources/TetherKit/TetherWire.swift`）。 |
| **端口派生公式** | 逐位对齐上游 `tether-host` 的实现，并以契约测试锁住（`TetherProxyPortTests`）。 |
| **Apple 平台配置结论** | Info.plist 的 ATS / Local Network 结论来自上游真机实测记录。 |
| **界面层** | **完全不同**：上游是在 WebView 里注入 CSS/JS，本项目是用 SwiftUI 从零重写。见 `docs/WHY-NOT-INJECTION.md`。 |

上游的 MIT 许可证要求在再分发时保留其版权声明 —— **本文件即该声明**：

```
MIT License

Copyright (c) 2026 zexadev

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 2. iroh-ffi — 官方 Swift 绑定（二进制依赖）

- 上游：<https://github.com/n0-computer/iroh-ffi>
- 版本：v1.1.0，由 `ios/scripts/fetch-iroh.sh` 在构建时按 sha256 校验下载
- 许可证：MIT / Apache-2.0（双许可，见上游仓库）

`Iroh.xcframework` 与 `IrohLib.swift` **不入库**，由脚本从上游 release 取得。

## 3. DeepSeek Harness

- 上游：<https://github.com/deepseek-ai/deepseek-harness>
- 本项目只作为**客户端**消费其客户端协议（unary RPC + WS mux + `session/follow`），
  **不改其源码**，也不包含其代码。

## 4. DSH_Mobile — 协议事实来源

- 上游：<https://github.com/jayantTang/DSH_Mobile>
- 仅把其整理的协议文档与端点目录当作**事实核对来源**；按 ADR-0005 的约定
  **不复制其代码**。
