#!/usr/bin/env bash
# 把手机上的 App 日志取回来（不用解锁手机、不用手动导出）。
#
#   bash scripts/pull-logs.sh              # 取回并打印最后 80 行
#   bash scripts/pull-logs.sh --all        # 取回并打印全文
#   bash scripts/pull-logs.sh --out /tmp/x # 指定落盘位置
#
# 依赖 App 把日志落盘（`MemoryLogSink(fileURL:)`，0.4.14 起）。
# 取的是 App 容器里的 `Library/Logs/dsh-pocket.log` —— 它是**追加写**的，
# 所以 App 被杀掉之后现场还在，这正是连接类 bug 最需要的那段。
#
# 为什么不用「设置 → 诊断 → 导出日志」：那条路要求用户手动操作，而
# "卡在连接中"这种场景往往连界面都点不动；而且重启后内存日志就没了。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

BUNDLE_ID="cc.unsplashz.dshpocket"
SOURCE_PATH="Library/Logs/dsh-pocket.log"
OUT="/tmp/dsh-pocket.log"
MODE="tail"

while [ $# -gt 0 ]; do
  case "$1" in
    --all) MODE="all"; shift ;;
    --out) OUT="$2"; shift 2 ;;
    --device) DEVICE_OVERRIDE="$2"; shift 2 ;;
    -h|--help) sed -n '2,${/^[^#]/q; s/^# \{0,1\}//; p;}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) shift ;;
  esac
done

# 复用装机脚本里那套"只挑真机"的逻辑，避免挑到 Mac 或手表。
DEVICE="${DEVICE_OVERRIDE:-}"
if [ -z "${DEVICE}" ]; then
  DEVICE="$(xcrun devicectl list devices \
    --hide-default-columns --columns Identifier \
    --filter 'properties.hardware.reality == "physical" AND properties.hardware.platform == "iOS"' 2>/dev/null \
    | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1 || true)"
fi

if [ -z "${DEVICE}" ]; then
  echo "找不到 iPhone。用数据线连上并解锁后再试（--device <UDID> 可显式指定）。" >&2
  exit 1
fi

echo "==> 从 ${DEVICE} 取 ${SOURCE_PATH}"
rm -f "${OUT}"
if ! xcrun devicectl device copy from \
    --device "${DEVICE}" \
    --domain-type appDataContainer \
    --domain-identifier "${BUNDLE_ID}" \
    --source "${SOURCE_PATH}" \
    --destination "${OUT}" >/dev/null 2>&1; then
  echo "取不到日志。" >&2
  echo "  · 手机锁屏时取不了 —— 解锁再试；" >&2
  echo "  · 也可能是这版 App 还没把日志落盘（0.4.14 起才有）。" >&2
  exit 1
fi

LINES="$(wc -l < "${OUT}" | tr -d ' ')"
echo "==> 已保存 ${OUT}（${LINES} 行）"

if [ "${MODE}" = "all" ]; then
  cat "${OUT}"
else
  echo "==> 最后 80 行（--all 看全文）"
  tail -80 "${OUT}"
fi
