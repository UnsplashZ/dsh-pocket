#!/usr/bin/env bash
# 把 DSHPocket 装到你自己的 iPhone 上（免费 Apple ID 也能用）。
#
#   bash scripts/install-device.sh                      # 自动挑唯一一台连着线的设备
#   bash scripts/install-device.sh --device <UDID>
#   bash scripts/install-device.sh --team <TEAMID>      # 手动指定开发团队
#   bash scripts/install-device.sh --list               # 列出可用设备
#
# 免费个人团队的两条现实约束，脚本里都处理了：
#   1. **证书 7 天过期**：每次装机都会 `-allowProvisioningUpdates` 让 Xcode 自动续；
#      7 天后重跑一次本脚本即可，不需要删 App。
#   2. **首次要信任开发者证书**：装完在手机上「设置 → 通用 → VPN 与设备管理」里
#      信任你的 Apple ID，然后才能启动。脚本会把这一步打出来。
#
# 前提：Xcode 里已登录一个 Apple ID（Xcode → Settings → Accounts）。
# 开发团队会自动从 Xcode 的偏好里探测（`IDEProvisioningTeamByIdentifier`），
# 探测不到就用 `--team <TEAMID>` 显式给一个。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

DERIVED="${ROOT}/.derived-device"
BUNDLE_ID="cc.unsplashz.dshpocket"
DEVICE=""
TEAM=""

# 从 Xcode 的偏好里探测开发团队：取第一个 teamID。
# 免费个人团队也在里面（isFreeProvisioningTeam = 1），所以免费账号同样能装机。
detect_team() {
  defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
    | grep -oE 'teamID = [A-Z0-9]+;' | head -1 | awk '{print $3}' | tr -d ';'
}

# 只挑**能装机的真机**：physical + iOS —— 模拟器与 Apple Watch 一次排除干净。
#
# 为什么不再用 `awk '{print $(NF-1)}'` 数表格的列号（本脚本原来就是这么写的，是错的）：
#   · 那样取到的是**机型列** `(iPhone16,1)`，不是 UDID，喂给 xcodebuild 会报
#     `unreadable input '18)' at end of value for option 'Destination'`；
#   · 而且 `available` 会**先命中那台 Apple Watch**（它长期是 `available (paired)`），
#     于是"自动挑设备"实际挑中的是一块手表；
#   · 表格里 `Identifier` 列还带 `(UDID)` 后缀、设备名里也可能带空格
#     （实测 Apple Watch 的名字里是不换行空格 U+00A0），按列号解析怎么都不稳。
# 所以改成让 devicectl 自己过滤（`--filter`），只对 **UDID 正则**取值 ——
# UDID 不含空格也不含中文，是这堆输出里唯一稳的锚点。
DEVICE_BASE_FILTER='properties.hardware.reality == "physical" AND properties.hardware.platform == "iOS"'

# 打印一台可装机真机的 UDID；没有就打印空。
# 可选参数是连接状态：传 `connected` 只要已连上的，省略则不限状态。
#
# `|| true` 是必须的：本脚本开着 `set -euo pipefail`，若把这条失败的命令替换
# 放进赋值，`set -e` 会**直接终止脚本** —— 那样"没找到设备"就变成"脚本莫名退出"，
# 而调用方本来是要走兜底与友好报错的。`head` 提前关管道让 `grep` 拿到
# SIGPIPE（退出码 141）同理，一并吞掉。
pick_device_udid() {
  local state="${1:-}"
  local filter="${DEVICE_BASE_FILTER}"
  if [ -n "${state}" ]; then
    filter="${filter} AND properties.connection.state == \"${state}\""
  fi
  { xcrun devicectl list devices \
      --hide-default-columns --columns Identifier \
      --filter "${filter}" 2>/dev/null \
    | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' \
    | head -1; } || true
}

# devicectl 较旧、不认识 `properties.*` 字段时的兜底：不带 filter 解析，
# 仍然只认真机 + iOS，并同样用 UDID 正则挑。
pick_device_udid_unfiltered() {
  { xcrun devicectl list devices 2>/dev/null \
    | grep -E '[[:space:]]physical[[:space:]]' \
    | grep -vE 'watchOS|Apple[[:space:]]Watch' \
    | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' \
    | head -1; } || true
}

# 挑设备的顺序：已连接的 → 任意可用的真机 → 不带 filter 的兜底。
pick_device() {
  local picked
  picked="$(pick_device_udid connected)"
  if [ -z "${picked}" ]; then picked="$(pick_device_udid)"; fi
  if [ -z "${picked}" ]; then picked="$(pick_device_udid_unfiltered)"; fi
  printf '%s' "${picked}"
}

for arg in "$@"; do
  case "${arg}" in
    --list) xcrun devicectl list devices --filter "${DEVICE_BASE_FILTER}"; exit 0 ;;
    # 打印文件头那段注释当帮助。**不能用固定行号**（`sed -n '2,20p'` 一旦
    # 头部注释变长/变短就会把正文代码也打出来），改成"从第 2 行起，
    # 遇到第一条非注释行就停"。
    --help|-h) sed -n '2,${/^[^#]/q; s/^# \{0,1\}//; p;}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) ;;
  esac
