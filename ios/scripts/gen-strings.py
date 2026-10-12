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
}

# 哪些插值表达式是整数。判错的后果是英文界面上显示成 `%lld` 字面量，
# 所以这里同时用"名字白名单"和"看 .count / Int( 这两种形状"两条判据。
INT_EXPRESSIONS = {"turn", "count", "minutes", "remainder", "step", "index"}


def is_integer_expression(inner: str) -> bool:
    stripped = inner.strip()
    if stripped in INT_EXPRESSIONS:
        return True
    if ".count" in stripped or stripped.startswith("Int("):
        return True
    if "prefix(" in stripped or "suffix(" in stripped:
        return False
    return False


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


def extract() -> dict[str, str]:
    found: dict[str, str] = {}
    for path in sorted(SOURCE_DIR.rglob("*.swift")):
        text = path.read_text()
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
            # 有插值的 key：把源语言那一侧也写全，便于译者对照
            entry["localizations"][SOURCE_LANGUAGE] = {
                "stringUnit": {"state": "translated", "value": raw}
            }
        catalog_strings[key] = entry

    problems = []
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
