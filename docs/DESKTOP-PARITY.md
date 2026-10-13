# DSH Pocket × DSH Desktop 能力对照

**日期**：2026-10-13
**桌面端**：DSH 0.2.0-rc.2，`@deepseek-ai/dsh-client-ui-*` 共 **53 个**客户端插件
**手机端**：本仓库 `ios/DSHPocket`（9,820 行 Swift）

---

## 一、结论先说

53 个插件里，**真正值得搬到手机上的只有 8 个**。其余要么已经有了、
要么是桌面壳层（多窗口/侧边栏/快捷键）、要么手机上没意义（用 Finder 打开文件）。

按「值不值得做」排：

| 优先级 | 能力 | 为什么值得 |
|---|---|---|
| **1** | **后台任务面板**（`jobs`） | 唯一一类**跑起来就看不见**的东西。后台 bash 跑着，手机上没有任何入口能看输出或停掉它 |
| **2** | **会话搜索**（`session/search`） | 会话一多就找不到。接口现成，App 没用 |
| **3** | **`/` 命令菜单** | `/compact`（压缩对话）、`/goal`、`/plan`、`/export` 全在命令里。App 只有内部用的 `/permission` |
| **4** | **目标面板**（`goal`） | App 现在只渲染成一行「目标已更新」。暂停/恢复/编辑/清除都做不了 |
| **5** | **`@` 引用**（`reference`） | 引用工作区文件、其他会话、子代理 —— 手机上选文件比打路径强得多 |
| **6** | **定时提醒**（`schedule`） | 服务端 `schedule/{list,update,delete,history,catalog}` 全通。手机上"让电脑到点干件事"很自然 |
| **7** | **上下文明细**（`contextBreakdown`） | `{systemTokens, toolsTokens, messageTokens}` 已经躺在投影里。**最便宜的一个** |
| **8** | **字号调节**（`theme`） | 现在只有跟随系统。桌面端有独立字号 |

---

## 二、逐项对照

图例：**✅ 已有** · **🟡 简版** · **❌ 缺失** · **🚫 不适用**

### 对话与消息

| 桌面插件 | 提供什么 | 手机端 |
|---|---|---|
| `conversation` | Queue／Steer 发送、命令菜单、引用菜单、换行 | 🟡 排队/插队/停止有；**命令菜单和引用菜单没有** |
| `approval` | 越权审批卡片（允许一次／拒绝） | ✅ 含 waterfall 应答 |
| `user-questions` | 选择题卡片、倒计时、跳过 | ✅ 含 waterfall 应答 |
| `message-feedback` | 点赞点踩、反馈分类与详情 | 🟡 赞/踩有；**分类和文字反馈没有** |
| `tool` / `renderer` | 工具调用与结果渲染 | ✅ 通用工具行 + 子代理卡片 |
| `subagent` | 子代理耗时 | ✅ 子代理卡片（可点进去） |
| `deliverables` | 交付物卡片 | ✅ |
| `compaction` | 压缩区间折叠 | ✅ |
| `todo` | 待办列表 | ✅ |
| `skill` | 技能加载中/已加载/失败卡片 | ❌ 技能清单被当注入上下文隐藏了 |
| `trajectory` | 完整轨迹查看器（展开轮次/调用、搜索） | ❌ 手机上价值中等 |
| `plan` | 计划文档预览、侧栏打开 | 🟡 只有一行「已进入计划模式」 |
| `goal` | 目标面板：暂停/恢复/编辑/清除 | 🟡 只有一行「目标已更新」 |
| `workflow-run` | 子代理工作流进度（分阶段、成员） | ❌ |
| `agent-preset` | 会话模式说明与示例 | ✅ 建会话时可选 |
| `model-selection` | 模型选择 | ✅ |
| `permission-presets` | 权限档位 | ✅ |
| `attachment` | 附件 | ✅ |
| `input-trigger` | `@`／`/` 触发候选 | ❌ |

