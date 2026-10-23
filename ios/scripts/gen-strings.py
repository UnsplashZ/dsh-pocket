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

# 旧正则抽取模式（已弃用，仅留作形状对照参考；三元 / return / 单独成行三种
# 形状当时也在其中）。正则的字符类会在插值内层引号上停下、把字面量截成假 key；
# 现在的抽取是**配对感知的扫描器 + 前后文核对**（见 read_string_literal / extract()）。
EXTRACTION_PATTERNS_DEPRECATED = [
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
    r'SecureField\(\s*"((?:[^"\\]|\\.)*)"',
    # `.help(_:)` 收的是 `LocalizedStringKey`，字面量同样要进 catalog ——
    # 不进的话中文机器上一切正常，英文机器上冒出一句中文。
    #
    # 这几个都允许 `(` 与字面量之间换行：真实调用点常写成多行形式，写死 `\("` 会整片漏掉。
    r'\.help\(\s*"((?:[^"\\]|\\.)*)"\s*\)',
    r'\.alert\(\s*"((?:[^"\\]|\\.)*)"',
    r'\.confirmationDialog\(\s*"((?:[^"\\]|\\.)*)"',
    r'\.accessibilityLabel\(\s*"((?:[^"\\]|\\.)*)"',
    r'LabeledContent\(\s*"((?:[^"\\]|\\.)*)"',
    r'ProgressView\(\s*"((?:[^"\\]|\\.)*)"',
]

# 现在的调用形状表：字面量**之前**的形状（`$` 锚定）+ 字面量**之后**必须紧跟的
# 形状（`^` 锚定；None 表示不查）。与上面的弃用列表一一对应。
CALL_SHAPES = [
    (r"String\(localized:\s*$", None),
    (r"Text\($", r"\)"),
    (r"Label\($", None),
    (r"\.navigationTitle\($", r"\)"),
    (r"ContentUnavailableView\(\s*$", None),
    (r"Button\($", None),
    (r"Section\($", r"\)"),
    (r"Toggle\($", None),
    (r"TextField\($", None),
    (r"Picker\($", None),
    (r"SecureField\(\s*$", None),
    # `.help(_:)` 收的是 `LocalizedStringKey`，字面量同样要进 catalog ——
    # 不进的话中文机器上一切正常，英文机器上冒出一句中文。
    (r"\.help\(\s*$", r"\s*\)"),
    (r"\.alert\(\s*$", None),
    (r"\.confirmationDialog\(\s*$", None),
    (r"\.accessibilityLabel\(\s*$", None),
    (r"LabeledContent\(\s*$", None),
    (r"ProgressView\(\s*$", None),
    # `return "文案"`：返回位置的字面量（枚举的 `var label` 之类）。
    # 返回类型是 `LocalizedStringKey` 的已经是对的，返回类型是 `String` 的必须自己
    # 包一层 `String(localized:)` —— `Text(String)` 是 verbatim 语义，不查目录。
    (r"\breturn\s+$", None),
]
COMPILED_CALL_SHAPES = [(re.compile(prefix), None if tail is None else re.compile(tail))
                        for prefix, tail in CALL_SHAPES]

# 三元的两半：`cond ? "A" : "B"`。两个分支都要本地化，而调用形状看不出来
# ——"发送 / 排队发送"那颗主按钮就是这种形状（见 #1）。
TERNARY_BEFORE = re.compile(r"\?\s*$")
# 配不到 `: "B"` 的 `?`（比如 `x ?? "默认"`）不收 —— 那是空合并，不是二元文案。
TERNARY_BETWEEN = re.compile(r"\s*:\s*")

# 兜底扫描用：日志、断言、调试输出里的中文字面量不会进界面，不该要求翻译。
NOT_USER_FACING_LINE = re.compile(r"logs\.log\(|logger\??\.log\(|XCTAssert|\bprint\(|fatalError|\bassert\(")

# 只给人看的机器文本（诊断导出的纯文本、协议里的字段名等）。每一条都写理由 ——
# 这个名单本身就是"为什么它可以不翻译"的记录。空着是有意的：宁可多翻译几条，
# 也别靠名单把漏网的字面量悄悄放过去。
NOT_LOCALIZED: dict[str, str] = {
    # `statTexts(...).joined(separator: "，")` —— 这是**分隔符**，不是写给读者的话。
    "，": "分隔符（拼接 accessibilityLabel 用），不是文案",
    # 附件落盘用的文件名，会写进会话数据。翻译它等于改数据，不是改界面。
    "照片.\\(ext)": "附件文件名（会写进会话数据），不是界面文案",
}

