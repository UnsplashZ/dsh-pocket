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
BUNDLE_ID="cc.zexa.dshpocket"
DEVICE=""
TEAM=""

# 从 Xcode 的偏好里探测开发团队：取第一个 teamID。
# 免费个人团队也在里面（isFreeProvisioningTeam = 1），所以免费账号同样能装机。
detect_team() {
  defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
    | grep -oE 'teamID = [A-Z0-9]+;' | head -1 | awk '{print $3}' | tr -d ';'
}

for arg in "$@"; do
  case "${arg}" in
    --list) xcrun devicectl list devices; exit 0 ;;
    --help|-h) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
  # devicectl 的输出里状态列是 "connected"/"available"；取第一台连着的真机
  DEVICE="$(xcrun devicectl list devices 2>/dev/null \
    | awk '/connected|available/ && $0 !~ /Simulator/ {print $(NF-1)}' | head -1)"
fi

if [ -z "${DEVICE}" ]; then
  echo "找不到已连接的 iPhone。" >&2
  echo "  · 用数据线连上手机并在手机上点「信任」" >&2
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