### 面板与侧边栏

| 桌面插件 | 提供什么 | 手机端 |
|---|---|---|
| `jobs` | **后台任务**：列表、实时输出、停止 | ❌ **完全缺失** |
| `sidebar-files` | 工作区文件浏览、自动刷新 | 🟡 只读浏览，无自动刷新 |
| `sidebar-terminal` | 会话工作区里的终端 | 🚫 手机上意义不大 |
| `sidebar-browser` | 内置浏览器 | 🚫 |
| `sidebar-documentpreview` | 文档预览、自动换行、打开方式 | 🟡 Markdown 只读预览 |
| `sidebar` / `sidebar-right` / `layout` | 侧边栏与分栏 | 🚫 桌面壳层 |
| `reference` | 文件／会话／子代理引用 | ❌ |
| `open-in-app` | 用 Finder／编辑器打开 | 🚫 iOS 没有这个概念 |

### 设置

| 桌面插件 | 提供什么 | 手机端 |
|---|---|---|
| `settings-models` | 提供商与模型增删改、密钥 | ✅ 刚做完（密钥只写不读） |
| `settings-plugins` / `plugin-manager` | 插件开关、**安装/卸载** | 🟡 开关有；**安装卸载没有** |
| `settings-plugin-inventory` | 插件清单与包元信息 | 🟡 包级别清单有 |
| `settings-agent-loop` | 并行工具调用数 | ❌ |
| `settings-subagent` | 递归深度、数量上限、子代理模型 | ❌ |
| `settings-web-search` | 搜索提供方与密钥 | ❌ |
| `settings-shell` | 命令超时、输出上限 | ❌ |
| `settings-session-log` | 会话日志 | ❌ |
| `settings-general` / `settings` / `settings-shell`(壳) | 通用设置、更新检查 | 🟡 有诊断页；**更新检查不适用** |
| `settings-account` | 登录、充值、引导问卷 | 🚫 账号相关 |
| `theme` | 浅色/深色/跟随系统、**字号** | 🟡 跟随系统；**字号没有** |
| `shortcuts` | 快捷键 | 🚫 |
| `schedule` | 定时提醒 | ❌ |
| `directory-picker-*` | 目录选择器 | 🟡 用工作区列表代替 |

### 桌面壳层（手机不适用）

`brand-official` · `chat` · `cordis` · `primitives` · `renderer` · `session` ·
`slots` · `workspace`(部分) · `sidebar-*` · `layout` · `shortcuts`

---

## 三、接口可行性（都实测过）

| 能力 | 服务端支持 | 备注 |
|---|---|---|
| `jobs` | `jobs/{list,follow,kill}` | 用 `follow` 拿实时输出 |
| `session/search` | ✅ | App 已有 `listSessions`，加个 search 很轻 |
| 命令 | ✅ `commands` + `session/command` | App 已有 `executeCommand`，只差菜单 UI |
| `goal` | ✅ 投影 `goal` + `/goal` 命令 | 编辑走命令，状态读投影 |
| `schedule` | ✅ `schedule/{catalog,list,history,update,delete}` | 完整 |
| `reference` | 需要 `fileReferences` 命名空间 | 已有 `workspaceFiles/*` 可复用 |
| `contextBreakdown` | ✅ 已在投影里 | **零成本** |
| `agentTeam` | 投影 `agentTeam`（实验性） | `dsh-experimental-*`，先不动 |

---

## 四、这 8 项分别是谁提供的？

**结论：1-8 全部是 DSH 官方能力，没有一项来自第三方插件。**

用 `pluginManager/listBundles` 查的权威分类（不是按包名猜的）。本机 17 个 bundle 分三层：

### 第 1 层 · 核心内置（`@deepseek-ai/dsh-base`，`management-required`，不可禁用）

服务端能力全在这一层：