# `TetherDiscovery` 的解析细节 + `AppModel` 里做前缀剥离/类型判断用的字面量：
# **都只进日志**，不是界面文案。放名单而不是写成 `String(localized:)`，是因为
# 它们描述的是 DNS 报文和错误链的内部细节 —— 翻成英文反而会在排障时对不上
# iroh 的原始报错（那些报错本身是英文）。
for _diagnostic in (
    "应答太短", "应答段损坏", "应答被截断", "截断", "问题段损坏",
    "查询报文构造失败", "没有解析器返回结果", "两个解析器都没回（\\(lastFailure)）",
    "端点 ID 不是合法的 64 位十六进制", "解析器地址不合法：\\(server)",
    "\\(hint.addresses.count) 条直连", "\\(outcome.server) · \\(elapsed)ms · 记录存在但没有任何地址",
    "socket() 失败", "发送失败（\\(sent)）", "\\(server) 没有回应",
    "连接失败：", "与电脑的连接已断开：", "与电脑的连接断了：", "超时",
    # 会话流窗口选择的诊断文案（只进日志）
    "首屏",
):
    NOT_LOCALIZED.setdefault(_diagnostic, "诊断/匹配用字面量（只进日志），不是界面文案")

# 字面量扫描统一走 `read_string_literal` / `iter_string_literals`（配对感知）。
# 曾经用正则 `[^"\\]` 扫，插值里再嵌一对引号的那种
# （`"RTT：\(m.map { "\($0)ms" } ?? "—")"`）会被截断成一个假 key —— 已修。
# 中文（含扩展区）、CJK 标点、全角形式。用 `[^\x00-\x7F]` 更省事，但那会把
# `"—"`、`"…"` 这种纯排版的字面量也算进来 —— 它们不需要翻译，只会制造噪声。
HAS_CJK = re.compile(r"[\u2e80-\u9fff\u3000-\u303f\uff00-\uffef]")
# 只要汉字（不含标点）：单字文案（"小" / "大"）靠它才能被当成文案收下，
# 而 `"—"`、`"："` 这类纯标点字面量不会被误收。
HAS_IDEOGRAPH = re.compile(r"[\u4e00-\u9fff]")