done

while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --team) TEAM="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "${TEAM}" ]; then
  TEAM="$(detect_team)"
fi

if [ -z "${TEAM}" ]; then
  cat >&2 <<'EOF'
探测不到开发团队。两种办法：
  1. 打开 Xcode → Settings → Accounts，登录一个 Apple ID（免费个人团队即可）；
  2. 或者显式指定：bash scripts/install-device.sh --team <10 位 TEAMID>
EOF
  exit 1
fi

echo "==> 开发团队：${TEAM}"

if [ -z "${DEVICE}" ]; then
  DEVICE="$(pick_device)"
fi

if [ -z "${DEVICE}" ]; then
  echo "找不到可用的 iPhone。" >&2
  echo "  · 用数据线连上手机并在手机上点「信任」" >&2
  echo "  · 手机已配对但没连上时，先在手机上点开 DSH Pocket 唤醒连接" >&2
  echo "  · 或者用 --device <UDID> 指定；--list 可以看有哪些设备" >&2
  exit 1
fi

echo "==> 目标设备：${DEVICE}"

# 依赖（Iroh 的预编译部件）
if [ ! -d "ios/vendor/Iroh.xcframework" ]; then
  echo "==> 取 Iroh 部件"
  bash ios/scripts/fetch-iroh.sh
fi

echo "==> 生成工程"
(cd ios && xcodegen generate --spec project.yml >/dev/null)

echo "==> 构建（真机）"
# 与 ios/build.sh 同样的环境开关：受限沙箱里需要 -disable-sandbox 才能跑宏插件。
export CLANG_MODULE_CACHE_PATH="${ROOT}/ios/.module-cache"
mkdir -p "${CLANG_MODULE_CACHE_PATH}"

(cd ios && xcodebuild \
  -project DSHPocket.xcodeproj \
  -scheme DSHPocket \
  -configuration Debug \
  -destination "id=${DEVICE}" \
  -derivedDataPath "${DERIVED}" \
  -allowProvisioningUpdates \
  "DEVELOPMENT_TEAM=${TEAM}" \
  "DSH_POCKET_SWIFT_FLAGS=${DSH_POCKET_SWIFT_FLAGS:-}" \
  build)

APP="${DERIVED}/Build/Products/Debug-iphoneos/DSHPocket.app"
if [ ! -d "${APP}" ]; then
  echo "没找到产物：${APP}" >&2
  exit 1
fi

echo "==> 装机"
xcrun devicectl device install app --device "${DEVICE}" "${APP}"

echo "==> 启动"
# 装完启动失败有两种**完全不同**的原因，别把它们混成一句话让用户猜：
#   · 手机锁屏 → 解锁后自己点开就行，重跑脚本没必要；
#   · 证书没信任 → 必须去设置里信任，否则点了也打不开。
LAUNCH_LOG="$(mktemp)"
if xcrun devicectl device process launch --device "${DEVICE}" "${BUNDLE_ID}" > "${LAUNCH_LOG}" 2>&1; then
  rm -f "${LAUNCH_LOG}"
else
  if grep -qiE "not, or could not, be unlocked|Locked|FBSOpenApplicationErrorDomain error 7" "${LAUNCH_LOG}"; then
    cat <<'EOF'

已经装好了，只是**手机锁着**所以没能自动启动。
解锁后直接在手机上点开 DSH Pocket 就行 —— 不用重跑本脚本。
EOF
  else
    cat <<'EOF'

启动失败，最常见的原因是还没信任开发者证书：
  手机 → 设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任你的 Apple ID
信任之后再跑一次本脚本，或直接在手机上点开 DSH Pocket。
EOF
  fi
  rm -f "${LAUNCH_LOG}"
fi

cat <<'EOF'

第一次在同一 Wi-Fi 下连接电脑时，系统会问「本地网络」权限 —— 必须允许，
否则 iroh 的 UDP 打洞会被内核静默拦掉（表现为连接超时、电脑端完全收不到连接）。
EOF

cat <<EOF

完成。接下来：
  1. 在电脑上打开 DSH 的「连接手机」，拿到配对串；
  2. 手机上打开 DSH Pocket → 添加电脑 → 扫码或手输 6 位码；
  3. 免费 Apple ID 的证书 7 天后过期 —— 到期后重跑本脚本即可（不用删 App）。
EOF