| 能力 | 模块 |
|---|---|
| 后台任务 | `dsh-jobs-local` · `dsh-tool-jobs` |
| 目标 | `dsh-goal` · `dsh-goal-round-driver` · `dsh-command-goal` |
| 命令 | `dsh-commands` · `dsh-command-feedback` · `dsh-command-compact` |
| 计划模式 | `dsh-plan-mode` |
| **会话搜索** | `dsh-session-query-sqlite` |
| **上下文明细** | `dsh-token-meter`（`contextBreakdown` 由它定义） |
| 技能 | `dsh-skill` · `dsh-skill-filesystem` · `dsh-tool-skill` |

### 第 2 层 · 官方 Web 界面（`@deepseek-ai/dsh-web-app`，`management-required`）

**所有客户端 UI 都在这一层** —— 也就是说这 8 项的手机端实现，本质上是
把 `dsh-web-app` 里对应的那个 React 组件用 SwiftUI 重写一遍：

| 能力 | 模块 |
|---|---|
| 后台任务面板 | `dsh-client-ui-jobs` |
| 目标面板 | `dsh-client-ui-goal` |
| 命令菜单 | `dsh-client-ui-commands` |
| **`@` 引用** | `dsh-client-ui-reference` · `dsh-session-reference` · `dsh-file-reference-local` |
| 触发候选 | `dsh-client-ui-input-trigger` |
| **字号调节** | `dsh-client-ui-theme` |
| 上下文明细 UI | `dsh-client-ui-conversation` |
| 轨迹 / 技能卡片 | `dsh-client-ui-trajectory` · `dsh-client-ui-skill` |

### 第 3 层 · 官方实验性（`@deepseek-ai/dsh-experimental-*`，`optional`）

**8 项里只有「定时提醒」在这一层** —— 它不在核心包里，是单独一个可选 bundle
（本机已启用）：

```
@deepseek-ai/dsh-experimental-schedule-bundle   [enabled, optional]
   dsh-time-context · dsh-schedule · dsh-client-ui-schedule
```

同层还有 `experimental-agent-team-profile`（Agent Teams）、`voice-input`、
`auto-review` —— 都没进我的 1-8。

### 第三方插件跟这 8 项无关

本机装了 **7 个第三方**（`installed` + `removable`），没有一个提供 1-8 的能力：

| 包 | 是什么 |
|---|---|
| `dsh-plugin-tether` | 手机客户端传输层 —— **就是我们这个 App 依赖的那个** |
| `dshmarket` | 可视化插件市场 |
| `dsh-plugin-tool-management` | MCP／技能／场景／记忆／子代理人设的统一设置面板 |
| `dsh-better-sidebar` | 增强版右侧栏（文件树、编辑器、变更、任务） |
| `@michengai/dsh-im-connect` | IM 接入（飞书/微信…）—— 就是频道功能的来源 |
| `dsh-free-search` | 24 引擎免费搜索 |
| `dsh-context` | **上下文仪表盘**（dashboard／browser／dynamics + context 命令） |

> ⚠️ **一个例外要标清楚**：第 7 项「上下文明细」我指的是官方的
> `contextBreakdown`（`{systemTokens, toolsTokens, messageTokens}` 三个数）。
> 桌面端那个**更丰富的上下文仪表盘**是第三方 `dsh-context` 提供的 ——
> 那部分不在我的 1-8 里，要做得单独看它的接口。

---

## 五、明确建议**不做**的

- **侧边栏三件套**（终端／浏览器／文档预览增强）：手机屏幕放不下，且真正需要时
  桌面上做更合适
- **`open-in-app`**：iOS 沙箱里没有"用 Finder 打开"
- **快捷键**：触屏
- **账号与充值**：`settings-account`
- **`agentTeam`**：还是 `dsh-experimental-*`，接口会变
- **插件安装/卸载**：手机上装插件风险高（会改用户电脑上的环境），
  开关已经够了