# `return "文案"` 有两种命运，抽取模式认不出类型，所以这里单独兜一条：
#   · 返回类型是 `LocalizedStringKey` —— 本来就有效（SwiftUI 会去查目录），放行；
#   · 返回类型是 `String` —— 只进目录、运行时不查（`Text(String)` 是 verbatim 语义），
#     必须写成 `return String(localized: "文案")`。
RETURN_LITERAL_LINE = re.compile(r'\breturn\s+"')
DECLARATION_LINE = re.compile(
    r"^\s*(?:(?:public|private|internal|fileprivate|open|static|final)\s+)*(?:var|func)\s+\w+[^{]*\{\s*$"
)

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
    "新对话": "New chat",
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
    # 文件预览（产物卡点开 / 工作区文件点开）
    "再打开一次": "Open again",
    "已取回": "Fetched",
    "打不开这个文件": "Can’t open this file",
    "正在从电脑取回…": "Fetching from your computer…",
    "点按预览这个文件": "Tap to preview this file",
    "文件太大，只显示了开头部分": "This file is too large — showing the beginning only",
    "图片预览": "Image preview",
    "这个图片打不开": "This image can’t be opened",
    "文件取回来了，但不是这个 App 认得的图片格式。": "The file was fetched, but it isn’t an image format this app recognises.",
    "读文件失败": "Couldn’t read the file",
    "读文件没有拿到 HTTP 响应": "Reading the file returned no HTTP response",
    "读文件的响应不是 multipart": "The file response was not multipart",
    "读文件的响应里没有文件内容": "The file response contained no file content",
    "这条产物没有文件路径，打不开": "This deliverable has no file path, so it can’t be opened",
    "远端返回了一个错误": "The remote side returned an error",
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
    "连接": "Connect",
    "复制": "Copy",
    "已复制": "Copied",

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
    "文本、Markdown、图片、PDF 都能直接看，不下载到别处": "Text, Markdown, images and PDFs preview in place — nothing is copied elsewhere",
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
    "主机版本": "Host version",
    "协议": "Protocol",
    "协议基线": "Protocol baseline",
    "传输": "Transport",
    "第三方组件与许可": "Third-party components and licenses",
    "隐私与安全边界": "Privacy and security boundaries",
    "第三方组件": "Third-party components",
    "本项目以 MIT 许可发布。以上组件各自保留原许可与版权声明。":
        "This project is released under the MIT license. Each component above keeps its own license and copyright notice.",
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
    "会话已归档": "Session archived",
    "已归档": "Archived",
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
    "清缓存": "Clear cache",
    "清掉已归档会话的本地缓存（不影响未归档的）":
        "Clear the local cache for archived sessions only.",
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
    "执行中": "Working",
    "等待回复": "Waiting for you",
    "不可用": "Unavailable",
    "已完成": "Done",
    "新对话": "New chat",
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
    "文件": "File",
    "模型": "Model",
    "权限": "Permissions",
    "目标": "Goal",
    "执行中": "Working",
    "等待回复": "Waiting for you",
    "不可用": "Unavailable",
    "已完成": "Done",
    "新对话": "New chat",
    "目录": "Folder",
    "插队给这一轮": "Steer into this turn",
    # 连接失败的可执行提示
    "上一次连接还在进行中": "A connection attempt is already in progress",
    "连接已取消": "Connection cancelled",
    "已退到后台，跳过这次连接": "The app moved to the background — skipping this attempt",
    "如果电脑端重装过插件或清过配对数据，请在「设置 → 主机」里删掉这台电脑，然后重新配对。":
        "If the plugin was reinstalled or its pairing data was cleared on your computer, delete this computer under Settings → Computers and pair again.",
    "网络看起来解析不到这台电脑的地址，正在后台继续重试。如果一直这样，检查手机的网络、代理或 VPN（它们常会拦掉 DNS 查询）。":
        "The phone can’t resolve this computer’s address — still retrying in the background. If this keeps happening, check the phone’s network, proxy or VPN (they often block DNS lookups).",
    "找不到这台电脑的地址（DNS 暂时不可用），正在重试": "Can’t resolve this computer’s address (DNS is temporarily unavailable) — retrying",
    "连接已断开": "The connection was lost",
    "连接超时（%@ 秒），正在重试": "Connection timed out (%@s) — retrying",
    "连接未完成": "The connection didn’t complete",
    "思考中": "Thinking",
    "正在写回复": "Writing a reply",
    "正在思考": "Reasoning",
    "传输层：%@": "Transport: %@",
    "健康": "healthy",
    # 会话正在等第一份快照（屏幕上先显示缓存）
    "正在同步最新内容": "Syncing the latest content",
    "重连续拉（只差 %@ 条）": "Reconnect resume (only %@ events behind)",
    "重连续拉（落后 %@ 条，用大窗口）": "Reconnect resume (%@ events behind — using a larger window)",
    "屏幕上先显示本机缓存，最新几条还在从电脑上取": "Showing cached content first — the newest messages are still coming from your computer",
    # 会话加载骨架（慢的时候要能看见"还在动"）
    "正在读取会话内容…": "Loading this conversation…",
    "正在读取会话内容…已等 %@ 秒": "Loading this conversation… %@s so far",
    # 寻址解析的诊断片段（只进日志/诊断页，但走的是 String(localized:) 路径）
    "无 relay": "no relay",
    "解析器返回错误码 %@": "the resolver returned error code %@",
    "记录不存在（NXDOMAIN）": "no such record (NXDOMAIN)",
    "如果是装完 App 第一次启动，请到「设置 → 隐私与安全性 → 本地网络」确认 DSH Pocket 是开的 —— 关着的话 iOS 会静默丢包，看起来就是一直连接中。":
        "If this is the first launch after installing, check Settings → Privacy & Security → Local Network and make sure DSH Pocket is allowed — with it off, iOS silently drops packets and it looks like “connecting” forever.",
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
    "新对话": "New chat",
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
    "执行中": "Working",
    "等待回复": "Waiting for you",
    "不可用": "Unavailable",
    "已完成": "Done",
    "新对话": "New chat",
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
    "文件": "File",
    "模型": "Model",
    "权限": "Permissions",
    "目标": "Goal",
    "执行中": "Working",
    "等待回复": "Waiting for you",
    "不可用": "Unavailable",
    "已完成": "Done",
    "新对话": "New chat",
    "目录": "Folder",
    "删除": "Delete",

    # ── #1 的收尾：过去靠调用点形状抽取，漏掉了一整批面向人的文案 ──────────
    # 现在抽取模式与兜底扫描都补上了，这些是随之补写的英文。
    "# DSH Pocket 诊断": "# DSH Pocket diagnostics",
    "## 你\n%@\n": "## You\n%@\n",
    "## 助手\n%@\n": "## Assistant\n%@\n",
    "## 日志": "## Log",
    "DSH_Mobile 协议文档": "DSH_Mobile protocol docs",
    "RTT：%@": "RTT: %@",
    "[图片]": "[image]",
    "%@，%@，%@": "%@, %@, %@",
    "%@：%@": "%@: %@",
    "：%@": ": %@",
    "follow 的 event 帧缺少 event": "follow event frame is missing \"event\"",
    "fork 没有返回 sessionId": "fork did not return a sessionId",
    "iroh 端点绑定失败：%@": "iroh endpoint bind failed: %@",
    "mux：%@": "mux: %@",
    "result 缺少 ok": "result is missing ok",
    "session/create 没有返回 sessionId": "session/create did not return a sessionId",
    "· 工具 %@ (%@)\n%@\n": "· Tool %@ (%@)\n%@\n",
    "一次尝试未产出内容": "A turn produced no output",
    "上传失败": "Upload failed",
    "上传结果缺少 receiptId": "Upload result is missing receiptId",
    "上游协议，不改源码": "Upstream protocol; source not modified",
    "不是 HTTP 响应": "Not an HTTP response",
    "不是合法的 JSON 值": "Not a valid JSON value",
    "与电脑的连接已断开：%@": "Connection to your computer was lost: %@",
    "从电脑上把历史取回来 ": "Fetching history from your computer ",
    "代理：%@": "Proxy: %@",
    "会话事件 %@ 缺少 seq": "Session event %@ is missing seq",
    "会话事件 %@ 缺少 time": "Session event %@ is missing time",
    "会话事件缺少 type": "Session event is missing type",
    "保存失败": "Save failed",
    "信封 type 不是 server-response": "Envelope type is not server-response",
    "信封缺少 result": "Envelope is missing result",
    "其它": "Other",
    "启用": "Enabled",
    "命令": "Command",
    "命令失败": "Command failed",
    "命令完成": "Command finished",
    "响应不是 JSON：%@": "Response is not JSON: %@",
    "子 agent": "Sub-agent",
    "宿主响应无法解析：%@": "Could not parse the host response: %@",
    "宿主返回 HTTP %@%@": "Host returned HTTP %@%@",
    "宿主返回了一个未说明的错误": "The host returned an unexplained error",
    "密钥名": "Key name",
    "尚未连接到电脑": "Not connected to your computer yet",
    "会话流已结束": "The session stream ended",
    "点按重试": "Tap to retry",
    "工具": "Tool",
    "已有一次连接正在进行": "A connection is already in progress",
    "开代理流失败：%@": "Failed to open the proxy stream: %@",
    "把排队里的第一条插进正在跑的这一轮": "Move the first queued message into the running turn",
    "把输入框里的内容插进正在跑的这一轮": "Insert the composer content into the running turn",
    "控制流未建立": "Control stream was not established",
    "撤销评价被拒": "Un-rating was rejected",
    "无法构造上传 URL": "Could not build the upload URL",
    "无法编码为 UTF-8": "Could not encode as UTF-8",
    "未知的 follow 帧：%@": "Unknown follow frame: %@",
    "本地代理启动失败：%@": "Local proxy failed to start: %@",
    "模型 id": "Model id",
    "正在读取这条会话的内容 ": "Loading this session ",
    "流出错：%@": "Stream error: %@",
    "流错误": "Stream error",
    "状态：%@": "Status: %@",
    "电脑 %@": "Computer %@",
    "电脑端关闭了控制流": "The computer closed the control stream",
    "监听被取消": "Listening was cancelled",
    "端口 %@ 不在合法范围": "Port %@ is out of range",
    "端点 ID 不合法（应为 64 位十六进制）：%@": "Invalid endpoint ID (expected 64 hex digits): %@",
    "等待电脑端应答超时": "Timed out waiting for the computer to reply",
    "绑定套接字：%@": "Bound sockets: %@",
    "认不出": "Unrecognized",
    "设备 ID：%@": "Device ID: %@",
    "评价被拒": "Rating was rejected",
    "路径：%@": "Path: %@",
    "这一轮被中断": "This turn was interrupted",
    "远端拒绝了这次应答": "The remote rejected this response",
    "连接已断开：%@": "Connection closed: %@",
    "配对应答无法解析：%@": "Could not parse the pairing reply: %@",
    "配对时收到意外消息：%@": "Unexpected message during pairing: %@",
    "附件数据不是合法 base64": "Attachment data is not valid base64",
    "首个 follow 帧不是 snapshot": "The first follow frame is not a snapshot",
    # ── 2026-10-14 缺口收口（ADR-0027）新增 ─────────────────────────────
    "描述你的任务以生成计划": "Describe your task to generate a plan",
    "这轮还没有待办": "No to-dos for this turn yet",
    "这个会话由子代理托管，请到它的父会话里操作。":
        "This session is managed by a subagent. Use its parent session instead.",
    "工作中，至少已用时 %@": "Working · at least %@ elapsed",

    # ── 0.5.0 多路接入（uplink）─────────────────────────────────────────
    "多路接入": "Multi-path",
    "局域网": "LAN",
    "自建中转": "Self-hosted relay",
    "已配对的电脑": "Paired computer",
    "粘贴电脑上显示的配对串（dshuplink://…）": "Paste the pairing link from your computer (dshuplink://…)",
    "配对": "Pair",
    "重新配对": "Pair again",
    "忘记这台电脑": "Forget this computer",
    "重新探测": "Probe again",
    "已关闭": "Off",
    "未选档": "No path selected",
    "票据": "Ticket",
    "还剩 %@ 秒": "%@ s left",
    "档位：%@": "Path: %@",
    "网关：%@": "Gateway: %@",
    # 错误与诊断
    "上一次探测还在进行中": "A probe is still running",
    "上一次用的 %@ 这次没通，换到 %@": "The previous path %@ did not respond — switched to %@",
    "所有档位都被关掉了。至少打开一个，或者换回 iroh。":
        "Every path is turned off. Turn one back on, or switch back to iroh.",
    "所有档位都连不上。检查手机和电脑是否在同一网络，或者换一个档位再试。":
        "No path is reachable. Check that the phone and the computer are on the same network, or try another path.",
    "没有可用的档位": "No usable path",
    "还没有配对这台电脑。请让电脑端显示配对串，然后粘贴到这里。":
        "This computer is not paired yet. Show the pairing link on your computer and paste it here.",
    "配对串认不出来。它应该以 dshuplink:// 开头，后面是一整段字符 —— 别只复制半截。":
        "That pairing link is not readable. It should start with dshuplink:// followed by one long run of characters — make sure you copied all of it.",
    "这个地址上是另一台电脑（期望 %@…，实际 %@…），已跳过。":
        "That address belongs to another computer (expected %@…, got %@…) — skipped.",
    "电脑拒绝了这台手机（%@）。多半是电脑端重装过插件或清过配对数据，重新配一次就好。":
        "Your computer rejected this phone (%@). This usually means the plugin was reinstalled or the pairing data was cleared — pairing again fixes it.",
    "票据被拒（%@）。请在电脑端确认这台设备还在授权列表里。":
        "The ticket was rejected (%@). Check that this device is still in the authorized list on your computer.",
    "电脑回了一个意外的状态码 %@。": "Your computer returned an unexpected status code %@.",
    "电脑回的响应看不懂：%@": "Could not parse the response from your computer: %@",
    "连不上：%@": "Can’t connect: %@",
    "不是 JSON": "not JSON",

    # ── 0.5.0 多路接入：网络类型 / 探测失败分类 / iroh 兜底 ──────────────
    "当前网络": "Network",
    "网络：%@": "Network: %@",
    "蜂窝网络": "Cellular",
    "有线网络": "Ethernet",
    "无网络": "Offline",
    "其他网络": "Other network",
    "未知网络": "Unknown network",
    "当前在蜂窝网络，局域网不可达": "Skipped: LAN is unreachable on cellular",
    "当前在蜂窝网络，局域网地址不可达。需要配置 iroh 兜底 / Tailscale / 自建中转才能在外面连。":
        "You are on cellular, so LAN addresses are unreachable. Configure the iroh fallback / Tailscale / a self-hosted relay to connect from outside.",
    "当前网络下没有可用的地址（跳过 %@ 个档位）。": "No usable address on this network (%@ paths skipped).",
    "手机现在没有网络连接。先确认 Wi-Fi 或蜂窝数据是开的。":
        "The phone has no network right now. Check that Wi-Fi or cellular data is on.",
    "手机当前没有网络连接。": "The phone has no network connection.",
    "没有可探测的地址。": "There is no address to probe.",
    "超时：可能不在同一网络、iOS「本地网络」权限没开，或者 VPN 拦了请求。":
        "Timed out: you may be on a different network, iOS Local Network permission may be off, or a VPN is blocking the request.",
    "连接被拒：地址是通的，但那个端口上没有服务（电脑端网关没起，或被防火墙挡了）。":
        "Connection refused: the address responds, but nothing is listening on that port (gateway not running, or blocked by a firewall).",
    "解析不到这个地址（DNS / mDNS 没回应）。": "This address does not resolve (no DNS / mDNS answer).",
    "这个地址上是另一台电脑，不是已配对的那台。":
        "That address belongs to a different computer, not the paired one.",
    "探测失败：%@": "Probe failed: %@",
    "%lld 个地址都没试通：手机现在没有网络。先确认 Wi-Fi 或蜂窝数据是开的。":
        "None of the %lld addresses worked: the phone has no network. Check that Wi-Fi or cellular data is on.",
    "%lld 个地址都超时了：可能不在同一网络、iOS「本地网络」权限没开，或者 VPN 把请求劫持了。":
        "All %lld addresses timed out: you may be on a different network, iOS Local Network permission may be off, or a VPN is intercepting requests.",
    "%lld 个地址都拒绝连接：电脑上的网关可能没在跑，或者被防火墙挡了。":
        "All %lld addresses refused the connection: the gateway on your computer may not be running, or a firewall is blocking it.",
    "%lld 个地址都解析不到：多半是 DNS 或 VPN 的问题。":
        "None of the %lld addresses could be resolved — usually a DNS or VPN problem.",
    "%lld 个地址上都不是已配对的那台电脑，请重新配对。":
        "%lld addresses belong to a different computer — pair again.",
    "%lld 个地址都不通，原因见下方每一档的说明。":
        "None of the %lld addresses are reachable; see the per-path details below.",
    # iroh 兜底
    "iroh 兜底": "iroh fallback",
    "已配对": "Paired",
    "未配对": "Not paired",
    "电脑端没有启用 iroh 兜底档。": "The iroh fallback is not enabled on your computer.",
    "已配对（电脑端确认）": "Paired (confirmed by your computer)",
    "已配对（本地记录）": "Paired (local record)",
    "强制用 iroh 兜底试一次": "Try the iroh fallback now",
    "手动触发 iroh 兜底": "iroh fallback triggered manually",
    "iroh 兜底已连上": "The iroh fallback is connected",
    "没连上：%@": "Not connected: %@",
    "配对串里没有 iroh 信息，测不了兜底。请重新粘贴一次配对串。":
        "This pairing link has no iroh information, so the fallback cannot be tested. Paste the pairing link again.",
    "配对码已用过或过期，需要一张新的。": "The pairing code was used or has expired; a new one is needed.",
    "现在连不上网关，暂时换不到新的配对码（不影响当前连接）。":
        "No gateway is reachable right now, so a new pairing code cannot be fetched (your current connection is unaffected).",
    "电脑端的 iroh 白名单里没有这台手机。": "This phone is not in your computer’s iroh allow-list.",
    "现在连不上这台电脑，iroh 兜底也还没配好。请在电脑上重新生成配对串，再回到 App 里粘贴一次。":
        "This computer is unreachable and the iroh fallback is not paired yet. Generate a new pairing link on your computer and paste it here again.",
    "换不到 iroh 配对码": "Could not get an iroh pairing code",
    "换 iroh 配对码失败：%@": "Could not get an iroh pairing code: %@",
    "现在一个地址都不通，换不到 iroh 配对码。请先回到能连上这台电脑的网络。":
        "No address is reachable right now, so an iroh pairing code cannot be fetched. Get back to a network where this computer is reachable.",
    "配对码已过期。请在电脑上重新生成配对串（电脑端的「连接手机」里点一次生成），然后重新粘贴。":
        "The pairing code has expired. Generate a new pairing link on your computer (tap “Connect phone” again) and paste it here.",
    # ── 0.5.2：只保留多路接入 / 本地回环代理 / ATS ─────────────────────
    "建议重新配对": "Pair again to enable multi-path",
    "改回多路接入": "Switch back to multi-path",
    "正常使用请改回「多路接入」": "Switch back to “multi-path” for normal use",
    "这台手机还在用旧的 iroh 配对。建议到「设置 → 多路接入」里重新粘贴一次配对串：之后局域网 / 虚拟组网会更快，iroh 仍然作为兜底。":
        "This phone still uses the old iroh pairing. Paste a pairing link again under Settings → Multi-path: LAN and virtual networks will be faster, and iroh still works as the fallback.",
    "一个配对串同时配好局域网 / Tailscale / ZeroTier / 自建中转**和 iroh 兜底**，哪条通走哪条。在外面（蜂窝网络）时自动用 iroh。配对串在电脑端的「连接手机」里生成。":
        "One pairing link sets up LAN / Tailscale / ZeroTier / self-hosted relay **and the iroh fallback**, and whichever path works is used. On cellular it switches to iroh automatically. Generate the link on your computer under “Connect phone”.",
    "本地代理：%@": "Local proxy: %@",
    "本地代理起不来：%@": "Could not start the local proxy: %@",
    "本地代理的监听被取消": "The local proxy listener was cancelled",
    "这一档的地址解析不出 host/port，已跳过。": "This path's address has no usable host/port — skipped.",
    "被 iOS 的 ATS 拦下了（明文 http 只放行本地地址）。这是 App 的 bug：uplink 的请求应当走本地回环代理。":
        "Blocked by iOS ATS (plain HTTP is only allowed to local addresses). This is an app bug: uplink requests should go through the local loopback proxy.",
    "%lld 个地址被 iOS 的 ATS 拦下了：uplink 的请求应该走本地回环代理，这是 App 的 bug，请把诊断日志发给我们。":
        "%lld addresses were blocked by iOS ATS: uplink requests should go through the local loopback proxy. This is an app bug — please send us the diagnostic log.",
    "地址清单来自电脑端的配对串，探测全不通时还会用 Bonjour 找一次电脑现在的地址。RTT 是最近一次探测的结果，「—」表示这次没测到（另一档先通了，或当前网络下不可达）。":
        "The address list comes from the pairing link; when nothing responds the app also runs a Bonjour lookup for the computer’s current address. RTT is from the latest probe; “—” means it was not measured (another path answered first, or it is unreachable on this network).",
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


