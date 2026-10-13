#!/usr/bin/env python3
"""生成 `DSHPocket/Resources/Localizable.xcstrings`（String Catalog）。

为什么用脚本而不是手写 JSON：源语言是 zh-Hans，中文文案就是 key。手写 200 多条
JSON 很容易漏、很容易写错转义；脚本还能顺手做两件有价值的事：

  1. **校验**：源码里出现的每条文案都必须有 en 翻译，否则退出码非 0 —— 这就是
     「zh-Hans / en 全部有文案」这条验收项的自动化版本；
  2. **占位符一致性检查**：带插值的文案，中英两侧的 `%lld` / `%@` 数量必须一致，
     否则英文界面上会显示成 `%lld` 字面量。

用法：
    python3 ios/scripts/gen-strings.py            # 写入 String Catalog
    python3 ios/scripts/gen-strings.py --check    # 只校验，不写文件（CI 用）
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "DSHPocket"
# DSHKit 里也有 `String(localized:)`。它是**静态库**，链接进 App 之后
# `String(localized:)` 走的就是 App 的目录 —— 不扫它这些文案会漏翻译
# （英文界面上直接显示中文）。TetherKit 同理。
EXTRA_SOURCE_DIRS = [ROOT / "DSHKit" / "Sources", ROOT / "TetherKit" / "Sources"]
CATALOG = SOURCE_DIR / "Resources" / "Localizable.xcstrings"
SOURCE_LANGUAGE = "zh-Hans"

# 源码里会被抽成 key 的调用点。宁可多列几种，也别漏（漏了就不会被本地化）。
EXTRACTION_PATTERNS = [
    r'String\(localized:\s*"((?:[^"\\]|\\.)*)"',
    r'Text\("((?:[^"\\]|\\.)*)"\)',
    r'Label\("((?:[^"\\]|\\.)*)"',
    r'\.navigationTitle\("((?:[^"\\]|\\.)*)"\)',
    r'ContentUnavailableView\(\s*"((?:[^"\\]|\\.)*)"',
    r'Button\("((?:[^"\\]|\\.)*)"',
    r'Section\("((?:[^"\\]|\\.)*)"\)',
    r'Toggle\("((?:[^"\\]|\\.)*)"',
    r'TextField\("((?:[^"\\]|\\.)*)"',
    r'Picker\("((?:[^"\\]|\\.)*)"',
]

# 中 → 英。插值文案里的 \(x) 在 catalog 里是 %lld（Int）或 %@（字符串）。
EN: dict[str, str] = {
    # 连接状态
    "未连接": "Not connected",
    "连接中…": "Connecting…",
    "连接失败": "Connection failed",
    "开发直连": "Dev direct",
    "远端连接": "Remote",
    "断开": "Offline",
    "已连接": "Connected",
    "重连中": "Reconnecting",
    "未开始": "Not started",
    "连接中": "Connecting",
    "已断开：%@": "Disconnected: %@",
    "直连（打洞成功）": "Direct (hole-punched)",
    "中转（仅密文）": "Relay (ciphertext only)",

    # 通知
    "有一条操作在等你批准": "An action is waiting for your approval",
    "电脑在等你回答": "Your computer is waiting for an answer",
    "电脑端提示：有操作待批准": "From your computer: an action needs approval",
    "%lld 个问题": "%lld questions",

    # 会话列表
    "会话": "Sessions",
    "选择一个会话": "Select a session",
    "在左侧选一个会话开始；也可以下拉刷新列表。": "Pick a session on the left, or pull to refresh.",
    "刚刚": "Just now",
    "搜索标题或摘要": "Search titles and summaries",
    "会话会在所选工作区里创建。": "The session is created in the workspace you pick.",
    "在电脑上开一个会话，或者在这里新建一个。": "Start a session on your computer, or create one here.",
    "归档": "Archive",
    "重新连接": "Reconnect",
    "读不到会话": "Couldn’t load sessions",
    "还没有会话": "No sessions yet",
    "新建会话": "New session",
    "设置": "Settings",
    "正在运行": "Running",
    "打开这个会话": "Open this session",
    "这台电脑上暂时不可用": "Unavailable on this computer",
    "这是一个子会话": "This is a subagent session",
    "正在读取会话…": "Loading sessions…",
    "重命名会话": "Rename session",
    "标题": "Title",
    "保存": "Save",
    "取消": "Cancel",
    "重命名": "Rename",
    "复制会话 ID": "Copy session ID",
    "%lld 个会话": "%lld sessions",

    # 会话时间线
    "这个会话还是空的": "This session is empty",
    "在下面输入第一句话。": "Type your first message below.",
    "正在读取会话内容": "Loading this session",
    "载入更早的内容": "Load earlier content",
    "已被压缩取代的 %lld 条内容": "%lld items replaced by compaction",
    "跳到最新": "Jump to latest",
    "切换模型": "Change model",
    "工作区文件": "Workspace files",
    "显示模型可见的原始事件": "Show raw model-facing events",
    "隐藏被取代的内容": "Hide replaced content",
    "显示被取代的内容": "Show replaced content",
    "分享这轮对话": "Share this conversation",
    "会话操作": "Session actions",
    "连接断了，正在重连": "Connection dropped — reconnecting",
    "连不上电脑": "Can’t reach your computer",
    "上一步没成功": "The last step didn’t go through",
    "知道了": "Got it",
    "正在补更早的内容": "Loading earlier content",
    "第 %lld 轮": "Turn %lld",
    "第 %lld 轮：%@": "Turn %lld: %@",
    "第 %lld 轮，%@ 开始": "Turn %lld, started %@",
    "这一轮结束": "Turn finished",
    "已中断": "Interrupted",
    "出错结束": "Ended with an error",
    "开始压缩上下文": "Compacting context",
    "上下文已压缩": "Context compacted",
    "压缩完成": "Compaction finished",
    "已裁剪旧工具结果": "Trimmed old tool results",
    "目标已更新": "Goal updated",
    "已进入计划模式": "Entered plan mode",
    "已退出计划模式": "Left plan mode",

    # 消息
    "你说：%@": "You said: %@",
    "助手回复": "Assistant reply",
    "正在生成": "Generating",
    "思考过程": "Reasoning",
    "展开查看模型的推理过程": "Show the model’s reasoning",
    "图片": "Image",
    "图片附件": "Image attachment",
    "认不出的事件 %@": "Unrecognized event %@",
    "点按全屏查看": "Tap to view full screen",
    "关闭": "Close",
    "代码": "Code",
    "复制": "Copy",
    "已复制": "Copied",
    "复制代码": "Copy code",
    "已复制代码": "Code copied",

    # 工具
    "工具 %@": "Tool %@",
    "参数": "Arguments",
    "输出": "Output",
    "错误输出": "Error output",
    "查看全部 / 分享": "View all / Share",
    "运行中": "Running",
    "成功": "Succeeded",
    "失败": "Failed",
    "已取消": "Cancelled",

    # 待办 / 产物
    "待办": "To-dos",
    "进行中": "In progress",
    "已完成": "Done",
    "产物": "Deliverables",

    # 审批
    "需要你决定": "Your decision is needed",
    "电脑上有一个操作在等你批准。": "An action on your computer is waiting for approval.",
    "审批请求：%@。%@": "Approval request: %@. %@",
    "拒绝": "Reject",
    "批准一次": "Allow once",
    "稍后处理": "Later",
    "待处理": "Pending",
    "没有待处理的事": "Nothing pending",
    "电脑上有操作要你批准时会出现在这里。": "Approvals from your computer show up here.",
    "打开待处理列表": "Open the pending list",
    "已批准一次": "Allowed once",
    "已始终允许": "Always allowed",
    "已拒绝": "Rejected",
    "%lld 个待批准": "%lld to approve",
    "%lld 个待回答": "%lld to answer",
    "完成": "Done",

    # 提问
    "你的回答": "Your answer",
    "补充说明（可选）": "Additional notes (optional)",
    "其它（可选）": "Other (optional)",
    "选择": "Choose",
    "未选择": "Not selected",
    "提交回答": "Submit answer",

    # 文件
    "工作区": "Workspace",
    "读不到文件": "Couldn’t read the folder",
    "这个目录是空的": "This folder is empty",
    "复制路径": "Copy path",
    "上一层": "Up",
    "刷新": "Refresh",
    "重试": "Retry",
    "工作区根目录": "Workspace root",

    # 输入区
    "添加附件": "Add attachment",
    "移除附件 %@": "Remove attachment %@",
    "消息": "Message",
    "照片": "Photo",
    "文件": "File",
    "附件": "Attachment",
    "给电脑说点什么…": "Say something to your computer…",
    "发送": "Send",
    "停止": "Stop",
    "发送中…": "Sending…",
    "把消息发给电脑": "Send this message to your computer",
    "打断正在跑的这一轮": "Interrupt the running turn",
    "已附加 %lld 张图片，点按移除": "%lld images attached, tap to remove",

    # 模型
    "模型": "Model",
    "可用模型": "Available models",
    "切换只影响这个会话。": "Switching only affects this session.",
    "读不到模型清单": "Couldn’t load the model list",
    "电脑没有返回模型清单。": "Your computer returned no model list.",
    "推理强度": "Reasoning effort",
    "跟随默认": "Use default",
    "低": "Low",
    "中": "Medium",
    "高": "High",
    "最高": "Max",

    # 配对
    "连接电脑": "Connect to computer",
    "扫描电脑上的二维码": "Scan the QR code on your computer",
    "手动输入配对码": "Enter the pairing code",
    "这台设备不能扫码": "This device can’t scan codes",
    "在电脑上打开 DSH 的「连接手机」，它会显示一个二维码和 6 位配对码。":
        "Open “Connect phone” in DSH on your computer — it shows a QR code and a 6-digit pairing code.",
    "配对窗口 10 分钟内有效，最多错 3 次。": "The pairing window lasts 10 minutes and allows 3 attempts.",
    "这台手机的设备 ID": "This phone’s device ID",
    "电脑端按这把公钥授权给这台手机；换手机或重置身份后需要重新配对。":
        "Your computer authorizes this phone by this public key. A new phone, or a reset identity, needs pairing again.",
    "把电脑上的二维码放进取景框": "Point the camera at the QR code on your computer",
    "可以手动输入 6 位配对码。": "You can type the 6-digit code instead.",
    "6 位配对码": "6-digit pairing code",
    "电脑上「连接手机」对话框里显示的那 6 个数字。":
        "The six digits shown in the “Connect phone” dialog on your computer.",
    "电脑 ID": "Computer ID",
    "电脑 ID（可选）": "Computer ID (optional)",
    "已配对过的电脑会自动填上；第一次配对时也可以整串粘贴到这里。":
        "A previously paired computer fills this in. You can also paste the whole pairing string here.",
    "格式是「电脑 ID#配对码」，整串粘进来会自动拆开。":
        "The format is “computer-id#code”; pasting the whole string splits it automatically.",
    "粘贴配对串": "Paste the pairing string",
    "配对码": "Pairing code",
    "连接": "Connect",
    "正在连接电脑…": "Connecting to your computer…",
    "配对没有成功": "Pairing didn’t succeed",
    "再试一次": "Try again",
    "手动输入": "Enter manually",
    "这个二维码里没有配对信息。请确认扫的是 DSH「连接手机」显示的那一个。":
        "That QR code has no pairing information. Make sure you scanned the one from DSH’s “Connect phone”.",
    "连接没有完成，请再试一次。": "The connection didn’t finish. Please try again.",
    "复制": "Copy",
    "已复制": "Copied",
    "这台手机的设备 ID：%@…\n电脑端按这把公钥授权；删掉它需要重新配对。":
        "This phone’s device ID: %@…\nYour computer authorizes by this public key; deleting it requires pairing again.",

    # 首次启动
    "把电脑上的会话带到手机上": "Your computer’s sessions, on your phone",
    "原生 SwiftUI 界面，直接和电脑上的 DSH 说话：看时间线、发消息、批审批、看产物。不经过任何第三方服务器。":
        "A native SwiftUI client that talks straight to DSH on your computer: read the timeline, send messages, approve actions, collect deliverables. No third-party server involved.",
    "会话时间线，流式追加": "Streaming session timeline",
    "工具调用折叠成一行，点开看参数与输出": "Tool calls collapse to one row — tap for arguments and output",
    "审批在你的手机上决定": "Approvals decided on your phone",
    "电脑上有操作要你批准时会推到你面前": "When your computer needs approval, it comes to you",
    "浏览工作区文件": "Browse workspace files",
    "用系统 QuickLook 预览，不下载到别处": "Preview with the system QuickLook — nothing is copied elsewhere",
    "你的数据只在你的设备之间": "Your data stays between your devices",
    "手机和电脑之间走点对点加密（iroh）。打洞成功时数据不经过任何第三方；回退中转时，中转只能看到密文。":
        "Phone and computer talk over encrypted peer-to-peer iroh. When hole-punching succeeds nothing goes through a third party; on relay fallback the relay only sees ciphertext.",
    "不采集分析数据": "No analytics",
    "没有遥测、没有账号、没有云端": "No telemetry, no account, no cloud",
    "凭证与内容都在你的电脑上": "Credentials and content live on your computer",
    "这个 App 只是一个远程控制端": "This app is only a remote control",
    "访问权由这台手机的公钥决定": "Access is granted by this phone’s public key",
    "配对码 6 位、10 分钟、3 次尝试": "6-digit code, 10 minutes, 3 attempts",
    "两条如实告知的边界": "Two boundaries we tell you about",
    "安全声明只有在说清边界时才有意义。": "A security claim is only worth something when its boundaries are spelled out.",
    "电脑端": "On the computer",
    "已经能在你电脑上执行代码的人，可以伪造回环请求、自签配对码，把自己配成一台「手机」。所以不要把本 App 用在你同时跑不可信代码的电脑上。":
        "Anyone who can already run code on your computer can forge loopback requests and mint their own pairing code, enrolling themselves as a “phone”. So don’t use this app on a computer where you also run untrusted code.",
    "手机端": "On the phone",
    "App 内的本地代理只监听 127.0.0.1，但手机上其它 App 可以连上它，而且端口能由主机 ID 推算出来。一期如实告知，后续会加进程内握手令牌。":
        "The in-app local proxy listens on 127.0.0.1 only, but other apps on this phone can connect to it, and the port is derivable from the host ID. We tell you now; an in-process handshake token comes later.",
    "跳过": "Skip",
    "继续": "Continue",
    "开始使用": "Get started",
    "DSH Pocket 是独立社区项目，与 DeepSeek 官方无隶属关系。":
        "DSH Pocket is an independent community project, not affiliated with DeepSeek.",

    # 诊断
    "诊断": "Diagnostics",
    "连接与协议": "Connection and protocol",
    "动作": "Actions",
    "重新拉会话列表": "Reload session list",
    "重连电脑": "Reconnect to computer",
    "连不上时先看电脑端：sidecar 进程在不在、DSH 是否还在 127.0.0.1:19387、系统「本地网络」权限是否放行。":
        "When it won’t connect, check the computer first: is the sidecar running, is DSH still on 127.0.0.1:19387, and has the system granted Local Network access.",
    "协议自检": "Protocol self-check",
    "自检直接打 DSH 的客户端协议（unary + 流），不经过界面。宿主升级后出问题，先看这里。":
        "The self-check calls DSH’s client protocol directly (unary + streams), bypassing the UI. If a host upgrade breaks something, look here first.",
    "跑一次协议自检": "Run a protocol self-check",
    "unary · session/list": "unary · session/list",
    "流 · session/follow": "stream · session/follow",
    "拿到 %lld 个会话": "Got %lld sessions",
    "快照 %lld 条事件": "Snapshot with %lld events",
    "没有收到快照": "No snapshot received",
    "最近日志": "Recent log",
    "还没有日志。": "No log entries yet.",
    "显示全部日志": "Show full log",
    "日志只留在本机内存里，不会外发；要给别人看就手动导出。":
        "The log stays in local memory and is never sent anywhere; export it manually if you need to share it.",
    "导出日志": "Export log",
    "状态": "Status",
    "会话流（mux）": "Session stream (mux)",
    "本地代理": "Local proxy",
    "加密路径": "Encrypted path",
    "远端": "Remote",
    "本机端点 ID": "Local endpoint ID",
    "未启动": "Not started",
    "未连接": "Not connected",
    "解析中": "Parsing",

    # 设置
    "主机": "Computers",
    "还没有配对过任何电脑。": "No computers paired yet.",
    "添加电脑": "Add computer",
    "忘记": "Forget",
    "当前": "Current",
    "这台手机的设备 ID：%@": "This phone’s device ID: %@",
    "通知": "Notifications",
    "等待审批": "Waiting for approval",
    "等你回答": "Waiting for your answer",
    "一轮跑完": "Turn finished",
    "只在打开开关时才向系统申请通知权限。App 退到后台会断开与电脑的连接（iOS 不允许常驻），所以通知是本地提醒，不是实时推送。":
        "Notification permission is requested only when you turn a switch on. The app disconnects from your computer in the background (iOS doesn’t allow persistent connections), so these are local reminders rather than live push.",
    "外观": "Appearance",
    "主题": "Theme",
    "跟随系统": "System",
    "浅色": "Light",
    "深色": "Dark",
    "关于": "About",
    "版本": "Version",
    "协议": "Protocol",
    "传输": "Transport",
    "第三方组件与许可": "Third-party components and licenses",
    "隐私与安全边界": "Privacy and security boundaries",
    "第三方组件": "Third-party components",
    "本项目以 MIT 许可发布。以上组件各自保留原许可与版权声明。":
        "This project is released under the MIT license. Each component above keeps its own license and copyright notice.",
    "重命名主机": "Rename computer",
    "名称": "Name",

    # 隐私页
    "我们做什么": "What we do",
    "不采集任何分析数据，不联网发送遥测。": "We collect no analytics and send no telemetry.",
    "所有流量都发往你自己已配对的电脑。": "All traffic goes to your own paired computer.",
    "凭证与数据都在你自己的机器上。": "Credentials and data stay on your own machine.",
    "电脑端的已知边界": "Known boundary on the computer",
    "已经能在你电脑上执行代码的人，可以伪造回环 Host 通过栅栏、自签配对码，把自己配成一台「手机」。":
        "Anyone who can already run code on your computer can forge the loopback Host to pass the fence and mint their own pairing code, enrolling themselves as a “phone”.",
    "所以：**不要把本 App 用在你同时跑不可信代码的电脑上。**":
        "So: **don’t use this app on a computer where you also run untrusted code.**",
    "手机端的已知边界": "Known boundary on the phone",
    "App 内的本地代理只监听 127.0.0.1，但手机上其它 App 可以连上它，而且端口可以由主机 ID 推算出来。":
        "The in-app local proxy listens on 127.0.0.1 only, but other apps on this phone can connect to it, and the port is derivable from the host ID.",
    "一期如实告知；后续可加一个进程内的随机握手令牌（需要电脑端配合）。":
        "We say so up front; a random in-process handshake token can be added later (it needs the computer side to cooperate).",
    "端到端加密": "End-to-end encryption",
    "打洞成功时数据不经过任何第三方。": "When hole-punching succeeds, data passes through no third party.",
    "回退中转时，中转只能看到密文。": "On relay fallback, the relay only sees ciphertext.",
    "配对码 6 位、10 分钟、3 次尝试；配对后访问权由这台手机的公钥决定。":
        "A 6-digit code, 10 minutes, 3 attempts; after pairing, access is granted by this phone’s public key.",

    # 错误与回退
    "还没有和这台电脑配对": "Not paired with this computer yet",
    "电脑上没有开着的配对窗口。请在电脑上打开「连接手机」再试。":
        "No pairing window is open on your computer. Open “Connect phone” there and try again.",
    "配对窗口已过期。请在电脑上重新打开「连接手机」。":
        "The pairing window expired. Open “Connect phone” on your computer again.",
    "配对码试错次数超限，窗口已关。请在电脑上重新打开「连接手机」。":
        "Too many wrong codes — the window is closed. Open “Connect phone” on your computer again.",
    "配对码不正确。": "That pairing code is wrong.",
    "还没有连接到电脑": "Not connected to your computer yet",
    "请求已取消": "Request cancelled",
    "未知错误": "Unknown error",
    "电脑端拒绝了代理流（插件可能没在正常状态）": "Your computer refused the proxy stream (the plugin may not be healthy)",
    "还没有和这台电脑配对": "Not paired with this computer yet",
    "读取中…": "Loading…",
    "DSH Pocket": "DSH Pocket",
    "电脑端结束了这条会话流": "Your computer closed this session stream",
    "会话已归档": "Session archived",
    "已归档": "Archived",
    "这个二维码里没有配对信息。": "That QR code has no pairing information.",
    "正在读取会话…": "Loading sessions…",
    "跳过": "Skip",
    "%lld 分 %lld 秒": "%lld min %lld s",
    "%.1f 秒": "%.1f s",
    "%lld 毫秒": "%lld ms",
    "%@，%@": "%@, %@",
    # 归档管理 / 连接状态 / 代理提示
    "已归档的会话": "Archived sessions",
    "已归档": "Archived",
    "恢复到对话列表": "Restore to session list",
    "恢复": "Restore",
    "恢复这个会话？": "Restore this session?",
    "没有归档的会话": "No archived sessions",
    "左滑会话列表里的行就能把它归档到这里。": "Swipe a row in the session list to archive it here.",
    "搜索已归档的会话": "Search archived sessions",
    "左滑可恢复到对话列表": "Swipe to restore it to the session list",
    "归档过的会话不会出现在对话列表里，在这里可以恢复或重新打开。":
        "Archived sessions don’t appear in the session list. Restore or reopen them here.",
    "已置顶": "Pinned",
    "正在和电脑握手，第一次可能要几秒。": "Shaking hands with your computer — the first time can take a few seconds.",
    "配对一次之后，手机会记住这台电脑。": "After pairing once, this phone remembers your computer.",
    "正在连接…": "Connecting…",
    "正在连接电脑": "Connecting to your computer",
    "已连接到电脑": "Connected to your computer",
    "已连接，正在重连会话流": "Connected, reconnecting the session stream",
    "连接失败：%@": "Connection failed: %@",
    "先试这三件事": "Try these three things",
    "1. 确认电脑上的 DSH 开着、插件已加载；\n2. 手机设置里允许本 App 使用「本地网络」；\n3. 关掉手机上的代理/VPN 再连一次（它会接管 UDP，打洞会失败）。":
        "1. Make sure DSH is running on your computer and the plugin is loaded;\n2. Allow Local Network access for this app in iOS Settings;\n3. Turn off any proxy/VPN on the phone and try again (it takes over UDP, so hole-punching fails).",
    "手机上开着代理或 VPN（sing-box、Clash、Surge 等）时，隧道会把 UDP 一并接管：打洞多半会退化成中转（仍然加密，只是慢），分流规则里禁掉 UDP 的话 QUIC 会被直接拦死。连不上就先关掉代理试一次。":
        "With a proxy or VPN running on the phone (sing-box, Clash, Surge…), the tunnel also captures UDP: hole-punching usually degrades to a relay (still encrypted, just slower), and if your rules block UDP, QUIC is blocked outright. If it won’t connect, turn the proxy off and try once.",
    "这个会话正在跑": "This session is running",
    "停止并归档": "Stop and archive",
    "归档会先把这一轮停掉。已经跑出来的内容会保留。":
        "Archiving stops the running turn first. Everything already produced is kept.",
    "这个会话正在跑，DSH 不允许直接归档。先停下它再归档。":
        "This session is running, and DSH won’t archive it as-is. Stop it first, then archive.",
    # 连接方式
    "连接方式": "Connection",
    "远端连接（iroh）": "Remote (iroh)",
    "开发直连（本机）": "Dev direct (this Mac)",
    "直连网关（Tailscale / 局域网）": "Direct gateway (Tailscale / LAN)",
    "直连网关": "Direct gateway",
    "开发直连地址": "Dev direct address",
    "网关地址": "Gateway address",
    "令牌": "Token",
    "用这个地址连接": "Connect with this address",
    "走 iroh 点对点：公网可用，打洞成功时不经第三方，回退中转时中转只见密文。":
        "Peer-to-peer over iroh: works over the public internet, goes through no third party when hole-punching succeeds, and the relay only sees ciphertext on fallback.",
    "打本机回环上的直连网关，模拟器开发用。需要先在电脑上跑 node tools/direct-gateway.mjs。":
        "Hits a direct gateway on the loopback interface — for simulator development. Run node tools/direct-gateway.mjs on your computer first.",
    "打你电脑上的直连网关。适合手机上开着代理/VPN（iroh 的 UDP 打洞会被隧道干扰），或者电脑和手机在同一个 tailnet / 局域网时。\n电脑上：node tools/direct-gateway.mjs --host <你的 tailnet 或局域网地址> --token <令牌>\n这条路依赖 tailnet / 局域网自身的加密；公网使用请放在 TLS 反向代理后面。":
        "Hits a direct gateway on your computer. Best when a proxy/VPN is running on the phone (it interferes with iroh’s UDP hole-punching), or when phone and computer share a tailnet / LAN.\nOn your computer: node tools/direct-gateway.mjs --host <tailnet-or-LAN-address> --token <token>\nThis path relies on the tailnet / LAN for encryption; for public use put it behind a TLS reverse proxy.",
    # 列表分流与筛选
    "会话": "Sessions",
    "频道": "Channels",
    "范围": "Scope",
    "筛选": "Filter",
    "工作区": "Workspace",
    "全部工作区": "All workspaces",
    "清除工作区筛选": "Clear the workspace filter",
    "显示全部工作区": "Show all workspaces",
    "这个工作区下没有会话": "No sessions in this workspace",
    "换一个工作区，或者清除筛选。": "Pick another workspace, or clear the filter.",
    "没有频道会话": "No channel sessions",
    "飞书、微信这类外部聊天接进 DSH 之后，会在这里出现。":
        "External chats wired into DSH — Feishu, WeChat and the like — show up here.",
    "排队发送": "Queue",
    # 桌面端对齐：后台任务 / 目标 / 提醒 / 上下文明细 / 引用 / 搜索 / 字号
    "小": "Small",
    "标准": "Standard",
    "大": "Large",
    "特大": "Largest",
    "会话字号": "Session text size",
    "后台任务": "Background jobs",
    "后台任务（%lld 个运行中）": "Background jobs (%lld running)",
    "没有后台任务": "No background jobs",
    "让电脑跑一个后台命令时，它会出现在这里，输出也能实时看。":
        "When a background command runs on your computer, it shows up here — with live output.",
    "运行中": "Running",
    "正在停止": "Stopping",
    "已结束": "Finished",
    "失败": "Failed",
    "已停止": "Stopped",
    "还没有输出…": "No output yet…",
    "没有输出。": "No output.",
    "前面的输出已经被丢掉了（超出上限），下面是能拿到的部分。":
        "Earlier output was dropped (over the limit); below is what’s still available.",
    "停止这个后台任务？": "Stop this background job?",
    "停止": "Stop",
    "重新连接": "Reconnect",
    "%@ 输出": "%@ output",
    "目标": "Goal",
    "目标（进行中）": "Goal (active)",
    "目标内容": "Objective",
    "进行中的目标": "Active goal",
    "已暂停的目标": "Paused goal",
    "受阻的目标": "Blocked goal",
    "未运行的目标": "No active goal",
    "这个会话没有目标": "This session has no goal",
    "目标是「让智能体持续做下去」的长期任务。设一个之后，它会自己接着跑。":
        "A goal is a long-running task the agent keeps working on by itself.",
    "设一个目标": "Set a goal",
    "描述你要它持续做什么": "Describe what it should keep doing",
    "保存之后智能体会持续执行，直到你说停。": "The agent keeps going until you tell it to stop.",
    "暂停目标": "Pause goal",
    "恢复目标": "Resume goal",
    "编辑目标": "Edit goal",
    "清除目标": "Clear goal",
    "上下文占用": "Context usage",
    "系统提示": "System prompt",
    "工具定义": "Tool definitions",
    "对话历史": "Conversation history",
    "合计": "Total",
    "占窗口 %lld%% · %@ / %@": "%lld%% of window · %@ / %@",
    "定时提醒": "Scheduled reminders",
    "没有提醒": "No reminders",
    "读不到提醒": "Couldn’t load reminders",
    "重试": "Retry",
    "在会话里用 `/schedule` 让电脑到点干件事，之后会出现在这里。":
        "Use `/schedule` in a session to have your computer do something on time; it appears here.",
    "左滑删除。新建要在会话里发 `/schedule` —— 服务端的写接口要求传完整记录和乐观并发版本，比命令脆弱得多。":
        "Swipe to delete. Create reminders with `/schedule` in a session — the write API needs a full record plus an optimistic-concurrency version, which is far more fragile than the command.",
    "让电脑到点自己干件事。新建要在会话里发 `/schedule`。":
        "Have your computer do something on time. Create one with `/schedule` in a session.",
    "删除这条提醒？": "Delete this reminder?",
    "提醒": "Reminder",
    "%lld 秒后": "in %llds",
    "指定时刻": "at a set time",
    "每 %lld 小时": "every %lldh",
    "每 %lld 分钟": "every %lldm",
    "每 %lld 秒": "every %llds",
    "每天": "Daily",
    "每周": "Weekly",
    "历史搜索": "History search",
    "历史搜索 · %lld 条": "History · %lld hits",
    "这台电脑没有开启会话搜索索引（session-query 的 openAt 被设成了 never）。":
        "This computer hasn’t enabled the session search index (session-query’s openAt is set to never).",
    "同一工作区": "Same workspace",
    "待办 %lld/%lld": "To-dos %lld/%lld",
    "发消息或创建任务": "Send a message or create a task",
    "正在生成": "Generating",
    "工作中": "Working",
    "工作中，已用时 %@": "Working · %@ elapsed",
    "%lld 分 %lld 秒": "%lldm %llds",
    "%lld 秒": "%llds",
    "目录": "Folder",
    "插队给这一轮": "Steer into this turn",
    # 连接失败的可执行提示
    "上一次连接还在进行中": "A connection attempt is already in progress",
    "%@\n连续失败 %lld 次。如果电脑端重装过插件或清过配对数据，请在「设置 → 主机」里删掉这台电脑，然后重新配对。":
        "%@\nFailed %lld times in a row. If the plugin was reinstalled or its pairing data was cleared on your computer, delete this computer under Settings → Computers and pair again.",
    # 模型页 / 筛选 / 思考过程
    "正在读取模型清单…": "Loading the model list…",
    "这台电脑上没有可用模型": "No models available on this computer",
    "先在你电脑上的 DSH 里登录一个模型服务。": "Sign in to a model service in DSH on your computer first.",
    "当前模型": "Current model",
    "只列出当前模型支持的档位 —— 不同模型的可选项不一样。":
        "Only the levels this model supports are listed — they differ per model.",
    "切换失败": "Couldn’t switch",
    "清除": "Clear",
    "清除筛选": "Clear the filter",
    "默认展开思考过程": "Expand reasoning by default",
    "按名字或路径找会话": "Search by name or path",
    # 权限档位
    "权限": "Permissions",
    "权限：%@": "Permissions: %@",
    "权限：仅可查看": "Permissions: Read only",
    "权限：工作区内修改": "Permissions: Workspace write",
    "权限：完全权限": "Permissions: Full access",
    "仅可查看": "Read only",
    "工作区内修改": "Workspace write",
    "完全权限": "Full access",
    "正在读取权限档位…": "Loading permission presets…",
    "读不到权限档位": "Couldn’t load permission presets",
    "当前会话": "This session",
    "当前档位": "Current",
    "现在": "Now",
    "档位": "Preset",
    "只影响这个会话。改完电脑端会记一条权限变更，时间线上也看得到。":
        "Affects this session only. Your computer records the change, and it shows up on the timeline.",
    "只能读，不能改文件，也不能跑会写盘的命令。": "Read only — no file changes, no commands that write.",
    "能在工作区目录里读写。工作区之外的操作仍然要你批准。":
        "Read and write inside the workspace directory. Anything outside still needs your approval.",
    "读写不受工作区限制，而且会减少确认步骤，包括敏感操作与外部命令。只在你信任接下来的任务时用。":
        "Unrestricted reads and writes, with fewer confirmation steps — including sensitive operations and external commands. Only use it when you trust what comes next.",
    "启用完全权限？": "Turn on full access?",
    "我已了解风险，仍然启用": "I understand the risk — enable it",
    "完全权限会读写不受工作区限制，并减少确认步骤 —— 包括敏感操作、文件修改和外部命令。仅在你信任接下来的任务时使用。":
        "Full access removes the workspace limit on reads and writes and cuts confirmation steps — including sensitive operations, file changes, and external commands. Only use it when you trust what comes next.",
    "切换权限失败": "Couldn’t switch permissions",
    # Markdown 表格与图片
    "表格，%lld 列 %lld 行": "Table, %lld columns by %lld rows",
    "图片 %@，未加载：只从你的电脑取数据": "Image %@, not loaded: data comes only from your computer",
    # 新建会话
    "新建会话": "New session",
    "搜索工作区": "Search workspaces",
    "还没有工作区": "No workspaces yet",
    "先在电脑上的 DSH 里添加一个工作区，然后再来这里新建会话。":
        "Add a workspace in DSH on your computer first, then come back here.",
    "新建的会话会挂在这个工作区下面；选了工作区之后直接进会话页。":
        "The new session belongs to the workspace you pick; you go straight into it.",
    "电脑没有返回新建的会话。": "Your computer didn’t return the new session.",
    "建不了会话": "Couldn’t create the session",
    # 开发者模式（仅 DEBUG）
    "调试": "Debug",
    "开发者模式：": "Developer mode: ",
    "改回 iroh": "Switch back to iroh",
    "正常使用请改回「远端连接（iroh）」": "For normal use, switch back to “Remote (iroh)”.",
    # 会话缓存
    "缓存": "Cache",
    "已缓存会话": "Cached sessions",
    "占用空间": "Space used",
    "清空缓存": "Clear cache",
    "会话内容会缓存在本机，切回之前的会话时不用再等一次远程加载。缓存放在系统可回收的位置，随时可以清空 —— 清空只影响速度，不会丢任何东西。":
        "Sessions are cached on this device, so switching back doesn’t wait for a remote reload. The cache lives in a system-reclaimable location and you can clear it anytime — clearing only costs speed, nothing is lost.",
    # 提问交互
    "跳过这个问题": "Skip this question",
    "用户跳过了这个问题，没有作答。": "The user skipped this question without answering.",
    "还有 1 个问题没回答": "1 question still needs an answer",
    "还有 %lld 个问题没回答": "%lld questions still need answers",
    "待处理已作废": "Pending items expired",
    "连接中断过，%lld 条待处理已经作废 —— 电脑端会按默认方式继续。":
        "The connection dropped, so %lld pending item(s) expired — your computer will continue using its defaults.",
    "都不回答（结束这次提问）": "Answer none (end this question)",
    # 审批
    "展开全部": "Show all",
    "收起": "Collapse",
    "将要执行：%@": "About to run: %@",
    "完整参数在「%@」那张卡片上。": "The full arguments are on the card in “%@”.",
    "这条已经不能在这里回答了（连接中断过，电脑会按默认方式继续）":
        "This one can no longer be answered here (the connection dropped; your computer will use its default).",
    "别的会话": "Another session",
    # 电脑设置
    "电脑设置": "Computer settings",
    "在手机上改**电脑上**的配置：插件开关、新会话的默认模型与思考等级。其余设置在电脑上改更合适。":
        "Change settings on your **computer** from here: plugin toggles, and the default model and thinking level for new sessions. Other settings are better changed on the computer.",
    "新会话的默认值": "Defaults for new sessions",
    "默认模型": "Default model",
    "思考等级": "Thinking level",
    "未设置": "Not set",
    "正在读取…": "Loading…",
    "这台电脑没有暴露默认模型设置。": "This computer doesn’t expose a default-model setting.",
    "只影响**之后新建**的会话；已经在跑的会话各自保留自己的模型（那个在会话菜单里改）。":
        "Affects **new** sessions only; running sessions keep their own model (change that in the session menu).",
    "插件": "Plugins",
    "没有读到插件清单。": "Couldn’t read the plugin list.",
    "已启用 · %lld": "Enabled · %lld",
    "已停用 · %lld": "Disabled · %lld",
    "已启用": "Enabled",
    "已停用": "Disabled",
    "运行中": "Running",
    "没有可寻址的位置，改不了": "No addressable location — can’t be changed",
    "管理插件，不能自己关自己": "Management plugin — it can’t turn itself off",
    "不可修改": "Not editable",
    "停用这个插件？": "Disable this plugin?",
    "停用": "Disable",
    "停用后，依赖它的功能会立刻失效（比如 IM 插件停掉之后频道会话就不再更新）。在电脑上重启 DSH 也能恢复。":
        "Anything depending on it stops working immediately (disable the IM plugin and channel sessions stop updating). Restarting DSH on your computer restores it.",
    "改不了": "Couldn’t change it",
    "搜索插件": "Search plugins",
    "先连上电脑才能改这些。": "Connect to your computer first.",
    "停用这个插件": "Disable this plugin",
    "启用这个插件": "Enable this plugin",
    # 排队
    "1 条排队中": "1 queued",
    "%lld 条排队中": "%lld queued",
    "%lld 条消息排队中": "%lld messages queued",
    "%lld 张图片": "%lld images",
    "%lld 个文件": "%lld files",
    "电脑跑完这一轮就会发出去。": "Your computer sends it when this turn finishes.",
    "展开模型的推理过程": "Show the model’s reasoning",
    "思考中…": "Thinking…",
    # 轮次收拢
    "已完成": "Done",
    "用时 %@": "took %@",
    "%lld 步": "%lld steps",
    "展开这一轮的过程": "Expand this turn’s steps",
    "收起这一轮的过程": "Collapse this turn’s steps",
    # 插件包
    "官方 · %lld": "Official · %lld",
    "已安装 · %lld": "Installed · %lld",
    "系统": "System",
    "实验性": "Experimental",
    "正在读取插件包…": "Loading plugin bundles…",
    "这些是组成 DSH 本身的层，不能单独关掉。": "These are the layers DSH itself is made of — they can’t be turned off individually.",
    "全部插件": "All plugins",
    "包里面的单个插件。平时不用管，排查问题时才需要看。":
        "The individual plugins inside each bundle. You rarely need these — only when troubleshooting.",
    "停用这个插件包？": "Disable this plugin bundle?",
    "停用后，这个包里提供的功能会立刻失效（比如 IM Connect 停掉之后频道会话就不再更新）。在电脑上重启 DSH 也能恢复。":
        "Everything this bundle provides stops working immediately (disable IM Connect and channel sessions stop updating). Restarting DSH on your computer restores it.",
    "停用后，依赖它的功能会立刻失效。在电脑上重启 DSH 也能恢复。":
        "Anything depending on it stops working immediately. Restarting DSH on your computer restores it.",
    "系统组件，不能关": "System component — can’t be disabled",
    "不可修改": "Not editable",
    # 输入框：权限 / 上下文 / 统计 / 消息操作
    "权限：": "Permissions: ",
    "改这个会话的文件读写与审批档位": "Change this session’s file access and approval preset",
    "上下文占用 %lld%%": "Context %lld%%",
    "%lld 轮": "%lld turns",
    "%lld 步": "%lld steps",
    "首字 %@": "TTFT %@",
    "%.0f tok/s": "%.0f tok/s",
    "缓存 %.0f%%": "Cache %.0f%%",
    "上下文 %.0f%%": "Context %.0f%%",
    "点进去可以**直接填密钥**：密钥只写不读，存在电脑端的凭据库里。\n\n新增的提供商**至少要有一个模型** —— 一个模型都没有的提供商会保存失败（电脑端会拒绝）。左滑可以删除。":
        "Tap in to **enter the key directly**: keys are write-only and live in your computer’s credential store.\n\nA new provider needs **at least one model** — a provider with none will be rejected by your computer. Swipe to delete.",
    "左滑删除。模型里没在界面上列出的字段（推理档位、模板参数…）会**原样保留**。\n\n模型 id 要和电脑端认的完全一致，否则这个提供商会保存失败。":
        "Swipe to delete. Fields not shown here (reasoning levels, template args…) are **preserved as-is**.\n\nThe model id must match exactly what your computer expects, or the provider will be rejected.",
    "用量 %@": "%@ tok",
    "复制": "Copy",
    "赞": "Good response",
    "踩": "Bad response",
    "从这里分支": "Branch from here",
    # DSHKit 里原本漏掉的
    "与电脑的连接断了：%@": "Lost the connection to your computer: %@",
    "连接已关闭": "The connection was closed",
    # 子代理 / preset
    "子代理": "Subagent",
    "子代理：": "Subagent: ",
    "一次性": "One-shot",
    "常驻": "Persistent",
    "后台": "Background",
    "找不到对应的子代理会话（可能已经不在列表里了）":
        "No matching subagent session — it may no longer exist.",
    "打开这个子代理的会话": "Open this subagent’s session",
    "模式": "Mode",
    "决定这个会话用哪套 agent 配置。名字下面有说明的，按说明选。":
        "Which agent configuration this session uses. When a preset has a description, go by it.",
    # 模型提供商
    "提供商与模型": "Providers & models",
    "新增、删除、修改提供商与模型。密钥不在手机上 —— 提供商配的是环境变量名。":
        "Add, remove, and edit providers and models. Keys aren’t on your phone — providers reference an environment variable.",
    "提供商": "Providers",
    "提供商 · %lld": "Providers · %lld",
    "添加提供商": "Add provider",
    "添加模型": "Add model",
    "模型 · %lld": "Models · %lld",
    "%lld 个模型": "%lld models",
    "容量": "Capacity",
    "上下文窗口": "Context window",
    "单次输出上限": "Max output",
    "标识": "ID",
    "名称": "Name",
    "地址": "Base URL",
    "协议": "API",
    "密钥环境变量": "Key env var",
    "「标识」是别的配置引用这个提供商用的键，建好之后不能改。\n\n「密钥名」是电脑端凭据库里的**名字**，密钥原文在下面单独填。":
        "“ID” is the key other settings use to reference this provider — it can’t change after creation.\n\n“Key name” is the **name** in your computer’s credential store; enter the actual key separately below.",
    "密钥不在手机上：提供商配的是**环境变量名**，真正的 key 在电脑的环境里。左滑可以删除。":
        "Keys aren’t on your phone: providers reference an **environment variable name**; the real key lives in your computer’s environment. Swipe to delete.",
    "左滑删除。模型里没在界面上列出的字段（推理档位、模板参数…）会**原样保留**。":
        "Swipe to delete. Fields not shown here (reasoning levels, template args…) are **preserved as-is**.",
    "模型 id 必须跟服务端认的那个完全一致，写错会选不中。":
        "The model id must match exactly what the server expects — a typo means it can’t be selected.",
    "删除这个提供商？": "Delete this provider?",
    "用它跑着的会话不会立刻停，但之后就选不到它的模型了。":
        "Sessions already using it keep running, but its models can no longer be selected.",
    "这台电脑没有暴露模型提供商设置。": "This computer doesn’t expose provider settings.",
    # 排队 / 插队 / 停止
    "追加排队": "Queue",
    "等这一轮跑完再发出去": "Send it once this turn finishes",
    "立刻插队": "Steer",
    "插进正在跑的这一轮，不再等它跑完": "Inject into the running turn instead of waiting",
    "排队": "Queue",
    "%lld 条排队消息": "%lld queued messages",
    "展开排队消息": "Show queued messages",
    "收起排队消息": "Hide queued messages",
    "编辑排队消息": "Edit queued message",
    "编辑": "Edit",
    "插进这一轮": "Steer into this turn",
    "内容": "Content",
    # 密钥（只写不读）
    "密钥": "API key",
    "已配置": "Configured",
    "未配置": "Not configured",
    "由电脑上的环境变量提供": "Provided by an environment variable on your computer",
    "粘贴 API 密钥": "Paste API key",
    "保存后会覆盖电脑上已有的那个密钥。": "Saving replaces the key already on your computer.",
    "清除这个密钥": "Remove this key",
    "清除这个密钥？": "Remove this key?",
    "清除": "Remove",
    "电脑上那个提供商会立刻用不了，直到重新填一个。":
        "That provider stops working immediately on your computer until you enter a new one.",
    "密钥**只写不读**：走的是已经端到端加密的 iroh 通道，存在电脑端的凭据库里；之后手机只能查到「配过没有」，拉不回原文。":
        "Keys are **write-only**: they travel over the already end-to-end-encrypted iroh channel and live in your computer’s credential store. Your phone can only see whether one is configured — never the value.",
    "排队发送": "Queue",
    # 桌面端对齐：后台任务 / 目标 / 提醒 / 上下文明细 / 引用 / 搜索 / 字号
    "小": "Small",
    "标准": "Standard",
    "大": "Large",
    "特大": "Largest",
    "会话字号": "Session text size",
    "后台任务": "Background jobs",
    "后台任务（%lld 个运行中）": "Background jobs (%lld running)",
    "没有后台任务": "No background jobs",
    "让电脑跑一个后台命令时，它会出现在这里，输出也能实时看。":
        "When a background command runs on your computer, it shows up here — with live output.",
    "运行中": "Running",
    "正在停止": "Stopping",
    "已结束": "Finished",
    "失败": "Failed",
    "已停止": "Stopped",
    "还没有输出…": "No output yet…",
    "没有输出。": "No output.",
    "前面的输出已经被丢掉了（超出上限），下面是能拿到的部分。":
        "Earlier output was dropped (over the limit); below is what’s still available.",
    "停止这个后台任务？": "Stop this background job?",
    "停止": "Stop",
    "重新连接": "Reconnect",
    "%@ 输出": "%@ output",
    "目标": "Goal",
    "目标（进行中）": "Goal (active)",
    "目标内容": "Objective",
    "进行中的目标": "Active goal",
    "已暂停的目标": "Paused goal",
    "受阻的目标": "Blocked goal",
    "未运行的目标": "No active goal",
    "这个会话没有目标": "This session has no goal",
    "目标是「让智能体持续做下去」的长期任务。设一个之后，它会自己接着跑。":
        "A goal is a long-running task the agent keeps working on by itself.",
    "设一个目标": "Set a goal",
    "描述你要它持续做什么": "Describe what it should keep doing",
    "保存之后智能体会持续执行，直到你说停。": "The agent keeps going until you tell it to stop.",
    "暂停目标": "Pause goal",
    "恢复目标": "Resume goal",
    "编辑目标": "Edit goal",
    "清除目标": "Clear goal",
    "上下文占用": "Context usage",
    "系统提示": "System prompt",
    "工具定义": "Tool definitions",
    "对话历史": "Conversation history",
    "合计": "Total",
    "占窗口 %lld%% · %@ / %@": "%lld%% of window · %@ / %@",
    "定时提醒": "Scheduled reminders",
    "没有提醒": "No reminders",
    "读不到提醒": "Couldn’t load reminders",
    "重试": "Retry",
    "在会话里用 `/schedule` 让电脑到点干件事，之后会出现在这里。":
        "Use `/schedule` in a session to have your computer do something on time; it appears here.",
    "左滑删除。新建要在会话里发 `/schedule` —— 服务端的写接口要求传完整记录和乐观并发版本，比命令脆弱得多。":
        "Swipe to delete. Create reminders with `/schedule` in a session — the write API needs a full record plus an optimistic-concurrency version, which is far more fragile than the command.",
    "让电脑到点自己干件事。新建要在会话里发 `/schedule`。":
        "Have your computer do something on time. Create one with `/schedule` in a session.",
    "删除这条提醒？": "Delete this reminder?",
    "提醒": "Reminder",
    "%lld 秒后": "in %llds",
    "指定时刻": "at a set time",
    "每 %lld 小时": "every %lldh",
    "每 %lld 分钟": "every %lldm",
    "每 %lld 秒": "every %llds",
    "每天": "Daily",
    "每周": "Weekly",
    "历史搜索": "History search",
    "历史搜索 · %lld 条": "History · %lld hits",
    "这台电脑没有开启会话搜索索引（session-query 的 openAt 被设成了 never）。":
        "This computer hasn’t enabled the session search index (session-query’s openAt is set to never).",
    "同一工作区": "Same workspace",
    "待办 %lld/%lld": "To-dos %lld/%lld",
    "发消息或创建任务": "Send a message or create a task",
    "正在生成": "Generating",
    "工作中": "Working",
    "工作中，已用时 %@": "Working · %@ elapsed",
    "%lld 分 %lld 秒": "%lldm %llds",
    "%lld 秒": "%llds",
    "目录": "Folder",
    "删除": "Delete",
}

# 哪些插值表达式是整数。判错的后果是英文界面上显示成 `%lld` 字面量，
# 所以这里同时用"名字白名单"和"看 .count / Int( 这两种形状"两条判据。
INT_EXPRESSIONS = {"turn", "count", "minutes", "remainder", "step", "index"}

# 名字里带这些词的插值按整数处理。
# 这是一条**启发式**，不是类型推断 —— 判错的后果是英文界面上显示成 `%lld` 字面量。
# 所以约定是：凡是插进本地化串里的数字，名字要能被这条规则认出来，
# 或者干脆用 `String(format:)` 写显式格式串（Format.duration 就是这么做的）。
INT_NAME_HINTS = ("count", "Count", "failures", "Failures", "attempts", "Attempts",
                  "index", "Index", "step", "Step", "turn", "Turn",
                  "tokens", "Tokens", "bytes", "Bytes", "ms", "Ms", "size", "Size")


def is_integer_expression(inner: str) -> bool:
    stripped = inner.strip()
    if stripped in INT_EXPRESSIONS:
        return True
    if ".count" in stripped or stripped.startswith("Int("):
        return True
    if "prefix(" in stripped or "suffix(" in stripped:
        return False
    # 最后一个标识符里带整数味儿的词
    tail = stripped.split(".")[-1].split("(")[0]
    return any(hint in tail for hint in INT_NAME_HINTS)


def key_for(raw: str) -> str:
    """把源码里的 `\\(expr)` 插值换成 String Catalog 的占位符写法。

    必须按**括号配对**扫描而不是正则：`\\(Format.time(item.time))` 里有一层嵌套，
    `[^)]*` 会在内层 `)` 上停下，切出一堆 `%@)` 之类的垃圾 key。
    """
    out: list[str] = []
    index = 0
    while index < len(raw):
        if raw[index] == "\\" and index + 1 < len(raw) and raw[index + 1] == "(":
            depth = 0
            cursor = index + 1
            while cursor < len(raw):
                if raw[cursor] == "(":
                    depth += 1
                elif raw[cursor] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                cursor += 1
            inner = raw[index + 2:cursor]
            out.append("%lld" if is_integer_expression(inner) else "%@")
            index = cursor + 1
            continue
        out.append(raw[index])
        index += 1
    return "".join(out)


def unescape(raw: str) -> str:
    return raw.replace('\\"', '"').replace("\\n", "\n")


def strip_comments(text: str) -> str:
    r"""把行注释抹掉，保留行号（只把 `//` 之后的部分换成空格）。

    为什么必须做：注释里常会举例说明"别这么写"，例如
    `// （写成 Text("\(index + 1)") 会生成一条 key 为 %lld 的条目）`。
    不抹注释的话这个**反例**会被当成真的调用点抽出来，凭空多一条 `%lld` 的 key ——
    实测踩过。`//` 在字符串字面量里（比如 URL）不算注释，所以要跟踪引号状态。
    """
    out: list[str] = []
    for line in text.split("\n"):
        in_string = False
        escaped = False
        cut = len(line)
        index = 0
        while index < len(line) - 1:
            character = line[index]
            if in_string:
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == '"':
                    in_string = False
            elif character == '"':
                in_string = True
            elif character == "/" and line[index + 1] == "/":
                cut = index
                break
            index += 1
        out.append(line[:cut])
    return "\n".join(out)


def extract() -> dict[str, str]:
    found: dict[str, str] = {}
    for path in sorted([p for base in [SOURCE_DIR, *EXTRA_SOURCE_DIRS] for p in base.rglob("*.swift")]):
        text = strip_comments(path.read_text())
        for pattern in EXTRACTION_PATTERNS:
            for match in re.finditer(pattern, text):
                raw = match.group(1)
                if len(raw) < 2:
                    continue
                found[unescape(raw)] = str(path.relative_to(ROOT))
    return found


def placeholders(text: str) -> list[str]:
    return re.findall(r"%[@dlsf]", text)


def main() -> int:
    check_only = "--check" in sys.argv
    found = extract()

    catalog_strings: dict[str, dict] = {}
    missing: list[str] = []
    mismatched: list[str] = []

    for raw in sorted(found):
        key = key_for(raw)
        english = EN.get(key) or EN.get(raw)
        if english is None:
            missing.append(key)
            english = key
        # 占位符必须对得上：英文里少一个 %lld，界面上就会少一个数字
        if placeholders(key) != placeholders(english):
            mismatched.append(f"{key}  →  {english}")

        entry: dict = {
            "extractionState": "manual",
            "localizations": {
                "en": {
                    "stringUnit": {"state": "translated", "value": english},
                }
            },
        }
        if key != raw:
            # 有插值的 key：源语言那一侧必须是**占位符形式**（%@ / %lld），
            # 不是源码里的 \(expr)。写成源码形式的话，SwiftUI 在 zh-Hans 下查不到
            # 带占位符的值，就会退化成把 key 当字面量显示。
            entry["localizations"][SOURCE_LANGUAGE] = {
                "stringUnit": {"state": "translated", "value": key}
            }
        catalog_strings[key] = entry

    # 第三类错误：值里混进了源码形式的插值。这正是"界面上直接把
    # `\(model.localEndpointId.prefix(16))` 显示出来"那个 bug 的形状 ——
    # 源语言那一侧写了源码表达式而不是占位符，SwiftUI 就查不到带占位符的值。
    literal_interpolation = [
        f"{key}  →  {value}"
        for key, value in [(k, v["localizations"][SOURCE_LANGUAGE]["stringUnit"]["value"])
                           for k, v in catalog_strings.items()
                           if SOURCE_LANGUAGE in v["localizations"]]
        if "\\(" in value
    ]

    problems = []
    if literal_interpolation:
        problems.append(
            f"值里出现了源码形式的插值 {len(literal_interpolation)} 条（应该写成 %@ / %lld）：\n  "
            + "\n  ".join(literal_interpolation[:10])
        )
    if missing:
        problems.append(f"缺少英文翻译 {len(missing)} 条：\n  " + "\n  ".join(missing[:20]))
    if mismatched:
        problems.append(f"占位符不一致 {len(mismatched)} 条：\n  " + "\n  ".join(mismatched[:20]))

    if problems:
        print("\n\n".join(problems), file=sys.stderr)
        if check_only:
            return 1

    if check_only:
        print(f"本地化检查通过：{len(catalog_strings)} 条，zh-Hans 与 en 都有文案")
        return 0

    catalog = {
        "sourceLanguage": SOURCE_LANGUAGE,
        "strings": catalog_strings,
        "version": "1.0",
    }
    CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(f"已写入 {CATALOG.relative_to(ROOT)}：{len(catalog_strings)} 条文案（zh-Hans → en）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