def read_string_literal(text: str, start: int) -> tuple[str, int] | None:
    """从 `text[start] == '"'` 开始读一个 Swift 字符串字面量。

    返回 `(raw, end)`：raw 是引号之间的原文（转义序列与 `\\(…)` 插值都保持原样，
    留给 `unescape` / `key_for` 处理），end 是闭合引号的下一个下标。
    读不到闭合引号（换行 / 文件尾）返回 None。

    与正则的本质区别：插值 `\\(…)` 里可以再嵌**带引号的字符串**
    （`"RTT：\\(m.map { "\\($0)ms" } ?? "—")"`），这里按括号配对 + 递归跳过嵌套
    字面量处理，不会在内层引号上截断。三引号多行字符串不属于这个函数
    （调用方在 `iter_string_literals` 里整块跳过）。
    """
    if text.startswith('"""', start):
        return None
    cursor = start + 1
    out: list[str] = []
    while cursor < len(text):
        character = text[cursor]
        if character == "\\":
            if cursor + 1 < len(text) and text[cursor + 1] == "(":
                # 插值：括号配对扫描，嵌套字符串字面量递归跳过（里面的引号不算数）。
                depth = 1
                probe = cursor + 2
                while probe < len(text) and depth > 0:
                    symbol = text[probe]
                    if symbol == '"':
                        nested = read_string_literal(text, probe)
                        if nested is None:
                            return None
                        probe = nested[1]
                        continue
                    if symbol == "\\":
                        probe += 2
                        continue
                    if symbol == "(":
                        depth += 1
                    elif symbol == ")":
                        depth -= 1
                    probe += 1
                if depth != 0:
                    return None
                out.append(text[cursor:probe])
                cursor = probe
                continue
            out.append(text[cursor:cursor + 2])
            cursor += 2
            continue
        if character == '"':
            return "".join(out), cursor + 1
        if character == "\n":
            return None
        out.append(character)
        cursor += 1
    return None


def iter_string_literals(text: str) -> list[tuple[int, str, int]]:
    """产出全文所有单行字符串字面量 `(start, raw, end)`；三引号多行块整块跳过。

    旧实现按行跑正则，插值里嵌引号的字面量会被截断。这里按扫描器走，
    拿到的永远是完整字面量。
    """
    found: list[tuple[int, str, int]] = []
    cursor = 0
    while cursor < len(text):
        if text.startswith('"""', cursor):
            closing = text.find('"""', cursor + 3)
            cursor = len(text) if closing == -1 else closing + 3
            continue
        if text[cursor] == '"':
            result = read_string_literal(text, cursor)
            if result is None:
                cursor += 1
                continue
            raw, end = result
            found.append((cursor, raw, end))
            cursor = end
            continue
        cursor += 1
    return found


def is_standalone_line(text: str, start: int, end: int) -> bool:
    """字面量单独成行：`{ "…" }` 隐式返回那种（旧模式 `^\\s*"…"\\s*,?$`）。**"""
    line_start = text.rfind("\n", 0, start) + 1
    line_end = text.find("\n", end)
    if line_end == -1:
        line_end = len(text)
    before = text[line_start:start].strip()
    after = text[end:line_end].strip()
    return before == "" and after in ("", ",")


def extract() -> dict[str, str]:
    found: dict[str, str] = {}
    for path in sorted([p for base in [SOURCE_DIR, *EXTRA_SOURCE_DIRS] for p in base.rglob("*.swift")]):
        text = strip_comments(path.read_text())
        relative = str(path.relative_to(ROOT))
        for start, raw, end in iter_string_literals(text):
            candidates = [raw]
            before = text[max(0, start - 200):start]
            matched = False
            # 三元：`? "A" : "B"` 两半都收；配不到 `: "B"` 的 `?`（`x ?? "默认"`）不收。
            if TERNARY_BEFORE.search(before):
                gap = TERNARY_BETWEEN.match(text, end)
                if gap and gap.end() < len(text) and text[gap.end()] == '"':
                    second = read_string_literal(text, gap.end())
                    if second is not None:
                        candidates.append(second[0])
                        matched = True
            if not matched:
                after = text[end:end + 64]
                matched = any(
                    prefix.search(before) and (tail is None or tail.match(after))
                    for prefix, tail in COMPILED_CALL_SHAPES
                )
            if not matched:
                matched = is_standalone_line(text, start, end)
            if not matched:
                continue
            for candidate in candidates:
                value = unescape(candidate)
                # 只收**面向人**的字面量：含中文，或者本来就在 EN 里管着
                #（`"%@% · %@ / %@"` 这种纯格式 key 就是这样保住的）。
                # 少了这一条，放宽后的形状会把 `"Hm"`、`"MMMdHm"`（日期模板）、
                # `"DEBUG"`（日志级别）这些技术字符串也当成待翻译文案。
                if not HAS_CJK.search(value) and key_for(value) not in EN:
                    continue
                found[value] = relative
    return found


def unwrapped_string_returns() -> list[str]:
    """`return "文案"` 落在**非** `LocalizedStringKey` 的返回位置上 —— 抽取得到、运行时查不到。

    这是这个工具唯一不能只靠正则解决的类型问题：同一个 `return "浅色"`，
    在 `var label: LocalizedStringKey` 里是对的，在 `var message: String` 里就是白搭。
    所以这一条单独判：往回找最近的声明行，看它有没有写 `LocalizedStringKey`。
    找不到声明就放行（宁可漏报，也别在没法判断时报一堆假警）。
    """
    complaints: list[str] = []
    for path in sorted([p for base in [SOURCE_DIR, *EXTRA_SOURCE_DIRS] for p in base.rglob("*.swift")]):
        lines = strip_comments(path.read_text()).splitlines()
        for index, line in enumerate(lines):
            if not RETURN_LITERAL_LINE.search(line):
                continue
            # 已经包好的、或本来就不含中文的，都放行。
            if "String(localized:" in line or not HAS_CJK.search(line):
                continue
            declaration = None
            for back in range(index - 1, max(-1, index - 60), -1):
                if DECLARATION_LINE.match(lines[back]):
                    declaration = lines[back]
                    break
            if declaration is None or "LocalizedStringKey" in declaration:
                continue
            complaints.append(f"{path.relative_to(ROOT)}:{index + 1}  {line.strip()[:88]}")
    return complaints


def scan_chinese_literals() -> dict[str, str]:
    """独立扫一遍源码里所有含中文的双引号字面量，不管它长在什么调用形状上。

    抽取模式只能覆盖它列出来的形状，而漏掉的形状在界面上表现为"英文设备上显示中文"——
    不会有人去数，只能靠这条兜底扫描把它顶出来。它和抽取是**两件事**：
    抽取回答"要翻译哪些"，兜底回答"还有没有没被抽取的"。
    """
    found: dict[str, str] = {}
    for path in sorted([p for base in [SOURCE_DIR, *EXTRA_SOURCE_DIRS] for p in base.rglob("*.swift")]):
        text = strip_comments(path.read_text())
        for number, line in enumerate(text.splitlines(), 1):
            if NOT_USER_FACING_LINE.search(line):
                continue
            for _, literal, _ in iter_string_literals(line):
                raw = unescape(literal)
                if not HAS_CJK.search(raw):
                    continue
                if raw in NOT_LOCALIZED:
                    continue
                found.setdefault(raw, f"{path.relative_to(ROOT)}:{number}")
    return found


def placeholders(text: str) -> list[str]:
    return re.findall(r"%[@dlsf]", text)


def selftest() -> int:
    """扫描器的自测（`--selftest`）：插值嵌引号这类曾经的截断点全部钉住。**"""
    cases: list[tuple[str, str | None]] = [
        # (输入, 期望的 raw；None 表示应当读不出来)
        ('"普通文案"', "普通文案"),
        ('"状态：\\(x)"', "状态：\\(x)"),
        # 插值里嵌一层字符串 —— 旧正则在这里截断
        ('"RTT：\\(m.map { "\\($0)ms" } ?? "—")"',
         'RTT：\\(m.map { "\\($0)ms" } ?? "—")'),
        # 插值里嵌套括号
        ('"共 \\(Format.time(item.time)) 条"', "共 \\(Format.time(item.time)) 条"),
        # 转义引号不是结束
        ('"他说 \\"你好\\""', '他说 \\"你好\\"'),
        # 空合并里的引号不被当成字面量边界
        ('"值：\\(dict["k"] ?? "—")"', '值：\\(dict["k"] ?? "—")'),
        # 未闭合（读到换行）
        ('"断了\n"', None),
    ]
    failures = 0
    for source, expected in cases:
        result = read_string_literal(source, 0)
        got = None if result is None else result[0]
        if got != expected:
            failures += 1
            print(f"selftest 失败：{source[:40]}… → {got!r}（期望 {expected!r}）", file=sys.stderr)

    # 迭代器：三引号块整块跳过，后面的字面量照常收
    triple = 'let a = """\n多行\n"""\nlet b = "之后的"'
    literals = [raw for _, raw, _ in iter_string_literals(triple)]
    if literals != ["之后的"]:
        failures += 1
        print(f"selftest 失败：三引号块跳过 → {literals!r}", file=sys.stderr)

    # 迭代器：插值里的引号不会把一个字面量劈成两个
    nested = 'Text("RTT：\\(m.map { "\\($0)ms" } ?? "—")")'
    literals = [raw for _, raw, _ in iter_string_literals(nested)]
    if len(literals) != 1:
        failures += 1
        print(f"selftest 失败：嵌套引号劈开了字面量 → {literals!r}", file=sys.stderr)

    if failures:
        return 1
    print("selftest 通过：扫描器行为符合预期")
    return 0


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
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
    # 兜底：源码里有中文字面量，但抽取模式没看见它 —— 它在英文设备上会显示中文。
    extracted_keys = {key_for(raw) for raw in found}
    missed = {
        raw: where
        for raw, where in scan_chinese_literals().items()
        if key_for(raw) not in extracted_keys
    }
    if missed:
        problems.append(
            f"有 {len(missed)} 条面向人的中文字面量没被抽取（英文设备上会显示中文）。"
            "要么把调用点写成 `String(localized:)`，要么给抽取模式补上这个形状，"
            "确实不该翻译的加进 NOT_LOCALIZED 并写明理由：\n  "
            + "\n  ".join(f"{raw}   ← {where}" for raw, where in sorted(missed.items()))
        )
    ineffective = unwrapped_string_returns()
    if ineffective:
        problems.append(
            f"有 {len(ineffective)} 处 `return \"中文\"` 落在 `String` 返回位置上（只进目录、"
            "运行时不查）。改成 `return String(localized: \"…\")`：\n  "
            + "\n  ".join(ineffective)
        )
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
